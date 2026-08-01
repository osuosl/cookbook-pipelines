require_relative 'spec_helper'
require_relative '../lib/community_deps'

RSpec.describe CommunityDeps do
  let(:github) { double('github') }
  let(:shell_calls) { [] }
  # Versions the fake Chef server "has": 'knife cookbook show' succeeds for
  # these and raises (non-zero exit) for everything else.
  let(:server_versions) { [] }
  let(:shell) do
    lambda do |*cmd|
      shell_calls << cmd
      next unless cmd[0, 3] == %w(knife cookbook show)

      raise 'not found' unless server_versions.include?(cmd[3, 2].join(' '))
    end
  end
  # What the fake Chef server /universe reports as present.
  let(:universe) { {} }
  let(:out) { StringIO.new }
  let(:deps) do
    described_class.new(
      github: github, org: 'osuosl-cookbooks',
      public_supermarket: 'https://supermarket.chef.io',
      shell: shell, server_universe: -> { universe }, out: out
    )
  end

  def stub_pr_files(patch)
    allow(github).to receive(:pull_request_files)
      .with('osuosl-cookbooks/osl-apache', 42)
      .and_return([double(filename: 'metadata.rb', patch: patch)])
  end

  # The public supermarket's per-version metadata, which carries each
  # version's dependency constraints.
  def stub_version_deps(name, version, dependencies = {})
    stub_request(:get, "https://supermarket.chef.io/api/v1/cookbooks/#{name}/versions/#{version.tr('.', '_')}")
      .to_return(status: 200, body: JSON.generate('dependencies' => dependencies))
  end

  def stub_cookbook_versions(name, versions)
    stub_request(:get, "https://supermarket.chef.io/api/v1/cookbooks/#{name}")
      .to_return(status: 200, body: JSON.generate(
        'versions' => versions.map { |v| "https://supermarket.chef.io/api/v1/cookbooks/#{name}/versions/#{v.tr('.', '_')}" }
      ))
  end

  describe '#changed_constraints' do
    it 'finds added depends lines' do
      stub_pr_files(<<~PATCH)
        +depends 'postfix', '~> 6.1'
        +depends 'osl-nginx'
      PATCH
      expect(deps.changed_constraints('osuosl-cookbooks/osl-apache', 42))
        .to contain_exactly(['postfix', '~> 6.1'], ['osl-nginx', nil])
    end

    it 'finds changed constraints but skips untouched ones' do
      stub_pr_files(<<~PATCH)
        -depends 'postfix', '~> 5.0'
        +depends 'postfix', '~> 6.1'
         depends 'apt', '>= 7.0'
      PATCH
      expect(deps.changed_constraints('osuosl-cookbooks/osl-apache', 42))
        .to eq([['postfix', '~> 6.1']])
    end

    it 'ignores moved-but-unchanged depends lines' do
      stub_pr_files(<<~PATCH)
        -depends 'postfix', '~> 6.1'
        +depends 'postfix', '~> 6.1'
      PATCH
      expect(deps.changed_constraints('osuosl-cookbooks/osl-apache', 42)).to be_empty
    end

    it 'returns nothing when metadata.rb was not touched' do
      allow(github).to receive(:pull_request_files)
        .and_return([double(filename: 'recipes/default.rb', patch: '+foo')])
      expect(deps.changed_constraints('osuosl-cookbooks/osl-apache', 42)).to be_empty
    end
  end

  describe '#community?' do
    it 'treats org repos as non-community' do
      allow(github).to receive(:repository?).with('osuosl-cookbooks/osl-nginx').and_return(true)
      expect(deps.community?('osl-nginx')).to be false
    end

    it 'treats unknown names as community' do
      allow(github).to receive(:repository?).with('osuosl-cookbooks/postfix').and_return(false)
      expect(deps.community?('postfix')).to be true
    end
  end

  describe '#resolve' do
    before do
      stub_request(:get, 'https://supermarket.chef.io/api/v1/cookbooks/postfix')
        .to_return(status: 200, body: fixture('supermarket_cookbook.json'))
    end

    it 'picks the newest version satisfying the constraint' do
      expect(deps.resolve('postfix', '~> 5.0')).to eq('5.5.1')
    end

    it 'picks the newest version when unconstrained' do
      expect(deps.resolve('postfix', nil)).to eq('6.1.8')
    end

    it 'raises when nothing satisfies' do
      expect { deps.resolve('postfix', '>= 99') }.to raise_error(CommunityDeps::Error, /no version/)
    end
  end

  describe '#upload' do
    it 'downloads from the public supermarket and uploads to the Chef server' do
      deps.upload('postfix', '6.1.8')
      expect(shell_calls[0]).to eq(%w(knife cookbook show postfix 6.1.8))
      expect(shell_calls[1]).to include('supermarket', 'download', 'postfix', '6.1.8', '-m',
                                        'https://supermarket.chef.io')
      expect(shell_calls[3]).to include('cookbook', 'upload', 'postfix', '--freeze')
      expect(shell_calls.length).to eq(4)
    end

    # The local supermarket holds only org cookbooks.
    it 'never shares community cookbooks to the local supermarket' do
      deps.upload('postfix', '6.1.8')
      expect(shell_calls.flatten).not_to include('share')
    end

    # A version already on the Chef server is the routine case (uploaded by an
    # earlier bump); it must count as success so the env pin still updates.
    context 'when the version already exists on the Chef server' do
      let(:server_versions) { ['postfix 6.1.8'] }

      it 'skips the download/upload/share entirely' do
        deps.upload('postfix', '6.1.8')
        expect(shell_calls).to eq([%w(knife cookbook show postfix 6.1.8)])
      end
    end

    it 'does nothing when do_not_upload is set' do
      quiet = described_class.new(
        github: github, org: 'o', public_supermarket: 'x',
        shell: shell, do_not_upload: true, out: StringIO.new
      )
      quiet.upload('postfix', '6.1.8')
      expect(shell_calls).to be_empty
    end
  end

  describe '#call' do
    before do
      allow(github).to receive(:repository?).with('osuosl-cookbooks/postfix').and_return(false)
      allow(github).to receive(:repository?).with('osuosl-cookbooks/osl-nginx').and_return(true)
      stub_request(:get, 'https://supermarket.chef.io/api/v1/cookbooks/postfix')
        .to_return(status: 200, body: fixture('supermarket_cookbook.json'))
    end

    it 'resolves and uploads only community deps' do
      stub_pr_files(<<~PATCH)
        +depends 'postfix', '~> 6.1'
        +depends 'osl-nginx', '~> 2.0'
      PATCH
      stub_version_deps('postfix', '6.1.8')

      expect(deps.call('osuosl-cookbooks/osl-apache', 42))
        .to eq([{ name: 'postfix', version: '6.1.8' }])
      expect(shell_calls).not_to be_empty
    end

    context 'with transitive dependencies' do
      before do
        stub_pr_files("+depends 'postfix', '~> 6.1'\n")
        allow(github).to receive(:repository?).with('osuosl-cookbooks/yum-epel').and_return(false)
        allow(github).to receive(:repository?).with('osuosl-cookbooks/yum').and_return(false)
      end

      it 'uploads a transitive dep the server cannot satisfy, recursively' do
        stub_version_deps('postfix', '6.1.8', 'yum-epel' => '>= 4.0')
        stub_cookbook_versions('yum-epel', %w(4.1.2 5.0.0))
        stub_version_deps('yum-epel', '5.0.0', 'yum' => '>= 7.0')
        stub_cookbook_versions('yum', %w(7.4.13))
        stub_version_deps('yum', '7.4.13')

        expect(deps.call('osuosl-cookbooks/osl-apache', 42)).to eq(
          [{ name: 'postfix', version: '6.1.8' },
           { name: 'yum-epel', version: '5.0.0' },
           { name: 'yum', version: '7.4.13' },]
        )
      end

      it 'leaves a dep alone when the server already satisfies it' do
        stub_version_deps('postfix', '6.1.8', 'yum-epel' => '>= 4.0')
        universe['yum-epel'] = { '4.1.2' => {} }

        expect(deps.call('osuosl-cookbooks/osl-apache', 42))
          .to eq([{ name: 'postfix', version: '6.1.8' }])
        expect(shell_calls.flatten.join(' ')).not_to include('yum-epel')
      end

      it 'skips org cookbooks but warns when the server lacks them entirely' do
        allow(github).to receive(:repository?).with('osuosl-cookbooks/osl-repos').and_return(true)
        stub_version_deps('postfix', '6.1.8', 'osl-repos' => '>= 5.0')

        expect(deps.call('osuosl-cookbooks/osl-apache', 42))
          .to eq([{ name: 'postfix', version: '6.1.8' }])
        expect(out.string).to include('osl-repos is an org cookbook the Chef server does not have')
      end

      it 'merges constraints from several dependents of a missing dep' do
        stub_version_deps('postfix', '6.1.8', 'yum-epel' => '>= 4.0', 'yum' => '~> 7.0')
        universe['yum-epel'] = { '4.1.2' => {} }
        stub_cookbook_versions('yum', %w(7.4.13 8.0.0))
        stub_version_deps('yum', '7.4.13')

        expect(deps.call('osuosl-cookbooks/osl-apache', 42))
          .to eq([{ name: 'postfix', version: '6.1.8' }, { name: 'yum', version: '7.4.13' }])
      end

      it 'raises on conflicting requirements for something already uploaded' do
        stub_version_deps('postfix', '6.1.8', 'yum-epel' => '>= 4.0', 'yum' => '>= 0')
        stub_cookbook_versions('yum-epel', %w(5.0.0))
        stub_version_deps('yum-epel', '5.0.0')
        stub_cookbook_versions('yum', %w(7.4.13))
        stub_version_deps('yum', '7.4.13', 'yum-epel' => '< 5.0')

        expect { deps.call('osuosl-cookbooks/osl-apache', 42) }
          .to raise_error(CommunityDeps::Error, /conflicting requirements: yum-epel 5\.0\.0/)
      end
    end
  end
end
