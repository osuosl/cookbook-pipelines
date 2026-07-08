require_relative 'spec_helper'
require_relative '../lib/cookbook_bumper'

RSpec.describe CookbookBumper do
  let(:workspace) { Dir.mktmpdir }
  let(:env) do
    {
      'GITHUB_ORG' => 'osuosl-cookbooks',
      'WORKSPACE' => workspace,
      'RESULT_FILE' => File.join(workspace, 'bump_result.json'),
      'DO_NOT_UPLOAD' => 'true',
    }
  end
  let(:pr_labels) { [] }
  let(:base_ref) { 'master' }
  let(:pull_request) do
    double(
      'pr',
      merged: false,
      mergeable: true,
      html_url: 'https://github.com/osuosl-cookbooks/osl-apache/pull/42',
      base: double(ref: base_ref),
      head: double(ref: 'feature-tls', repo: double(full_name: 'osuosl-cookbooks/osl-apache')),
      labels: pr_labels
    )
  end
  let(:github) do
    double(
      'github',
      pull_request: pull_request,
      merge_pull_request: true,
      delete_branch: true,
      add_comment: true
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

    context 'with a chain label' do
      let(:pr_labels) do
        [double(name: 'bump/minor'), double(name: 'chain/postfix-refactor'), double(name: 'env/default')]
      end

      it 'carries the chain name into the result' do
        result = bumper(payload).run
        expect(result['chain']).to eq('postfix-refactor')
        expect(result['envs']).to eq('default')
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

    context 'when the PR has conflicts' do
      before { allow(pull_request).to receive(:mergeable).and_return(false) }

      it 'refuses' do
        expect { bumper(payload).run }.to raise_error(CookbookBumper::Error, /cannot be merged/)
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
  end

  context 'with a !bump comment event' do
    let(:payload) { json_fixture('comment_payload.json') }

    before do
      allow(github).to receive(:permission_level)
        .and_return(double(permission: 'write'))
    end

    it 'parses level, envs, and chain from the comment' do
      result = bumper(payload).run
      expect(result['cookbooks']).to eq([{ 'name' => 'osl-apache', 'version' => '2.3.5' }])
      expect(result['envs']).to eq('production,staging')
      expect(result['chain']).to eq('postfix-refactor')
    end

    it 'requires write access' do
      allow(github).to receive(:permission_level).and_return(double(permission: 'read'))
      expect { bumper(payload).run }.to raise_error(CookbookBumper::Error, /not authorized/)
    end

    it 'maps legacy ~ and * env words' do
      payload['comment']['body'] = '!bump major ~'
      expect(bumper(payload).run['envs']).to eq('default')
    end

    it 'ignores non-bump comments' do
      payload['comment']['body'] = 'looks good to me!'
      expect(bumper(payload).run).to be_nil
    end

    it 'ignores comments on non-PR issues' do
      payload['issue'].delete('pull_request')
      expect(bumper(payload).run).to be_nil
    end
  end
end
