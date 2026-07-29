require_relative 'spec_helper'
require_relative '../lib/github_sync'

RSpec.describe GithubSync do
  let(:env) do
    {
      'GITHUB_ORG' => 'osuosl-cookbooks',
      'GITHUB_TOKEN' => 'test-token',
      'GITHUB_USER' => 'osuosl-bot',
      'DEFAULT_ENVIRONMENTS' => 'production,workstation',
      'WEBHOOK_ENDPOINT' => 'https://jenkins.example.org/generic-webhook-trigger/invoke',
      'TRIGGER_TOKEN' => 'trigger-secret',
    }
  end
  let(:hook_url) { 'https://jenkins.example.org/generic-webhook-trigger/invoke?token=trigger-secret' }
  let(:current_hook) do
    {
      'id' => 7, 'name' => 'web', 'active' => true, 'events' => %w(pull_request),
      'config' => { 'url' => hook_url, 'content_type' => 'json' },
    }
  end
  let(:repo_labels) { [] }
  let(:repo_hooks) { [] }
  let(:protection) { nil }
  let(:migrated) { false }
  let(:delete_branch_on_merge) { false }
  let(:repo_teams) { [] }
  let(:github) do
    github = double(
      'github',
      org_repos: [
        double(name: 'osl-apache', archived?: false, default_branch: 'master'),
        double(name: 'old-thing', archived?: true, default_branch: 'master'),
      ],
      repository: double(default_branch: 'master',
                         to_h: { delete_branch_on_merge: delete_branch_on_merge }),
      add_label: true, create_hook: true, edit_hook: true, protect_branch: true,
      remove_hook: true, put: true, edit_repository: true,
      repository_teams: repo_teams
    )
    allow(github).to receive(:labels).and_return(repo_labels)
    allow(github).to receive(:hooks).and_return(repo_hooks)
    if migrated
      allow(github).to receive(:contents).and_return(double)
    else
      allow(github).to receive(:contents).and_raise(Octokit::NotFound.new(status: 404))
    end
    if protection.nil?
      allow(github).to receive(:branch_protection).and_raise(Octokit::NotFound.new(status: 404))
    else
      allow(github).to receive(:branch_protection).and_return(protection)
    end
    github
  end
  let(:sleeps) { [] }
  let(:out) { StringIO.new }

  def sync(overrides = {})
    described_class.new(env: env.merge(overrides), github: github,
                        out: out, sleeper: ->(s) { sleeps << s })
  end

  it 'discovers non-archived org repos' do
    sync.run
    expect(github).to have_received(:labels).with('osuosl-cookbooks/osl-apache')
    expect(github).not_to have_received(:labels).with('osuosl-cookbooks/old-thing')
  end

  it 'honors the REPOS canary list without discovery' do
    sync('REPOS' => 'test-cookbook').run
    expect(github).not_to have_received(:org_repos)
    expect(github).to have_received(:labels).with('osuosl-cookbooks/test-cookbook')
  end

  describe 'label seeding' do
    it 'creates every missing label, including env/<name> ones' do
      result = sync.run
      expect(github).to have_received(:add_label)
        .with('osuosl-cookbooks/osl-apache', 'bump/patch', '0e8a16')
      expect(github).to have_received(:add_label)
        .with('osuosl-cookbooks/osl-apache', 'env/production', '1d76db')
      expect(result[:stats][:labels_created]).to eq(8)
    end

    it 'skips existing labels case-insensitively' do
      allow(github).to receive(:labels)
        .and_return([double(name: 'Bump/Patch'), double(name: 'env/production')])
      sync.run
      expect(github).not_to have_received(:add_label)
        .with(anything, 'bump/patch', anything)
      expect(github).not_to have_received(:add_label)
        .with(anything, 'env/production', anything)
    end

    it 'throttles after each write' do
      sync.run
      expect(sleeps.length).to be >= 8
    end
  end

  describe 'webhook management' do
    it 'creates the hook with pull_request events only' do
      sync.run
      expect(github).to have_received(:create_hook).with(
        'osuosl-cookbooks/osl-apache', 'web',
        { url: hook_url, content_type: 'json', insecure_ssl: false },
        { events: %w(pull_request), active: true }
      )
    end

    context 'when the hook is already current' do
      let(:repo_hooks) { [current_hook] }

      it 'issues no writes for it' do
        result = sync.run
        expect(github).not_to have_received(:create_hook)
        expect(github).not_to have_received(:edit_hook)
        expect(result[:stats][:unchanged]).to eq(1)
      end
    end

    context 'when the hook has drifted' do
      let(:repo_hooks) do
        [current_hook.merge('events' => %w(issue_comment))]
      end

      it 'updates it in place' do
        sync.run
        expect(github).to have_received(:edit_hook)
          .with('osuosl-cookbooks/osl-apache', 7, 'web', anything, anything)
      end
    end
  end

  describe 'legacy webhook cleanup' do
    let(:legacy_uploader_url) do
      'https://x:y@jenkins.example.org/job/cookbook-uploader-osuosl-cookbooks-osl-apache/' \
        'buildWithParameters?token=t'
    end
    let(:legacy_hooks) do
      [
        { 'id' => 11, 'name' => 'web', 'active' => true, 'events' => %w(issue_comment),
          'config' => { 'url' => legacy_uploader_url, 'content_type' => 'form' }, },
        { 'id' => 12, 'name' => 'web', 'active' => true, 'events' => %w(issue_comment pull_request),
          'config' => { 'url' => 'https://jenkins.example.org/ghprbhook/', 'content_type' => 'form' }, },
      ]
    end

    context 'when the repo has a Jenkinsfile (migrated)' do
      let(:migrated) { true }
      let(:repo_hooks) { legacy_hooks }

      it 'removes the legacy uploader and ghprb hooks' do
        result = sync.run
        expect(github).to have_received(:remove_hook).with('osuosl-cookbooks/osl-apache', 11)
        expect(github).to have_received(:remove_hook).with('osuosl-cookbooks/osl-apache', 12)
        expect(result[:stats][:legacy_hooks_removed]).to eq(2)
      end

      it 'still ensures the new uploader hook exists' do
        sync.run
        expect(github).to have_received(:create_hook)
      end
    end

    context 'when the repo has no Jenkinsfile' do
      let(:repo_hooks) { legacy_hooks }

      it 'leaves the legacy hooks alone' do
        sync.run
        expect(github).not_to have_received(:remove_hook)
      end
    end

    context 'in dry-run mode' do
      let(:migrated) { true }
      let(:repo_hooks) { legacy_hooks }

      it 'reports but does not delete' do
        sync('DRY_RUN' => 'true').run
        expect(github).not_to have_received(:remove_hook)
        expect(out.string).to include('DRY RUN: would remove legacy webhook 11')
      end
    end
  end

  describe 'team access' do
    it 'grants every standing team its permission' do
      result = sync.run
      expect(github).to have_received(:put)
        .with('/orgs/osuosl-cookbooks/teams/chefs/repos/osuosl-cookbooks/osl-apache', permission: 'push')
      expect(github).to have_received(:put)
        .with('/orgs/osuosl-cookbooks/teams/ci/repos/osuosl-cookbooks/osl-apache', permission: 'admin')
      expect(result[:stats][:teams_updated]).to eq(4)
    end

    context 'when the teams already have the right permissions' do
      let(:repo_teams) do
        [double(slug: 'chefs', permission: 'push'), double(slug: 'ci', permission: 'admin'),
         double(slug: 'core', permission: 'admin'), double(slug: 'staff', permission: 'push'),]
      end

      it 'issues no writes' do
        result = sync.run
        expect(github).not_to have_received(:put)
        expect(result[:stats][:teams_updated]).to eq(0)
      end
    end

    context 'when a team has the wrong permission' do
      let(:repo_teams) { [double(slug: 'ci', permission: 'push')] }

      it 'corrects it' do
        sync.run
        expect(github).to have_received(:put)
          .with('/orgs/osuosl-cookbooks/teams/ci/repos/osuosl-cookbooks/osl-apache', permission: 'admin')
      end
    end
  end

  describe 'repo settings' do
    it 'enables delete_branch_on_merge' do
      result = sync.run
      expect(github).to have_received(:edit_repository)
        .with('osuosl-cookbooks/osl-apache', delete_branch_on_merge: true)
      expect(result[:stats][:settings_updated]).to eq(1)
    end

    context 'when it is already enabled' do
      let(:delete_branch_on_merge) { true }

      it 'issues no write' do
        sync.run
        expect(github).not_to have_received(:edit_repository)
      end
    end
  end

  describe 'branch protection' do
    it 'restricts default-branch pushes to the bot but exempts admins' do
      sync.run
      expect(github).to have_received(:protect_branch).with(
        'osuosl-cookbooks/osl-apache', 'master',
        hash_including(
          enforce_admins: false,
          restrictions: { users: %w(osuosl-bot), teams: [] }
        )
      )
    end

    context 'when protection exists with other settings' do
      let(:protection) do
        double(
          enforce_admins: double(enabled: false),
          restrictions: double(users: [], teams: [double(slug: 'staff')]),
          required_status_checks: double(strict: true, contexts: ['ci/lint']),
          required_pull_request_reviews: double(
            dismiss_stale_reviews: true,
            require_code_owner_reviews: false,
            required_approving_review_count: 1
          )
        )
      end

      it 'carries the existing settings forward in the replace PUT' do
        sync.run
        expect(github).to have_received(:protect_branch).with(
          'osuosl-cookbooks/osl-apache', 'master',
          hash_including(
            restrictions: { users: %w(osuosl-bot), teams: %w(staff) },
            required_status_checks: { strict: true, contexts: ['ci/lint'] },
            required_pull_request_reviews: hash_including(required_approving_review_count: 1)
          )
        )
      end
    end

    context 'when protection is already correct' do
      let(:protection) do
        double(
          enforce_admins: double(enabled: false),
          restrictions: double(users: [double(login: 'osuosl-bot')], teams: []),
          required_status_checks: nil,
          required_pull_request_reviews: nil
        )
      end

      it 'issues no write' do
        result = sync.run
        expect(github).not_to have_received(:protect_branch)
        expect(result[:stats][:protection_current]).to eq(1)
      end
    end

    it 'can be disabled via PROTECT_BRANCHES' do
      sync('PROTECT_BRANCHES' => 'false').run
      expect(github).not_to have_received(:branch_protection)
      expect(github).not_to have_received(:protect_branch)
    end
  end

  describe 'dry run' do
    it 'reports planned writes without performing any' do
      result = sync('DRY_RUN' => 'true').run
      expect(github).not_to have_received(:add_label)
      expect(github).not_to have_received(:create_hook)
      expect(github).not_to have_received(:protect_branch)
      expect(out.string).to include("DRY RUN: would create label 'bump/major'")
      expect(out.string).to include('DRY RUN: would restrict merges')
      expect(result[:stats][:labels_created]).to eq(8)
    end
  end

  describe 'failure isolation' do
    it 'records a failing repo and continues with the rest' do
      allow(github).to receive(:labels)
        .with('osuosl-cookbooks/broken').and_raise(Octokit::Forbidden.new(status: 403))
      allow(github).to receive(:labels)
        .with('osuosl-cookbooks/test-cookbook').and_return([])

      result = sync('REPOS' => 'broken,test-cookbook').run
      expect(result[:failures].size).to eq(1)
      expect(result[:failures].first).to match(/broken.*Forbidden/)
      expect(github).to have_received(:hooks).with('osuosl-cookbooks/test-cookbook')
    end
  end
end
