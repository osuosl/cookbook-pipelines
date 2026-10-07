require_relative 'spec_helper'
require_relative '../lib/chef_repo_environments'

RSpec.describe ChefRepoEnvironments do
  describe '.expand' do
    let(:all) { %w(_default phpbb production workstation) }
    let(:default) { %w(production workstation) }

    def expand(*tokens)
      described_class.expand(tokens, all: all, default: default)
    end

    it 'makes named and default environments addable' do
      expect(expand('phpbb', 'default')).to eq('phpbb' => true, 'production' => true, 'workstation' => true)
    end

    it 'sweeps every environment in update-only for all' do
      expect(expand('all')).to eq(all.to_h { |e| [e, false] })
    end

    it 'keeps an explicitly named environment addable alongside all' do
      expect(expand('phpbb', 'all')['phpbb']).to be true
    end
  end

  describe '.chain_branch' do
    it 'names the chain branch' do
      expect(described_class.chain_branch('support-osuosl-rt')).to eq('jenkins/chain-support-osuosl-rt')
    end
  end

  describe ChefRepoEnvironments::Pins do
    let(:github) { double('github') }
    let(:pins) do
      described_class.new(github: github, chef_repo: 'osuosl/chef-repo',
                          default_environments: %w(production workstation))
    end
    let(:environments) do
      {
        'phpbb' => { 'certificate' => '= 2.0.3' },
        'production' => { 'certificate' => '= 2.0.4', 'osl-rt' => '= 4.0.0' },
        'workstation' => { 'certificate' => '= 2.0.4' },
      }
    end

    # Stub the contents API for one ref; nil means no ref (default branch).
    def stub_environments(ref, envs = environments)
      extra = ref ? { ref: ref } : {}
      allow(github).to receive(:contents)
        .with('osuosl/chef-repo', path: 'environments', **extra)
        .and_return((envs.keys + ['README.md']).map { |e| double(name: e.end_with?('.md') ? e : "#{e}.json") })
      allow(github).to receive(:contents)
        .with('osuosl/chef-repo', path: start_with('environments/'), **extra)
        .and_raise(Octokit::NotFound)
      envs.each do |name, versions|
        allow(github).to receive(:contents)
          .with('osuosl/chef-repo', path: "environments/#{name}.json", **extra)
          .and_return(double(content: [JSON.generate({ 'cookbook_versions' => versions }.compact)].pack('m')))
      end
    end

    def entry(name, addable, selected: true)
      { selected: selected, addable: addable, pins: environments.fetch(name), live: environments.fetch(name) }
    end

    it 'flags the environments the selection reaches' do
      stub_environments(nil)
      expect(pins.environments(%w(default)))
        .to eq('phpbb' => entry('phpbb', false, selected: false), 'production' => entry('production', true),
               'workstation' => entry('workstation', true))
    end

    # The environment bumper updates a pin wherever it already exists under
    # 'all', so every environment is selected, update-only.
    it 'selects every environment for all, none of them addable' do
      stub_environments(nil)
      expect(pins.environments(%w(all))).to eq(environments.keys.to_h { |e| [e, entry(e, false)] })
    end

    # The environment bumper would only fail on it after the merge.
    it 'refuses a selected environment chef-repo does not have' do
      stub_environments(nil)
      expect { pins.environments(%w(nonesuch phpbb)) }
        .to raise_error(ChefRepoEnvironments::Error, /no such chef-repo environment: nonesuch/)
    end

    it 'reads an environment without cookbook_versions as pinning nothing' do
      stub_environments(nil, 'phpbb' => nil)
      expect(pins.environments(%w(phpbb))['phpbb'][:pins]).to eq({})
    end

    context 'with a chain' do
      it 'reads pins from the chain branch and live pins from the default one' do
        allow(github).to receive(:branch).with('osuosl/chef-repo', 'jenkins/chain-rt').and_return(double)
        stub_environments(nil)
        stub_environments('jenkins/chain-rt', environments.merge('phpbb' => { 'certificate' => '= 2.0.4' }))

        expect(pins.environments(%w(phpbb), chain: 'rt')['phpbb'])
          .to eq(selected: true, addable: true, pins: { 'certificate' => '= 2.0.4' },
                 live: { 'certificate' => '= 2.0.3' })
      end

      it 'has no live pins for an environment the chain adds' do
        allow(github).to receive(:branch).with('osuosl/chef-repo', 'jenkins/chain-rt').and_return(double)
        stub_environments(nil)
        stub_environments('jenkins/chain-rt', environments.merge('staging' => { 'osl-rt' => '= 4.1.0' }))

        expect(pins.environments(%w(staging), chain: 'rt')['staging'][:live]).to eq({})
      end

      it 'falls back to the default branch before the chain branch exists' do
        allow(github).to receive(:branch).and_raise(Octokit::NotFound)
        stub_environments(nil)

        expect(pins.environments(%w(phpbb), chain: 'rt')['phpbb']).to eq(entry('phpbb', true))
      end
    end
  end
end
