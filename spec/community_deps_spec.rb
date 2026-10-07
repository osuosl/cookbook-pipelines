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

  describe '.parse_universe' do
    let(:universe_json) { JSON.pretty_generate('yum' => { '7.4.13' => {} }) }

    it 'parses plain JSON' do
      expect(described_class.parse_universe(universe_json)).to eq('yum' => { '7.4.13' => {} })
    end

    it 'skips knife log lines that precede the JSON when knife logs to stdout' do
      output = "INFO: Using configuration from /var/lib/jenkins/.cinc/knife.rb\n#{universe_json}"
      expect(described_class.parse_universe(output)).to eq('yum' => { '7.4.13' => {} })
    end

    it 'raises a readable error when there is no JSON at all' do
      expect { described_class.parse_universe("INFO: Using configuration from /x\n") }
        .to raise_error(CommunityDeps::Error, %r{knife raw /universe returned no JSON})
    end

    it 'raises a readable error on malformed JSON' do
      expect { described_class.parse_universe("{\n  \"yum\": \n") }
        .to raise_error(CommunityDeps::Error, %r{could not parse /universe})
    end
  end

  describe 'DEFAULT_SERVER_UNIVERSE' do
    let(:fetch) { described_class::DEFAULT_SERVER_UNIVERSE }

    def stub_knife_raw(stdout, stderr, success)
      knife = instance_double(Mixlib::ShellOut, stdout: stdout, stderr: stderr, error?: !success)
      allow(knife).to receive(:run_command).and_return(knife)
      allow(Mixlib::ShellOut).to receive(:new).with('knife', 'raw', '/universe').and_return(knife)
    end

    it 'runs knife raw /universe and parses its stdout, ignoring stderr' do
      stub_knife_raw("INFO: Using configuration from /x\n{\"yum\": {}}\n", 'WARN: noise', true)
      expect(fetch.call).to eq('yum' => {})
    end

    it 'raises with knife output and an org-path hint when knife fails' do
      stub_knife_raw('', 'ERROR: Server responded with error 404 "Not Found"', false)
      expect { fetch.call }.to raise_error(CommunityDeps::Error) { |e|
        expect(e.message).to include('/organizations/<org>')
        expect(e.message).to include('404 "Not Found"')
      }
    end
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

  # Each listed version has no dependencies until a stub_version_deps call
  # (which takes precedence) says otherwise.
  def stub_cookbook_versions(name, versions)
    stub_request(:get, "https://supermarket.chef.io/api/v1/cookbooks/#{name}")
      .to_return(status: 200, body: JSON.generate(
        'versions' => versions.map { |v| "https://supermarket.chef.io/api/v1/cookbooks/#{name}/versions/#{v.tr('.', '_')}" }
      ))
    versions.each { |v| stub_version_deps(name, v) }
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

  # Resolution against the public supermarket, through #call with nothing
  # pinned alongside.
  describe 'resolution' do
    before do
      allow(github).to receive(:repository?).and_return(false)
      stub_request(:get, 'https://supermarket.chef.io/api/v1/cookbooks/postfix')
        .to_return(status: 200, body: fixture('supermarket_cookbook.json'))
    end

    it 'picks the newest version satisfying the constraint' do
      stub_pr_files("+depends 'postfix', '~> 5.0'\n")
      stub_version_deps('postfix', '5.5.1')
      expect(deps.call('osuosl-cookbooks/osl-apache', 42)).to eq([{ name: 'postfix', version: '5.5.1' }])
    end

    it 'picks the newest version of an unconstrained dependency the server lacks' do
      stub_pr_files("+depends 'postfix'\n")
      stub_version_deps('postfix', '6.1.8')
      expect(deps.call('osuosl-cookbooks/osl-apache', 42)).to eq([{ name: 'postfix', version: '6.1.8' }])
    end

    it 'raises when nothing satisfies' do
      stub_pr_files("+depends 'postfix', '>= 99'\n")
      expect { deps.call('osuosl-cookbooks/osl-apache', 42) }
        .to raise_error(CommunityDeps::Error, /no version of 'postfix' satisfies '>= 99'/)
    end

    # Deprecated cookbooks stop the release with a clear message instead of
    # knife's exit-0 refusal and the tar error it caused (the sudo cookbook).
    it 'refuses deprecated cookbooks outright' do
      stub_pr_files("+depends 'sudo', '~> 5.4'\n")
      stub_request(:get, 'https://supermarket.chef.io/api/v1/cookbooks/sudo')
        .to_return(status: 200, body: JSON.generate('deprecated' => true, 'replacement' => nil))
      expect { deps.call('osuosl-cookbooks/osl-apache', 42) }
        .to raise_error(CommunityDeps::Error, /'sudo' is DEPRECATED.*no replacement.*upload it manually/m)
    end

    it 'names the replacement of a deprecated cookbook when one exists' do
      stub_pr_files("+depends 'cron'\n")
      stub_request(:get, 'https://supermarket.chef.io/api/v1/cookbooks/cron')
        .to_return(status: 200, body: JSON.generate(
          'deprecated' => true, 'replacement' => 'https://supermarket.chef.io/cookbooks/newcron'
        ))
      expect { deps.call('osuosl-cookbooks/osl-apache', 42) }
        .to raise_error(CommunityDeps::Error, %r{replacement: https://.*newcron})
    end
  end

  describe '#upload' do
    let(:postfix) { { name: 'postfix', version: '6.1.8' } }
    let(:yum) { { name: 'yum', version: '7.4.13' } }

    it 'downloads from the public supermarket and uploads to the Chef server' do
      deps.upload([postfix])
      expect(shell_calls[0]).to eq(%w(knife cookbook show postfix 6.1.8))
      expect(shell_calls[1]).to include('supermarket', 'download', 'postfix', '6.1.8', '-m',
                                        'https://supermarket.chef.io')
      expect(shell_calls[3]).to include('cookbook', 'upload', 'postfix', '--freeze')
      expect(shell_calls.length).to eq(4)
    end

    # knife refuses a cookbook whose dependencies are neither on the server
    # nor in the same upload, so a dependent and its dependency must go up
    # together.
    it 'uploads several cookbooks in a single knife call' do
      deps.upload([postfix, yum])
      uploads = shell_calls.select { |c| c[0, 3] == %w(knife cookbook upload) }
      expect(uploads.length).to eq(1)
      expect(uploads.first).to include('postfix', 'yum', '--freeze')
      expect(shell_calls.count { |c| c[0, 3] == %w(knife supermarket download) }).to eq(2)
    end

    # The local supermarket holds only org cookbooks.
    it 'never shares community cookbooks to the local supermarket' do
      deps.upload([postfix])
      expect(shell_calls.flatten).not_to include('share')
    end

    # A version already on the Chef server is the routine case (uploaded by an
    # earlier bump); it must count as success so the env pin still updates.
    context 'when the version already exists on the Chef server' do
      let(:server_versions) { ['postfix 6.1.8'] }

      it 'skips the download/upload/share entirely' do
        deps.upload([postfix])
        expect(shell_calls).to eq([%w(knife cookbook show postfix 6.1.8)])
      end

      it 'leaves it out of the batch but still uploads the rest' do
        deps.upload([postfix, yum])
        upload = shell_calls.find { |c| c[0, 3] == %w(knife cookbook upload) }
        expect(upload).to include('yum')
        expect(upload).not_to include('postfix')
      end
    end

    it 'does nothing when do_not_upload is set' do
      quiet = described_class.new(
        github: github, org: 'o', public_supermarket: 'x',
        shell: shell, do_not_upload: true, out: StringIO.new
      )
      quiet.upload([postfix])
      expect(shell_calls).to be_empty
    end
  end

  describe '#call' do
    # bump/minor of whatever version the released metadata.rb carries.
    let(:bump) { ->(_current) { '2.4.0' } }

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

    # Raising a constraint to a version some earlier bump already uploaded
    # must still move the pin, or environments keep the old one.
    context 'when the server already has the resolved version' do
      let(:server_versions) { ['postfix 6.1.8'] }

      it 'still returns it so its environment pin updates' do
        stub_pr_files("-depends 'postfix', '~> 6.0.0'\n+depends 'postfix', '~> 6.1'\n")
        universe['postfix'] = { '6.0.3' => {}, '6.1.8' => {} }
        stub_version_deps('postfix', '6.1.8')

        expect(deps.call('osuosl-cookbooks/osl-apache', 42)).to eq([{ name: 'postfix', version: '6.1.8' }])
        expect(shell_calls.flatten).not_to include('upload')
      end
    end

    context 'with cookbooks pinned alongside' do
      # production and workstation pin base, whose 9.16.3 needs certificate
      # '~> 2.0.2'; phpbb lags on certificate 2.0.3.
      let(:env_pins) do
        {
          'phpbb' => { 'certificate' => '= 2.0.3' },
          'production' => { 'base' => '= 9.16.3', 'certificate' => '= 2.0.4', 'osl-apache' => '= 2.3.4' },
          'workstation' => { 'base' => '= 9.16.3', 'certificate' => '= 2.0.4' },
        }
      end

      # metadata.rb at the commit being released.
      let(:release_metadata) { "name 'osl-apache'\nversion '2.3.4'\n" }

      before do
        allow(github).to receive(:repository?).with('osuosl-cookbooks/certificate').and_return(false)
        allow(github).to receive(:contents).with('osuosl-cookbooks/osl-apache', path: 'metadata.rb', ref: 'abc123')
                                           .and_return(double(content: [release_metadata].pack('m')))
        stub_cookbook_versions('certificate', %w(2.0.3 2.0.4 2.0.5 3.0.0))
        universe['certificate'] = { '2.0.3' => {}, '2.0.4' => {} }
        universe['base'] = { '9.16.3' => { 'dependencies' => { 'certificate' => '~> 2.0.2' } } }
        universe['osl-apache'] = { '2.3.4' => {} }
      end

      # Named (or default) environments are addable; env/all sweeps them in
      # update-only.
      let(:addable) { true }

      def release
        selected = -> { env_pins.transform_values { |pins| { selected: true, addable: addable, pins: pins } } }
        deps.call('osuosl-cookbooks/osl-apache', 42, head_sha: 'abc123', next_version: bump, env_pins: selected)
      end

      # The osl-rt case: an unconstrained depends must not pin certificate
      # 3.0.0 over base's '~> 2.0.2' - or move the pin at all.
      it 'leaves an unconstrained dependency the server has at its pin' do
        stub_pr_files("+depends 'certificate'\n")

        expect(release).to be_empty
        expect(shell_calls).to be_empty
        expect(deps.left_alone).to eq(['certificate'])
      end

      it 'resolves an unconstrained dependency the server lacks entirely' do
        universe.delete('certificate')
        env_pins.each_value { |pins| pins.delete('certificate') }
        stub_pr_files("+depends 'certificate'\n")
        stub_version_deps('certificate', '2.0.5')

        expect(release).to eq([{ name: 'certificate', version: '2.0.5' }])
      end

      it 'resolves to the newest version every pinned cookbook accepts' do
        stub_pr_files("+depends 'certificate', '>= 2.0'\n")
        stub_version_deps('certificate', '2.0.5')

        expect(release).to eq([{ name: 'certificate', version: '2.0.5' }])
      end

      it 'refuses when nothing satisfies everyone, naming only the blockers' do
        universe['osl-nginx'] = { '6.9.2' => { 'dependencies' => { 'certificate' => '>= 0.0.0' } } }
        universe['osl-mirror'] = { '4.7.2' => { 'dependencies' => { 'certificate' => '< 4.0' } } }
        env_pins['production'].merge!('osl-nginx' => '= 6.9.2', 'osl-mirror' => '= 4.7.2')
        stub_pr_files("+depends 'certificate', '>= 3.0'\n")

        expect { release }.to raise_error(CommunityDeps::Error) { |e|
          expect(e.message).to include("no version of certificate satisfies '>= 3.0'")
          expect(e.message).to include('base 9.16.3 needs certificate ~> 2.0.2 (production, workstation)')
          expect(e.message).not_to include('osl-nginx')
          expect(e.message).not_to include('osl-mirror')
        }
        expect(shell_calls).to be_empty
      end

      it 'blames no other cookbook when the version does not exist at all' do
        stub_pr_files("+depends 'certificate', '>= 9.0'\n")

        expect { release }.to raise_error(CommunityDeps::Error, /\Ano version of 'certificate' satisfies '>= 9\.0'\z/)
      end

      # The releasing cookbook's pinned version still carries the old
      # constraint its PR is replacing.
      context 'when the PR replaces the releasing cookbook\'s constraint' do
        let(:release_metadata) { "depends 'certificate', '~> 2.0'\n" }

        it 'ignores its pinned constraint, which this release replaces' do
          universe['osl-apache'] = { '2.3.4' => { 'dependencies' => { 'certificate' => '~> 1.0' } } }
          stub_pr_files("-depends 'certificate', '~> 1.0'\n+depends 'certificate', '~> 2.0'\n")

          expect(release).to eq([{ name: 'certificate', version: '2.0.5' }])
        end
      end

      it 'refuses to downgrade a current pin' do
        stub_pr_files("+depends 'certificate', '< 2.0.4'\n")

        expect { release }.to raise_error(
          CommunityDeps::Error,
          /certificate 2\.0\.3 .* downgrade its pin from 2\.0\.4 in production, 2\.0\.4 in workstation/
        )
      end

      # env/all moves a community pin wherever it is pinned, whether or not the
      # releasing cookbook is pinned there too.
      context 'with env/all' do
        let(:addable) { false }

        before do
          universe['proj-x'] = { '1.0.0' => { 'dependencies' => { 'certificate' => '< 2.0.5' } } }
          stub_pr_files("+depends 'certificate', '~> 2.0.5'\n")
          stub_version_deps('certificate', '2.0.5')
        end

        it 'checks an environment that pins only the dependency' do
          env_pins['openstack-rdo'] = { 'certificate' => '= 2.0.4', 'proj-x' => '= 1.0.0' }

          expect { release }
            .to raise_error(CommunityDeps::Error, /proj-x 1\.0\.0 needs certificate < 2\.0\.5 \(openstack-rdo\)/)
        end

        # certificate floats there under the new osl-apache, so it must still
        # satisfy proj-x.
        it 'checks an environment that pins only the releasing cookbook' do
          env_pins['openstack-rdo'] = { 'osl-apache' => '= 2.3.4', 'proj-x' => '= 1.0.0' }

          expect { release }.to raise_error(CommunityDeps::Error, /\(openstack-rdo\)/)
        end

        it 'ignores an environment nothing this release pins lands in' do
          env_pins['openstack-rdo'] = { 'proj-x' => '= 1.0.0' }

          expect(release).to eq([{ name: 'certificate', version: '2.0.5' }])
        end
      end

      context 'with transitive dependencies' do
        before do
          allow(github).to receive(:repository?).with('osuosl-cookbooks/postfix').and_return(false)
        end

        it 'leaves one alone when every current pin meets it' do
          stub_pr_files("+depends 'postfix', '~> 6.1'\n")
          stub_version_deps('postfix', '6.1.8', 'certificate' => '~> 2.0.3')

          expect(release).to eq([{ name: 'postfix', version: '6.1.8' }])
        end

        # The server having 2.0.4 is not enough: phpbb still pins 2.0.3.
        it 'moves a stale pin the new version needs past' do
          stub_pr_files("+depends 'postfix', '~> 6.1'\n")
          stub_version_deps('postfix', '6.1.8', 'certificate' => '~> 2.0.4')
          stub_version_deps('certificate', '2.0.5')

          expect(release).to eq([{ name: 'postfix', version: '6.1.8' }, { name: 'certificate', version: '2.0.5' }])
        end

        it 'refuses one the pinned cookbooks rule out' do
          stub_pr_files("+depends 'postfix', '~> 6.1'\n")
          stub_version_deps('postfix', '6.1.8', 'certificate' => '>= 3.0')

          expect { release }.to raise_error(CommunityDeps::Error, /base 9\.16\.3 needs certificate ~> 2\.0\.2/)
          expect(shell_calls).to be_empty
        end

        # osl-apache's unchanged depends binds what this run pins, even where
        # osl-apache is not pinned yet or its pinned version said otherwise.
        context 'when the released metadata constrains it too' do
          let(:release_metadata) { "depends 'certificate', '< 2.0.5'\ndepends 'postfix', '~> 6.1'\n" }

          it 'keeps the released metadata\'s constraints on what the PR did not change' do
            universe['osl-apache'] = { '2.3.4' => { 'dependencies' => { 'certificate' => '>= 1.0' } } }
            stub_pr_files("+depends 'postfix', '~> 6.1'\n")
            stub_version_deps('postfix', '6.1.8', 'certificate' => '~> 2.0.4')

            expect(release).to include(name: 'certificate', version: '2.0.4')
          end
        end

        it 'ignores a constraint the release removed' do
          universe['osl-apache'] = { '2.3.4' => { 'dependencies' => { 'certificate' => '~> 1.0' } } }
          stub_pr_files("-depends 'certificate', '~> 1.0'\n+depends 'postfix', '~> 6.1'\n")
          stub_version_deps('postfix', '6.1.8', 'certificate' => '~> 2.0.4')

          expect(release).to include(name: 'certificate', version: '2.0.5')
        end

        context 'when no environment pins it' do
          before do
            env_pins.each_value { |pins| pins.delete('certificate') }
            universe['certificate']['3.0.0'] = {}
            stub_pr_files("+depends 'postfix', '~> 6.1'\n")
          end

          # It floats: 3.0.0 being on the server says nothing about base.
          it 'refuses a requirement the cookbooks pinned there rule out' do
            stub_version_deps('postfix', '6.1.8', 'certificate' => '>= 3.0')

            expect { release }.to raise_error(CommunityDeps::Error, /base 9\.16\.3 needs certificate ~> 2\.0\.2/)
          end

          it 'leaves it floating when the server has a version everyone accepts' do
            stub_version_deps('postfix', '6.1.8', 'certificate' => '>= 2.0')

            expect(release).to eq([{ name: 'postfix', version: '6.1.8' }])
          end
        end

        # yum is only found to need re-pinning while walking postfix, after
        # certificate was resolved.
        it 'ignores the old constraints of a cookbook re-pinned later in the walk' do
          allow(github).to receive(:repository?).with('osuosl-cookbooks/yum').and_return(false)
          env_pins['production']['yum'] = '= 1.0.0'
          universe['yum'] = { '1.0.0' => { 'dependencies' => { 'certificate' => '< 2.0.5' } } }
          stub_cookbook_versions('yum', %w(1.0.0 2.0.0))
          stub_version_deps('yum', '2.0.0', 'certificate' => '>= 2.0')
          stub_pr_files("+depends 'certificate', '~> 2.0.5'\n+depends 'postfix', '~> 6.1'\n")
          stub_version_deps('postfix', '6.1.8', 'yum' => '>= 2.0')

          expect(release).to contain_exactly({ name: 'certificate', version: '2.0.5' },
                                             { name: 'postfix', version: '6.1.8' },
                                             { name: 'yum', version: '2.0.0' })
        end

        it 'resolves a direct dependency within what a sibling\'s new version needs' do
          stub_pr_files("+depends 'certificate', '>= 2.0'\n+depends 'postfix', '~> 6.1'\n")
          stub_version_deps('postfix', '6.1.8', 'certificate' => '< 2.0.5')

          expect(release).to contain_exactly({ name: 'certificate', version: '2.0.4' },
                                             { name: 'postfix', version: '6.1.8' })
        end

        it 'does not report an unconstrained dependency the walk re-pins as left alone' do
          stub_pr_files("+depends 'certificate'\n+depends 'postfix', '~> 6.1'\n")
          stub_version_deps('postfix', '6.1.8', 'certificate' => '~> 2.0.4')

          expect(release).to include(name: 'certificate', version: '2.0.5')
          expect(deps.left_alone).to be_empty
        end

        # postfix's pinned 6.0.3 needs certificate '< 2.0.5', but this run
        # replaces it with 6.1.8.
        it 'ignores the old constraints of a cookbook this run re-pins' do
          env_pins['production']['postfix'] = '= 6.0.3'
          universe['postfix'] = { '6.0.3' => { 'dependencies' => { 'certificate' => '< 2.0.5' } } }
          stub_pr_files("+depends 'postfix', '~> 6.1'\n")
          stub_version_deps('postfix', '6.1.8', 'certificate' => '~> 2.0.5')
          stub_version_deps('certificate', '2.0.5')

          expect(release).to include(name: 'certificate', version: '2.0.5')
        end
      end
    end

    # A pass that hits a conflict carries on with a fallback version, which
    # can need things the final answer never does. Nothing that pass learned
    # may decide the answer unless a later pass confirms it.
    context 'when a pass visits versions the answer never uses' do
      let(:env_pins) { { 'production' => { 'base' => '= 1.0.0', 'yum' => '= 1.0.0' } } }
      let(:addable) { true }

      before do
        %w(pf yum certificate proj-x).each do |name|
          allow(github).to receive(:repository?).with("osuosl-cookbooks/#{name}").and_return(false)
        end
        allow(github).to receive(:repository?).with('osuosl-cookbooks/osl-repos').and_return(true)
        allow(github).to receive(:contents).with('osuosl-cookbooks/osl-apache', path: 'metadata.rb', ref: 'abc123')
                                           .and_return(double(content: [''].pack('m')))
        stub_cookbook_versions('pf', %w(1.0.0 1.1.0))
        stub_cookbook_versions('yum', %w(1.0.0 2.0.0))
        stub_cookbook_versions('certificate', %w(2.0.4 2.0.5 3.0.0))
        stub_version_deps('pf', '1.1.0', 'yum' => '>= 2.0', 'osl-repos' => '>= 0')
        universe['base'] = { '1.0.0' => { 'dependencies' => { 'pf' => '< 1.1', 'certificate' => '~> 2.0.2' } } }
        universe['yum'] = { '1.0.0' => { 'dependencies' => { 'pf' => '< 1.0' } } }
        universe['certificate'] = { '2.0.4' => {} }
      end

      def release
        selected = -> { env_pins.transform_values { |pins| { selected: true, addable: addable, pins: pins } } }
        deps.call('osuosl-cookbooks/osl-apache', 42, head_sha: 'abc123', next_version: bump, env_pins: selected)
      end

      # Only pf 1.1.0 would re-pin yum, and base rules it out: the pinned
      # yum 1.0.0 still needs pf < 1.0.
      it 'refuses rather than trusting a re-pin only the fallback needed' do
        stub_pr_files("+depends 'pf', '~> 1.0'\n")

        expect { release }.to raise_error(CommunityDeps::Error, /yum 1\.0\.0 needs pf < 1\.0 \(production\)/)
        expect(shell_calls).to be_empty
      end

      it 'ignores what a version nobody chose needs' do
        env_pins['production'].merge!('certificate' => '= 2.0.4')
        env_pins['production'].delete('yum')
        stub_version_deps('pf', '1.1.0', 'certificate' => '>= 3.0')
        stub_pr_files("+depends 'certificate', '>= 2.0'\n+depends 'pf', '~> 1.0'\n")

        expect(release).to contain_exactly({ name: 'certificate', version: '2.0.5' }, { name: 'pf', version: '1.0.0' })
      end

      # legacy pins neither pf nor osl-apache, only yum, which a pf 1.1.0
      # would re-pin.
      it 'ignores environments only a version nobody chose reaches' do
        env_pins.replace(
          'production' => { 'osl-apache' => '= 2.0.0', 'base' => '= 1.0.0', 'pf' => '= 0.9.0' },
          'legacy' => { 'yum' => '= 1.0.0', 'proj-x' => '= 1.0.0' }
        )
        universe['pf'] = { '0.9.0' => {} }
        universe['osl-apache'] = { '2.0.0' => {} }
        universe['proj-x'] = { '1.0.0' => { 'dependencies' => { 'pf' => '< 1.0' } } }
        stub_pr_files("+depends 'pf', '~> 1.0'\n")

        expect(deps.call('osuosl-cookbooks/osl-apache', 42, head_sha: 'abc123', next_version: bump, env_pins: lambda {
          env_pins.transform_values { |pins| { selected: true, addable: false, pins: pins } }
        })).to eq([{ name: 'pf', version: '1.0.0' }])
      end

      # The first pass falls back to pf 1.1.0 (needing the missing org
      # cookbook osl-repos); the settled one picks 1.0.0 and never visits it.
      it 'only warns about what the settled pass visited' do
        env_pins['production']['pf'] = '= 0.9.0'
        universe['pf'] = { '0.9.0' => {} }
        stub_version_deps('pf', '1.0.0', 'yum' => '>= 2.0')
        stub_pr_files("+depends 'pf', '~> 1.0'\n")

        expect(release).to contain_exactly({ name: 'pf', version: '1.0.0' }, { name: 'yum', version: '2.0.0' })
        expect(out.string).not_to include('osl-repos')
      end
    end

    context 'when several new versions constrain each other' do
      let(:env_pins) { { 'production' => {} } }
      let(:release_metadata) { "name 'osl-apache'\nversion '2.3.4'\n" }

      before do
        %w(a b d p q w y z).each do |name|
          allow(github).to receive(:repository?).with("osuosl-cookbooks/#{name}").and_return(false)
        end
        allow(github).to receive(:repository?).with('osuosl-cookbooks/osl-repos').and_return(true)
        allow(github).to receive(:contents).with('osuosl-cookbooks/osl-apache', path: 'metadata.rb', ref: 'abc123')
                                           .and_return(double(content: [release_metadata].pack('m')))
      end

      def release
        selected = -> { env_pins.transform_values { |pins| { selected: true, addable: true, pins: pins } } }
        deps.call('osuosl-cookbooks/osl-apache', 42, head_sha: 'abc123', next_version: bump, env_pins: selected)
      end

      # Each of p's and q's needs alone is met by something on the server;
      # only 2.5.0, which it lacks, meets both.
      it 'checks a floating dependency against everything the new versions need' do
        stub_pr_files("+depends 'p', '>= 1.0'\n+depends 'q', '>= 1.0'\n")
        stub_cookbook_versions('p', %w(1.0.0))
        stub_cookbook_versions('q', %w(1.0.0))
        stub_cookbook_versions('d', %w(1.0.0 2.5.0 3.0.0))
        stub_version_deps('p', '1.0.0', 'd' => '>= 2.0')
        stub_version_deps('q', '1.0.0', 'd' => '< 3.0')
        universe['d'] = { '1.0.0' => {}, '3.0.0' => {} }

        expect(release).to include(name: 'd', version: '2.5.0')
      end

      context 'when the released metadata constrains a pinned dependency' do
        let(:release_metadata) { "depends 'd', '>= 2.0'\ndepends 'p', '~> 1.0'\n" }

        it 'moves the pin to meet it' do
          env_pins['production']['d'] = '= 1.5.0'
          stub_pr_files("+depends 'p', '~> 1.0'\n")
          stub_cookbook_versions('p', %w(1.0.0))
          stub_cookbook_versions('d', %w(1.5.0 2.0.0))
          stub_version_deps('p', '1.0.0', 'd' => '>= 1.0')
          universe['d'] = { '1.5.0' => {} }

          expect(release).to include(name: 'd', version: '2.0.0')
        end
      end

      # y 1.0.0 holds a below 2.0, which would be a downgrade from the pinned
      # 1.5.0; but a 2.0.0 re-pins y, after which nothing holds it back.
      it 'tries the newer version a downgrade conflict points at' do
        env_pins.replace('one' => { 'a' => '= 1.5.0' }, 'two' => { 'y' => '= 1.0.0' })
        stub_pr_files("+depends 'a', '>= 1.0'\n")
        stub_cookbook_versions('a', %w(1.0.0 2.0.0))
        stub_cookbook_versions('y', %w(1.0.0 2.0.0))
        stub_version_deps('a', '2.0.0', 'y' => '>= 2.0')
        universe['a'] = { '1.5.0' => {} }
        universe['y'] = { '1.0.0' => { 'dependencies' => { 'a' => '< 2.0' } } }

        expect(release).to contain_exactly({ name: 'a', version: '2.0.0' }, { name: 'y', version: '2.0.0' })
      end

      # The first pass falls back to a 2.0.0, whose z '>= 5.0' does not
      # exist; the next pass excludes y and settles on a 1.0.0.
      it 'does not let a fallback version\'s missing dependency end the run' do
        env_pins['production'].merge!('y' => '= 1.0.0', 'w' => '= 1.0.0')
        stub_pr_files("+depends 'b', '>= 1.0'\n+depends 'a', '>= 1.0'\n")
        stub_cookbook_versions('a', %w(1.0.0 2.0.0))
        stub_cookbook_versions('b', %w(1.0.0))
        stub_cookbook_versions('y', %w(1.0.0 2.0.0))
        stub_cookbook_versions('z', %w(4.0.0))
        stub_version_deps('a', '2.0.0', 'z' => '>= 5.0')
        stub_version_deps('b', '1.0.0', 'y' => '>= 2.0')
        universe['y'] = { '1.0.0' => { 'dependencies' => { 'a' => '< 1.0' } } }
        universe['w'] = { '1.0.0' => { 'dependencies' => { 'a' => '< 2.0' } } }

        expect(release).to contain_exactly({ name: 'a', version: '1.0.0' }, { name: 'b', version: '1.0.0' },
                                           { name: 'y', version: '2.0.0' })
      end

      # a 1.0.0 re-pins y, after which a 2.0.0 is allowed, which no longer
      # re-pins y: the passes alternate, and say so.
      it 'reports going round in a cycle' do
        env_pins['production']['y'] = '= 1.0.0'
        stub_pr_files("+depends 'a', '>= 1.0'\n")
        stub_cookbook_versions('a', %w(1.0.0 2.0.0))
        stub_cookbook_versions('y', %w(1.0.0 2.0.0))
        stub_version_deps('a', '1.0.0', 'y' => '>= 2.0')
        universe['y'] = { '1.0.0' => { 'dependencies' => { 'a' => '< 2.0' } } }

        expect { release }.to raise_error(CommunityDeps::Error, /went round in a cycle without settling/)
      end

      # Every release is checked, not only those that move a community pin.
      context 'when the release raises an org constraint past what is pinned' do
        let(:release_metadata) { "name 'osl-apache'\nversion '2.3.4'\ndepends 'osl-repos', '>= 3.0'\n" }

        it 'refuses it' do
          env_pins['production']['osl-repos'] = '= 2.0.0'
          universe['osl-repos'] = { '2.0.0' => {} }
          stub_pr_files("-depends 'osl-repos', '>= 2.0'\n+depends 'osl-repos', '>= 3.0'\n")

          expect { release }.to raise_error(CommunityDeps::Error) { |e|
            expect(e.message).to include('releasing osl-apache 2.4.0 would make these chef-repo environments ' \
                                         "fail env-pin-check:\n- production: osl-apache 2.4.0 depends on " \
                                         'osl-repos (>= 3.0) but the environment resolves osl-repos 2.0.0')
          }
        end
      end

      # Resolution never looks at org cookbooks; the landing check does.
      it 'refuses a new version needing a newer org cookbook than is pinned' do
        env_pins['production']['osl-repos'] = '= 2.0.0'
        stub_pr_files("+depends 'p', '~> 1.0'\n")
        stub_cookbook_versions('p', %w(1.0.0))
        stub_version_deps('p', '1.0.0', 'osl-repos' => '>= 3.0')
        universe['osl-repos'] = { '2.0.0' => {} }

        expect { release }.to raise_error(CommunityDeps::Error) { |e|
          expect(e.message).to include("would make these chef-repo environments fail env-pin-check:\n" \
                                       '- production: p 1.0.0 depends on osl-repos (>= 3.0) but the ' \
                                       'environment resolves osl-repos 2.0.0 (once it merges)')
        }
        expect(shell_calls).to be_empty
      end
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

      # The isc_kea -> chef_auto_accumulator case: uploading the direct dep
      # before its missing dependency is resolved makes knife refuse it.
      it 'uploads a direct dep together with its missing transitive deps' do
        stub_version_deps('postfix', '6.1.8', 'yum-epel' => '>= 4.0')
        stub_cookbook_versions('yum-epel', %w(5.0.0))
        stub_version_deps('yum-epel', '5.0.0')

        deps.call('osuosl-cookbooks/osl-apache', 42)
        uploads = shell_calls.select { |c| c[0, 3] == %w(knife cookbook upload) }
        expect(uploads.length).to eq(1)
        expect(uploads.first).to include('postfix', 'yum-epel')
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

      # The second pass resolves yum-epel with yum's '< 5.0' up front, and
      # nothing satisfies both.
      it 'raises on requirements no version satisfies together' do
        stub_version_deps('postfix', '6.1.8', 'yum-epel' => '>= 4.0', 'yum' => '>= 0')
        stub_cookbook_versions('yum-epel', %w(5.0.0))
        stub_version_deps('yum-epel', '5.0.0')
        stub_cookbook_versions('yum', %w(7.4.13))
        stub_version_deps('yum', '7.4.13', 'yum-epel' => '< 5.0')

        expect { deps.call('osuosl-cookbooks/osl-apache', 42) }
          .to raise_error(CommunityDeps::Error,
                          /no version of 'yum-epel' satisfies '(>= 4\.0, < 5\.0|< 5\.0, >= 4\.0)'/)
      end

      it 'uploads nothing when resolution fails partway through' do
        stub_version_deps('postfix', '6.1.8', 'yum-epel' => '>= 4.0', 'yum' => '>= 0')
        stub_cookbook_versions('yum-epel', %w(5.0.0))
        stub_version_deps('yum-epel', '5.0.0')
        stub_cookbook_versions('yum', %w(7.4.13))
        stub_version_deps('yum', '7.4.13', 'yum-epel' => '< 5.0')

        expect { deps.call('osuosl-cookbooks/osl-apache', 42) }.to raise_error(CommunityDeps::Error)
        expect(shell_calls).to be_empty
      end
    end
  end
end
