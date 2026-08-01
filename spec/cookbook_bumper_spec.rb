require_relative 'spec_helper'
require_relative '../lib/cookbook_bumper'

RSpec.describe CookbookBumper do
  let(:workspace) { Dir.mktmpdir }
  let(:env) do
    {
      'GITHUB_ORG' => 'osuosl-cookbooks',
      'GITHUB_TOKEN' => 'test-token',
      'WORKSPACE' => workspace,
      'RESULT_FILE' => File.join(workspace, 'bump_result.json'),
      'DO_NOT_UPLOAD' => 'true',
    }
  end
  let(:pr_labels) { [] }
  let(:mergeable_state) { 'clean' }
  let(:pr_body) { 'Adds TLS support to the vhost config.' }
  let(:pr_commits) { [] }
  let(:base_ref) { 'master' }
  let(:pull_request) do
    double(
      'pr',
      merged: false,
      mergeable: true,
      mergeable_state: mergeable_state,
      html_url: 'https://github.com/osuosl-cookbooks/osl-apache/pull/42',
      base: double(ref: base_ref),
      head: double(ref: 'feature-tls', sha: 'abc123',
                   repo: double(full_name: 'osuosl-cookbooks/osl-apache')),
      labels: pr_labels,
      body: pr_body
    )
  end
  let(:permission) { 'write' }
  let(:commit_state) { 'success' }
  let(:github) do
    double(
      'github',
      pull_request: pull_request,
      pull_request_commits: pr_commits,
      merge_pull_request: true,
      delete_branch: true,
      add_comment: true,
      add_labels_to_an_issue: true,
      permission_level: double(permission: permission),
      combined_status: double(state: commit_state)
    )
  end
  let(:repo) do
    double('repo', checkout: true, add: true, commit: true, add_tag: true, push: true)
  end
  let(:git) do
    git = double('git')
    allow(git).to receive(:clone) do |_url, dir|
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, 'metadata.rb'), <<~METADATA)
        name 'osl-apache'
        version '2.3.4'
      METADATA
      File.write(File.join(dir, 'CHANGELOG.md'), <<~CHANGELOG)
        osl-apache CHANGELOG
        ====================

        2.3.4 (2026-01-01)
        ------------------
        - Old entry
      CHANGELOG
      repo
    end
    git
  end
  let(:community_deps) { double('community_deps', call: []) }
  let(:shell_calls) { [] }
  let(:shell) { ->(*cmd) { shell_calls << cmd } }

  after { FileUtils.rm_rf(workspace) }

  def bumper(payload)
    described_class.new(
      payload: payload, env: env, github: github, git: git,
      community_deps: community_deps, shell: shell,
      sleeper: ->(_) {}, out: StringIO.new
    )
  end

  context 'with a bump label event' do
    let(:payload) { json_fixture('labeled_payload.json') }
    let(:pr_labels) { [double(name: 'env/production'), double(name: 'bump/minor')] }

    it 'merges the PR and bumps the minor version' do
      result = bumper(payload).run
      expect(github).to have_received(:merge_pull_request).with('osuosl-cookbooks/osl-apache', 42)
      expect(result['cookbooks']).to eq([{ 'name' => 'osl-apache', 'version' => '2.4.0' }])
    end

    it 'collects environments from env/* labels' do
      expect(bumper(payload).run['envs']).to eq('production')
      expect(github).not_to have_received(:add_labels_to_an_issue)
    end

    # Forgetting the env label is far more common than deliberately wanting
    # no environment bump, so an unlabeled release defaults to env/default.
    context 'with no env label on the PR' do
      let(:pr_labels) { [double(name: 'bump/minor')] }

      it 'defaults to env/default and records the label on the PR' do
        result = bumper(payload).run
        expect(result['envs']).to eq('default')
        expect(github).to have_received(:add_labels_to_an_issue)
          .with('osuosl-cookbooks/osl-apache', 42, ['env/default'])
        expect(File).to exist(env['RESULT_FILE'])
      end

      it 'still releases when the label cannot be added' do
        allow(github).to receive(:add_labels_to_an_issue)
          .and_raise(Octokit::Forbidden)
        expect(bumper(payload).run['envs']).to eq('default')
        expect(File).to exist(env['RESULT_FILE'])
      end
    end

    it 'writes the result file for the environment bumper' do
      bumper(payload).run
      result = JSON.parse(File.read(env['RESULT_FILE']))
      expect(result['pr_link']).to eq('https://github.com/osuosl-cookbooks/osl-apache/pull/42')
    end

    it 'commits, tags, and pushes to the PR base branch' do
      bumper(payload).run
      expect(repo).to have_received(:checkout).with('master')
      expect(repo).to have_received(:add_tag).with('v2.4.0')
      expect(repo).to have_received(:push).with('origin', 'master', tags: true)
    end

    it 'deletes the source branch' do
      bumper(payload).run
      expect(github).to have_received(:delete_branch).with('osuosl-cookbooks/osl-apache', 'feature-tls')
    end

    it 'does not run knife when DO_NOT_UPLOAD is set' do
      bumper(payload).run
      expect(shell_calls).to be_empty
    end

    it 'updates the CHANGELOG with the PR title' do
      bumper(payload).run
      changelog = File.read(File.join(workspace, 'cookbook', 'CHANGELOG.md'))
      expect(changelog).to match(/2\.4\.0 \(\d{4}-\d{2}-\d{2}\)\n-+\n- Add TLS support/)
    end

    context 'with a main-defaulted repo' do
      let(:base_ref) { 'main' }

      it 'pushes to main without any master assumption' do
        bumper(payload).run
        expect(repo).to have_received(:checkout).with('main')
        expect(repo).to have_received(:push).with('origin', 'main', tags: true)
      end
    end

    context 'with a Chain: directive in the PR body' do
      let(:pr_labels) { [double(name: 'bump/minor'), double(name: 'env/default')] }
      let(:pr_body) { "Part of the postfix update.\n\nCookbook-Chain: postfix-refactor" }

      it 'carries the chain name into the result' do
        result = bumper(payload).run
        expect(result['chain']).to eq('postfix-refactor')
        expect(result['envs']).to eq('default')
      end
    end

    context 'with a Chain: directive in a commit message' do
      let(:pr_commits) do
        [
          double(commit: double(message: 'Fix vhost template')),
          double(commit: double(message: "Update relay config\n\nCookbook-Chain: postfix-refactor")),
        ]
      end

      it 'picks up the chain from the commits when the body has none' do
        expect(bumper(payload).run['chain']).to eq('postfix-refactor')
      end
    end

    context 'with directives in both the body and a commit' do
      let(:pr_body) { 'Cookbook-Chain: from-body' }
      let(:pr_commits) { [double(commit: double(message: 'Cookbook-Chain: from-commit'))] }

      it 'prefers the PR body' do
        expect(bumper(payload).run['chain']).to eq('from-body')
      end
    end

    # Gerrit Depends-On style: pointing at the upstream PR instead of
    # inventing a name. All reference forms canonicalize to the same key.
    context 'with a PR reference as the chain value' do
      let(:pr_body) { 'Cookbook-Chain: https://github.com/osuosl-cookbooks/osl-postfix/pull/123' }

      it 'canonicalizes a full PR URL' do
        expect(bumper(payload).run['chain']).to eq('osl-postfix-123')
      end
    end

    context 'with a short PR reference as the chain value' do
      let(:pr_body) { 'Cookbook-Chain: osl-postfix#123' }

      it 'canonicalizes repo#number' do
        expect(bumper(payload).run['chain']).to eq('osl-postfix-123')
      end
    end

    context 'with an org-qualified PR reference as the chain value' do
      let(:pr_body) { 'Cookbook-Chain: osuosl-cookbooks/osl-postfix#123' }

      it 'canonicalizes org/repo#number to the same key' do
        expect(bumper(payload).run['chain']).to eq('osl-postfix-123')
      end
    end

    context 'with knife uploads enabled' do
      let(:env) { super().merge('DO_NOT_UPLOAD' => nil) }

      it 'uploads and shares the cookbook' do
        bumper(payload).run
        expect(shell_calls.map(&:first)).to eq(%w(knife knife))
        expect(shell_calls.first).to include('cookbook', 'upload', 'osl-apache', '--freeze')
      end
    end

    context 'when the label is not a bump label' do
      let(:payload) { json_fixture('labeled_payload.json').merge('label' => { 'name' => 'env/production' }) }

      it 'does nothing' do
        expect(bumper(payload).run).to be_nil
        expect(github).not_to have_received(:merge_pull_request)
      end
    end

    context 'when the PR is already merged' do
      before { allow(pull_request).to receive(:merged).and_return(true) }

      it 'refuses' do
        expect { bumper(payload).run }.to raise_error(CookbookBumper::Error, /already merged/)
      end
    end

    # Applying a label needs only triage on GitHub, which does not grant merge
    # or push; releasing must require write access on both trigger paths.
    context 'when the labeller lacks write access' do
      let(:permission) { 'read' }

      it 'refuses before merging' do
        expect { bumper(payload).run }.to raise_error(CookbookBumper::Error, /not authorized/)
        expect(github).not_to have_received(:merge_pull_request)
      end
    end

    context 'when the labeller is not a collaborator at all' do
      before do
        allow(github).to receive(:permission_level).and_raise(Octokit::NotFound.new(status: 404))
      end

      it 'refuses before merging' do
        expect { bumper(payload).run }.to raise_error(CookbookBumper::Error, /not authorized/)
        expect(github).not_to have_received(:merge_pull_request)
      end
    end

    context 'with a forged payload naming a repo outside the org' do
      let(:payload) do
        json_fixture('labeled_payload.json').tap do |p|
          p['repository']['full_name'] = 'attacker/evil'
        end
      end

      it 'refuses before touching GitHub' do
        expect { bumper(payload).run }
          .to raise_error(CookbookBumper::Error, /not in the 'osuosl-cookbooks' organization/)
        expect(github).not_to have_received(:merge_pull_request)
      end
    end

    context 'when the PR has conflicts' do
      let(:mergeable_state) { 'dirty' }

      it 'refuses' do
        expect { bumper(payload).run }.to raise_error(CookbookBumper::Error, /merge conflicts/)
        expect(github).not_to have_received(:merge_pull_request)
      end
    end

    # The bot holds admin so GitHub would let it bypass protection for anyone;
    # for a non-admin labeller it must refuse instead of exploiting that.
    context 'when branch protection blocks the PR and the labeller is not an admin' do
      let(:mergeable_state) { 'blocked' }

      it 'refuses with an actionable message and does not merge' do
        expect { bumper(payload).run }
          .to raise_error(CookbookBumper::Error, /blocked by branch protection.*approving review/m)
        expect(github).not_to have_received(:merge_pull_request)
      end
    end

    # An admin can merge a protected branch by hand, and cannot approve their
    # own PR, so the label path has to honor that same bypass or admins could
    # never release their own work.
    context 'when branch protection blocks the PR but an admin applied the label' do
      let(:mergeable_state) { 'blocked' }
      let(:permission) { 'admin' }

      it 'releases anyway when checks are green' do
        result = bumper(payload).run
        expect(github).to have_received(:merge_pull_request)
        expect(result['cookbooks']).to eq([{ 'name' => 'osl-apache', 'version' => '2.4.0' }])
      end

      it 'records the bypass on the PR' do
        bumper(payload).run
        expect(github).to have_received(:add_comment)
          .with('osuosl-cookbooks/osl-apache', 42, /admin bypass of branch protection/)
      end

      context 'but the checks are failing' do
        let(:commit_state) { 'failure' }

        it 'still refuses — the bypass does not cover red checks' do
          expect { bumper(payload).run }
            .to raise_error(CookbookBumper::Error, /checks are not passing/)
          expect(github).not_to have_received(:merge_pull_request)
        end
      end

      context 'and the checks have not finished' do
        let(:commit_state) { 'pending' }

        it 'waits rather than releasing' do
          expect { bumper(payload).run }
            .to raise_error(CookbookBumper::Error, /still unknown/)
          expect(github).not_to have_received(:merge_pull_request)
        end
      end
    end

    context 'when the PR is behind its base branch' do
      let(:mergeable_state) { 'behind' }

      it 'refuses' do
        expect { bumper(payload).run }.to raise_error(CookbookBumper::Error, /out of date/)
      end
    end

    context 'when only non-required checks are failing' do
      let(:mergeable_state) { 'unstable' }

      it 'still releases' do
        expect(bumper(payload).run['cookbooks']).to eq([{ 'name' => 'osl-apache', 'version' => '2.4.0' }])
      end
    end

    # bump/skip: merge with no release at all.
    context 'with the bump/skip label' do
      let(:payload) { json_fixture('labeled_payload.json').merge('label' => { 'name' => 'bump/skip' }) }

      it 'merges without releasing anything' do
        expect(bumper(payload).run).to be_nil
        expect(github).to have_received(:merge_pull_request).with('osuosl-cookbooks/osl-apache', 42)
        expect(github).to have_received(:delete_branch)
        expect(repo).not_to have_received(:add_tag)
        expect(shell_calls).to be_empty
        expect(File).not_to exist(env['RESULT_FILE'])
      end

      it 'never adds the env/default label - skip touches no environments' do
        bumper(payload).run
        expect(github).not_to have_received(:add_labels_to_an_issue)
      end

      it 'says so on the PR' do
        bumper(payload).run
        expect(github).to have_received(:add_comment)
          .with('osuosl-cookbooks/osl-apache', 42, /Merged without a release/)
      end

      it 'still requires write access' do
        allow(github).to receive(:permission_level).and_return(double(permission: 'read'))
        expect { bumper(payload).run }.to raise_error(CookbookBumper::Error, /not authorized/)
        expect(github).not_to have_received(:merge_pull_request)
      end
    end

    context 'when community dependencies changed' do
      before do
        allow(community_deps).to receive(:call).and_return([{ name: 'postfix', version: '6.1.8' }])
      end

      it 'includes them in the result cookbooks' do
        expect(bumper(payload).run['cookbooks']).to include('name' => 'postfix', 'version' => '6.1.8')
      end
    end

    # The release is already published by this point and cannot be retried,
    # so a community upload failure must not swallow the environment bump.
    context 'when a community dependency upload fails' do
      before do
        allow(community_deps).to receive(:call).and_raise(StandardError, 'cookbook is frozen')
      end

      it 'still finishes the release and queues the environment bump' do
        result = bumper(payload).run
        expect(result['cookbooks']).to eq([{ 'name' => 'osl-apache', 'version' => '2.4.0' }])
        expect(File).to exist(env['RESULT_FILE'])
      end

      it 'reports the failure on the PR' do
        bumper(payload).run
        expect(github).to have_received(:add_comment)
          .with('osuosl-cookbooks/osl-apache', 42, /Community dependency upload failed.*cookbook is frozen/m)
      end
    end

    it 'emits chain as a string so Jenkins readJSON cannot turn nil into "null"' do
      expect(bumper(payload).run['chain']).to eq('')
    end
  end

  it 'ignores non-labeled pull_request payloads' do
    payload = json_fixture('labeled_payload.json')
    payload['action'] = 'synchronize'
    expect(bumper(payload).run).to be_nil
  end
end
