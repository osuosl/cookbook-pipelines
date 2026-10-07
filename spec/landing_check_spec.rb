require_relative 'spec_helper'
require_relative '../lib/landing_check'

RSpec.describe LandingCheck do
  # The Chef server: base 9.16.3 needs certificate '~> 2.0.2'.
  let(:universe) do
    {
      'base' => { '9.16.3' => { 'dependencies' => { 'certificate' => '~> 2.0.2' } } },
      'certificate' => { '2.0.4' => { 'dependencies' => {} }, '3.0.0' => { 'dependencies' => {} } },
      'osl-repos' => { '2.0.0' => { 'dependencies' => {} } },
    }
  end

  def check(uploads: {}, release: nil, pins: {})
    described_class.new(universe: universe, uploads: uploads, release: release, pins: pins)
  end

  def env(pins, selected: true, addable: true)
    { selected: selected, addable: addable, pins: pins }
  end

  it 'passes a release that breaks nothing' do
    expect(check(uploads: { 'certificate' => { '2.0.5' => {} } }, pins: { 'certificate' => '2.0.5' })
      .problems('production' => env({ 'base' => '= 9.16.3', 'certificate' => '= 2.0.4' }))).to be_empty
  end

  it 'reports a new pin a pinned cookbook rejects' do
    expect(check(pins: { 'certificate' => '3.0.0' })
      .problems('production' => env({ 'base' => '= 9.16.3', 'certificate' => '= 2.0.4' })))
      .to eq(['production: base 9.16.3 depends on certificate (~> 2.0.2) but the environment resolves ' \
              'certificate 3.0.0 (once it merges)'])
  end

  # chef-repo CI floats d to the newest version a's edge allows, then fails
  # p's, though d 1.0.0 would have suited both.
  it 'floats unpinned dependencies exactly as env-pin-check does' do
    universe['a'] = { '1.0.0' => { 'dependencies' => { 'd' => '>= 1.0' } } }
    universe['d'] = { '1.0.0' => {}, '2.0.0' => {} }
    uploads = { 'p' => { '1.0.0' => { 'd' => '< 2.0' } } }

    expect(check(uploads: uploads, pins: { 'p' => '1.0.0' }).problems('production' => env({ 'a' => '= 1.0.0' })))
      .to eq(['production: p 1.0.0 depends on d (< 2.0) but the environment resolves d 2.0.0 (once it merges)'])
  end

  # The server is shared: d 3.0.0 becomes what d floats to everywhere, even
  # where nothing is pinned, and even while the bump PR is still open.
  context 'when an upload changes what an unpinned dependency floats to' do
    let(:uploads) { { 'd' => { '3.0.0' => { 'e' => '>= 5' } } } }
    let(:pins) { { 'p' => '= 1.0.0', 'q' => '= 1.0.0' } }

    before do
      universe['p'] = { '1.0.0' => { 'dependencies' => { 'd' => '>= 0' } } }
      universe['q'] = { '1.0.0' => { 'dependencies' => { 'e' => '~> 1.0' } } }
      universe['d'] = { '2.0.0' => {} }
      universe['e'] = { '1.0.0' => {}, '5.0.0' => {} }
    end

    it 'checks environments the release does not select' do
      expect(check(uploads: uploads, pins: { 'd' => '3.0.0' })
        .problems('workstation' => env(pins, selected: false, addable: false)))
        .to eq(['workstation: d 3.0.0 depends on e (>= 5) but the environment resolves e 1.0.0 ' \
                '(until the bump PR merges, once it merges, if the merge fails)'])
    end

    # Comparing against the server as it is, not with the upload already on
    # it, is what makes this a new error rather than an old one. Once d is
    # pinned, the re-sorted file walks d before q, so q's edge is what fails.
    it 'reports it where the release lands too' do
      expect(check(uploads: uploads, pins: { 'd' => '3.0.0' }).problems('production' => env(pins)))
        .to contain_exactly(a_string_including('d 3.0.0 depends on e (>= 5)', 'until the bump PR merges'),
                            a_string_including('q 1.0.0 depends on e (~> 1.0)', '(once it merges)'))
    end
  end

  # osl-rt's new version is what an unpinned osl-rt floats to.
  it 'checks the release\'s own new version where it floats' do
    universe['osl-foo'] = { '1.0.0' => { 'dependencies' => { 'osl-rt' => '>= 0' } } }
    universe['osl-rt'] = { '1.0.0' => { 'dependencies' => {} } }
    release = ['osl-rt', '1.1.0', { 'osl-repos' => '>= 3.0' }]

    expect(check(release: release, pins: { 'osl-rt' => '1.1.0' })
      .problems('workstation' => env({ 'osl-foo' => '= 1.0.0', 'osl-repos' => '= 2.0.0' }, selected: false)))
      .to eq(['workstation: osl-rt 1.1.0 depends on osl-repos (>= 3.0) but the environment resolves ' \
              'osl-repos 2.0.0 (until the bump PR merges, once it merges)'])
  end

  it 'checks constraints on the releasing cookbook itself' do
    universe['osl-admin'] = { '1.0.0' => { 'dependencies' => { 'osl-rt' => '< 4.1' } } }
    universe['osl-rt'] = { '4.0.0' => { 'dependencies' => {} } }

    expect(check(release: ['osl-rt', '4.1.0', {}], pins: { 'osl-rt' => '4.1.0' })
      .problems('production' => env({ 'osl-admin' => '= 1.0.0', 'osl-rt' => '= 4.0.0' })))
      .to eq(['production: osl-admin 1.0.0 depends on osl-rt (< 4.1) but the environment resolves ' \
              'osl-rt 4.1.0 (once it merges)'])
  end

  it 'writes pins only where the environment bumper would' do
    expect(check(pins: { 'certificate' => '3.0.0' })
      .problems('openstack-rdo' => env({ 'base' => '= 9.16.3', 'certificate' => '= 2.0.4' }, selected: false),
                'phpbb' => env({ 'base' => '= 9.16.3' }, addable: false)))
      .to be_empty
  end

  it 'walks floating chains to any depth' do
    universe['p'] = { '1.0.0' => { 'dependencies' => { 'f1' => '>= 0' } } }
    (1..11).each { |i| universe["f#{i}"] = { '1.0.0' => { 'dependencies' => { "f#{i + 1}" => '>= 0' } } } }
    universe['f12'] = { '1.0.0' => { 'dependencies' => { 'z' => '>= 9' } } }
    universe['z'] = { '9.0.0' => {} }

    expect(check(uploads: { 'z' => { '1.0.0' => {} } }, pins: { 'z' => '1.0.0' })
      .problems('production' => env({ 'p' => '= 1.0.0', 'z' => '= 9.0.0' })))
      .to eq(['production: f12 1.0.0 depends on z (>= 9) but the environment resolves z 1.0.0 (once it merges)'])
  end

  # Its old error is not the release's; the new one is, and would outlive
  # chef-repo fixing the old one.
  it 'reports a new error in an environment that already fails' do
    expect(check(pins: { 'certificate' => '3.0.0' })
      .problems('production' => env({ 'base' => '= 9.16.3', 'certificate' => '= 2.0.4',
                                      'osl-repos' => '= 9.9.9', })))
      .to eq(['production: base 9.16.3 depends on certificate (~> 2.0.2) but the environment resolves ' \
              'certificate 3.0.0 (once it merges)'])
  end

  # Until the chain PR merges, the Chef server and every other chef-repo PR
  # see the default branch's pins, not the chain's.
  context 'when the release joins a chain' do
    before do
      universe['osl-foo'] = { '1.0.0' => { 'dependencies' => {} }, '2.0.0' => { 'dependencies' => {} } }
      universe['osl-base'] = { '1.0.0' => { 'dependencies' => { 'osl-bar' => '>= 0' } } }
      universe['osl-bar'] = { '1.0.0' => { 'dependencies' => {} } }
    end

    let(:release) { ['osl-bar', '1.1.0', { 'osl-foo' => '>= 2.0' }] }
    let(:chained) do
      env({ 'osl-base' => '= 1.0.0', 'osl-foo' => '= 2.0.0' }, addable: false)
        .merge(live: { 'osl-base' => '= 1.0.0', 'osl-foo' => '= 1.0.0' })
    end

    it 'checks the interim state against the live pins' do
      expect(check(release: release, pins: { 'osl-bar' => '1.1.0' }).problems('production' => chained))
        .to eq(['production: osl-bar 1.1.0 depends on osl-foo (>= 2.0) but the environment resolves ' \
                'osl-foo 1.0.0 (until the bump PR merges)'])
    end

    it 'checks the merged state against the chain\'s pins' do
      chained[:live] = chained[:pins]
      expect(check(release: release, pins: { 'osl-bar' => '1.1.0' }).problems('production' => chained)).to be_empty
    end
  end

  # The environment bumper only re-sorts a file it changes, and env-pin-check
  # walks pins in file order.
  it 'keeps the order of a file the bump leaves alone' do
    universe['a'] = { '1.0.0' => { 'dependencies' => { 'd' => '>= 1.0' } } }
    universe['z'] = { '1.0.0' => { 'dependencies' => { 'd' => '< 2.0' } } }
    universe['d'] = { '1.0.0' => {}, '2.0.0' => {} }
    unsorted = { 'z' => '= 1.0.0', 'a' => '= 1.0.0' }

    expect(check(pins: { 'certificate' => '2.0.4' }).problems('production' => env(unsorted, addable: false)))
      .to be_empty
    expect(check(pins: { 'certificate' => '2.0.4' }).problems('production' => env(unsorted)))
      .to eq(['production: z 1.0.0 depends on d (< 2.0) but the environment resolves d 2.0.0 (once it merges)'])
  end

  # LandingCheck#errors is a port of chef-repo's scripts/env-pin-check.rb,
  # and must give its exact answers. CI has no chef-repo checkout, so they
  # are recorded in a fixture; where chef-repo is checked out alongside, the
  # fixture is re-derived from the script itself, so a change to it fails
  # here until the port (and the fixture) follow.
  describe 'agreement with env-pin-check' do
    let(:golden) { JSON.parse(File.read(File.join(__dir__, 'fixtures', 'env_pin_check_golden.json'))) }

    it 'gives the recorded results' do
      golden['cases'].each do |c|
        expect(check.errors(c['pins'], golden['universe'])).to eq(c['errors']), "for pins #{c['pins']}"
      end
    end

    env_pin_check = File.expand_path('../../chef-repo/scripts/env-pin-check.rb', __dir__)
    it 'records what chef-repo\'s env-pin-check says today', if: File.exist?(env_pin_check) do
      load env_pin_check
      golden['cases'].each do |c|
        actual = EnvPinCheck.new(golden['universe']).check('cookbook_versions' => c['pins'])[:errors]
        expect(actual.map { |e| e.sub(/ \(newest: .*\)\z/, '') }).to eq(c['errors']), "for pins #{c['pins']}"
      end
    end
  end
end
