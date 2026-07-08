require_relative 'spec_helper'
require_relative '../lib/community_deps'

RSpec.describe CommunityDeps do
  let(:github) { double('github') }
  let(:shell_calls) { [] }
  let(:shell) { ->(*cmd) { shell_calls << cmd } }
  let(:deps) do
    described_class.new(
      github: github, org: 'osuosl-cookbooks',
      public_supermarket: 'https://supermarket.chef.io',
      local_supermarket: 'https://supermarket.osuosl.org',
      shell: shell, out: StringIO.new
    )
  end

  def stub_pr_files(patch)
    allow(github).to receive(:pull_request_files)
      .with('osuosl-cookbooks/osl-apache', 42)
      .and_return([double(filename: 'metadata.rb', patch: patch)])
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
    it 'downloads from the public supermarket and shares locally' do
      deps.upload('postfix', '6.1.8')
      expect(shell_calls[0]).to include('supermarket', 'download', 'postfix', '6.1.8', '-m',
                                        'https://supermarket.chef.io')
      expect(shell_calls[2]).to include('cookbook', 'upload', 'postfix', '--freeze')
      expect(shell_calls[3]).to include('supermarket', 'share', 'postfix', '-m',
                                        'https://supermarket.osuosl.org')
    end

    it 'does nothing when do_not_upload is set' do
      quiet = described_class.new(
        github: github, org: 'o', public_supermarket: 'x', local_supermarket: 'y',
        shell: shell, do_not_upload: true, out: StringIO.new
      )
      quiet.upload('postfix', '6.1.8')
      expect(shell_calls).to be_empty
    end
  end

  describe '#call' do
    it 'resolves and uploads only community deps' do
      stub_pr_files(<<~PATCH)
        +depends 'postfix', '~> 6.1'
        +depends 'osl-nginx', '~> 2.0'
      PATCH
      allow(github).to receive(:repository?).with('osuosl-cookbooks/postfix').and_return(false)
      allow(github).to receive(:repository?).with('osuosl-cookbooks/osl-nginx').and_return(true)
      stub_request(:get, 'https://supermarket.chef.io/api/v1/cookbooks/postfix')
        .to_return(status: 200, body: fixture('supermarket_cookbook.json'))

      expect(deps.call('osuosl-cookbooks/osl-apache', 42))
        .to eq([{ name: 'postfix', version: '6.1.8' }])
      expect(shell_calls).not_to be_empty
    end
  end
end
