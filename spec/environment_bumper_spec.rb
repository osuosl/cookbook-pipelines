require_relative 'spec_helper'
require_relative '../lib/environment_bumper'

RSpec.describe EnvironmentBumper do
  let(:workspace) { Dir.mktmpdir }
  let(:default_branch) { 'master' }
  let(:env) do
    {
      'CHEF_REPO' => 'osuosl/chef-repo',
      'GITHUB_TOKEN' => 'test-token',
      'WORKSPACE' => workspace,
      'DEFAULT_ENVIRONMENTS' => 'production,workstation',
      'cookbooks' => 'osl-postfix:2.1.0,postfix:6.1.8',
      'envs' => 'production',
      'chain' => '',
      'pr_link' => 'https://github.com/osuosl-cookbooks/osl-postfix/pull/7',
    }
  end
  let(:remote_branches) { [] }
  let(:created_pr) { double(html_url: 'https://github.com/osuosl/chef-repo/pull/100', number: 100) }
  let(:github) do
    double(
      'github',
      repo: double(default_branch: default_branch),
      pull_requests: [],
      create_pull_request: created_pr,
      add_comment: true,
      update_pull_request: true
    )
  end
  let(:repo) do
    repo = double('repo', checkout: true, add: true, commit: true, push: true, pull: true)
    allow(repo).to receive(:branch) { |_name| double(checkout: true) }
    allow(repo).to receive(:branches).and_return(remote_branches)
    repo
  end
  let(:git) do
    git = double('git')
    allow(git).to receive(:clone) do |_url, dir|
      FileUtils.mkdir_p(File.join(dir, 'environments'))
      {
        'production' => { 'osl-postfix' => '= 2.0.0', 'postfix' => '= 6.0.2', 'apt' => '= 7.3.0' },
        'staging' => { 'osl-postfix' => '= 2.0.0' },
        'phpbb' => { 'apt' => '= 7.3.0' },
      }.each do |name, pins|
        File.write(File.join(dir, 'environments', "#{name}.json"),
                   JSON.pretty_generate('name' => name, 'cookbook_versions' => pins))
      end
      repo
    end
    git
  end

  after { FileUtils.rm_rf(workspace) }

  def bumper(overrides = {})
    described_class.new(env: env.merge(overrides), github: github, git: git, out: StringIO.new)
  end

  def environment(name)
    JSON.parse(File.read(File.join(workspace, 'chef-repo', 'environments', "#{name}.json")))
  end

  it 'pins all requested cookbooks in the environment' do
    bumper.run
    pins = environment('production')['cookbook_versions']
    expect(pins['osl-postfix']).to eq('= 2.1.0')
    expect(pins['postfix']).to eq('= 6.1.8')
    expect(pins['apt']).to eq('= 7.3.0')
  end

  it 'expands the default env word' do
    expect { bumper('envs' => 'default').run }
      .to raise_error(EnvironmentBumper::Error, /workstation\.json does not exist/)
  end

  it 'expands all to every environment file' do
    bumper('envs' => 'all').run
    expect(environment('staging')['cookbook_versions']['osl-postfix']).to eq('= 2.1.0')
  end

  it 'only touches environments that already pin the cookbook' do
    bumper('envs' => 'all').run
    expect(environment('phpbb')['cookbook_versions']).to eq('apt' => '= 7.3.0')
  end

  it 'creates a PR against the default branch with a content-addressed branch name' do
    bumper.run
    expect(github).to have_received(:create_pull_request).with(
      'osuosl/chef-repo', 'master', %r{\Ajenkins/osl-postfix-2\.1\.0-\h{7}\z},
      'Bump \'osl-postfix\' to 2.1.0, \'postfix\' to 6.1.8', /production/
    )
  end

  it 'force-pushes non-chain branches for idempotent retries' do
    bumper.run
    expect(repo).to have_received(:push).with('origin', anything, force: true)
  end

  it 'does nothing when every pin is already current' do
    expect(bumper('cookbooks' => 'apt:7.3.0', 'envs' => 'production').run).to be_nil
    expect(repo).not_to have_received(:commit)
  end

  context 'with a main-defaulted chef-repo' do
    let(:default_branch) { 'main' }

    it 'checks out and targets main' do
      bumper.run
      expect(repo).to have_received(:checkout).with('main')
      expect(github).to have_received(:create_pull_request)
        .with('osuosl/chef-repo', 'main', anything, anything, anything)
    end
  end

  context 'with a new chain' do
    it 'uses the chain branch and never force-pushes' do
      bumper('chain' => 'postfix-refactor').run
      expect(repo).to have_received(:push).with('origin', 'jenkins/chain-postfix-refactor', force: false)
      expect(github).to have_received(:create_pull_request)
        .with('osuosl/chef-repo', 'master', 'jenkins/chain-postfix-refactor',
              'Chained cookbook bumps (postfix-refactor)', anything)
    end
  end

  context 'with an existing chain branch and open PR' do
    let(:remote_branches) { [double(remote: true, name: 'jenkins/chain-postfix-refactor')] }
    let(:open_pr) do
      double(number: 55, body: 'existing body', html_url: 'https://github.com/osuosl/chef-repo/pull/55')
    end

    before do
      allow(github).to receive(:pull_requests)
        .with('osuosl/chef-repo', state: 'open', head: 'osuosl:jenkins/chain-postfix-refactor')
        .and_return([open_pr])
    end

    it 'stacks a commit on the chain branch and updates the PR' do
      bumper('chain' => 'postfix-refactor').run
      expect(repo).to have_received(:pull).with('origin', 'jenkins/chain-postfix-refactor')
      expect(github).not_to have_received(:create_pull_request)
      expect(github).to have_received(:add_comment).with('osuosl/chef-repo', 55, /osl-postfix.*2\.1\.0/)
      expect(github).to have_received(:update_pull_request)
        .with('osuosl/chef-repo', 55, body: /existing body\n- Added bump/)
    end
  end

  it 'raises on malformed cookbook pins' do
    expect { bumper('cookbooks' => 'nonsense').run }
      .to raise_error(EnvironmentBumper::Error, /malformed cookbook pin/)
  end

  # Explicitly named environments may gain NEW pins (e.g. a freshly added
  # community dependency); 'all' is update-only so one label cannot introduce
  # a cookbook everywhere.
  context 'when a requested cookbook is not yet pinned' do
    it 'adds the pin in an explicitly named environment' do
      bumper('cookbooks' => 'osl-postfix:2.1.0,brand-new-dep:3.2.0', 'envs' => 'production').run
      pins = environment('production')['cookbook_versions']
      expect(pins['brand-new-dep']).to eq('= 3.2.0')
      expect(repo).to have_received(:commit)
        .with(/osl-postfix to v2\.1\.0, brand-new-dep to v3\.2\.0/)
    end

    it 'writes cookbook_versions alphabetized so new pins land predictably' do
      bumper('cookbooks' => 'brand-new-dep:3.2.0', 'envs' => 'production').run
      expect(environment('production')['cookbook_versions'].keys)
        .to eq(%w(apt brand-new-dep osl-postfix postfix))
    end

    it 'leaves an environment file untouched when nothing changed in it' do
      # osl-postfix is already at 2.0.0 in staging; re-pinning production only
      # must not rewrite (and re-sort) staging.
      bumper('cookbooks' => 'osl-postfix:2.1.0', 'envs' => 'production').run
      expect(environment('staging')['cookbook_versions'].keys).to eq(%w(osl-postfix))
      expect(environment('production')['cookbook_versions'].keys)
        .to eq(%w(apt osl-postfix postfix))
    end

    it 'calls out newly added pins in the PR body' do
      bumper('cookbooks' => 'osl-postfix:2.1.0,brand-new-dep:3.2.0', 'envs' => 'production').run
      expect(github).to have_received(:create_pull_request)
        .with('osuosl/chef-repo', 'master', anything, anything,
              /Newly pinned.*brand-new-dep 3\.2\.0 in: production/m)
    end

    it 'does not add pins under env all, and flags the skip' do
      bumper('cookbooks' => 'osl-postfix:2.1.0,brand-new-dep:3.2.0', 'envs' => 'all').run
      expect(environment('production')['cookbook_versions']).not_to have_key('brand-new-dep')
      expect(repo).to have_received(:commit).with(/\Aautomatic version bump of osl-postfix to v2\.1\.0 by jenkins/i)
      expect(github).to have_received(:create_pull_request)
        .with('osuosl/chef-repo', 'master', anything, "Bump 'osl-postfix' to 2.1.0",
              /left unchanged: brand-new-dep/)
    end

    it 'treats an explicitly named env as addable even when all is also selected' do
      bumper('cookbooks' => 'brand-new-dep:3.2.0', 'envs' => 'all,production').run
      expect(environment('production')['cookbook_versions']['brand-new-dep']).to eq('= 3.2.0')
      expect(environment('staging')['cookbook_versions']).not_to have_key('brand-new-dep')
    end
  end

  # Re-running the same non-chain bump force-pushes the same content-addressed
  # branch; creating a second PR for it would fail with a 422.
  context 'when re-run for a non-chain branch that already has an open PR' do
    let(:remote_branches) { [double(remote: true, name: 'jenkins/osl-postfix-2.1.0-abcdef1')] }
    let(:open_pr) do
      double(number: 77, body: 'body', html_url: 'https://github.com/osuosl/chef-repo/pull/77')
    end

    before do
      allow(github).to receive(:pull_requests).and_return([open_pr])
    end

    it 'updates the existing PR instead of creating a duplicate' do
      bumper.run
      expect(github).not_to have_received(:create_pull_request)
      expect(github).to have_received(:add_comment).with('osuosl/chef-repo', 77, /Added bump of/)
    end
  end
end
