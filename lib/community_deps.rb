require 'json'
require 'mixlib/shellout'
require 'net/http'
require 'tmpdir'

require_relative 'landing_check'

# Detects community cookbook dependency changes in a PR about to be released,
# and uploads the newly required versions to the Chef server.
#
# A dependency is "community" when no repo of the same name exists in the
# GitHub org (org repos release through their own bump pipeline). Community
# cookbooks are never shared to the local supermarket - that holds only org
# cookbooks.
#
# A community cookbook's pin is shared by every environment that pins it, and
# every cookbook pinned alongside it may constrain it (base, its osl-* wrapper,
# a handful of others). So a release moves a pin only when its own metadata.rb
# constrains that cookbook, and only to the newest version that constraint and
# every cookbook pinned in the environments the release lands in accept
# (their constraints come from /universe, for the exact versions pinned; the
# releasing cookbook's come from the metadata.rb being released). Nothing
# satisfying all of them, or the result being lower than a current pin, stops
# the release before merge. An unconstrained `depends` takes no
# position on the version: it never moves a pin, and resolves only when the
# server has no version at all. A version already present on the Chef server
# is skipped and treated as success so its environment pin still updates.
#
# The dependency graph of everything resolved is then walked (the public
# Supermarket knows each version's dependencies). A transitive community
# dependency is left alone when its current pins already meet what the new
# versions need and, wherever it floats, the server has a version everything
# there accepts; otherwise it is resolved, uploaded and pinned the same way.
#
# Which cookbooks a run re-pins, and what their new versions need of each
# other, is only known once that walk has run, yet resolving each of them
# depends on both. So resolution runs in passes, each starting from what the
# previous one found, until a pass finds exactly what it started from.
#
# Resolution is a best effort, so the release as a whole - its own new
# version included, whether or not any community pin moves - is then checked
# on its own terms: LandingCheck refuses it if any chef-repo environment
# would newly fail env-pin-check.
#
# Nothing is uploaded until the whole closure is resolved, and then it all
# goes up in one knife call: knife refuses a cookbook whose dependencies are
# neither on the server nor part of the same upload, so uploading a direct
# dependency ahead of its own missing dependencies always fails.
class CommunityDeps
  class Error < StandardError
  end

  DEPENDS_RE = /\Adepends\s+(["'])([^"']+)\1(?:\s*,\s*(["'])([^"']+)\3)?/

  # Resolution passes before giving up on settling.
  MAX_PASSES = 6

  # The Chef server's full version index, fetched with the pipeline's knife
  # credentials. Injectable for tests.
  #
  # /universe is not among the endpoints the server maps onto its default
  # org, so unlike `knife cookbook upload` this only works when knife.rb's
  # chef_server_url carries the /organizations/<org> path - hence the hint.
  DEFAULT_SERVER_UNIVERSE = lambda do
    knife = Mixlib::ShellOut.new('knife', 'raw', '/universe').run_command
    if knife.error?
      detail = [knife.stderr, knife.stdout].map(&:strip).reject(&:empty?).join("\n")
      raise Error, 'failed to fetch /universe from the chef server ' \
                   "(does knife.rb's chef_server_url include /organizations/<org>?):\n#{detail}"
    end

    CommunityDeps.parse_universe(knife.stdout)
  end

  # knife's own log lines share stdout with the JSON when knife.rb sets
  # `log_location STDOUT` (the Jenkins controller's does), and the
  # "Using configuration from" line is emitted before any option could
  # redirect it. Skip ahead to the document rather than parse the noise.
  def self.parse_universe(output)
    json = output[/^[\[{].*/m]
    raise Error, "knife raw /universe returned no JSON:\n#{output.strip}" unless json

    JSON.parse(json)
  rescue JSON::ParserError => e
    raise Error, "could not parse /universe from the chef server: #{e.message}"
  end

  def initialize(github:, org:, public_supermarket:, shell:, do_not_upload: false,
                 server_universe: nil, out: $stdout)
    @github = github
    @org = org
    @public_supermarket = public_supermarket
    @do_not_upload = do_not_upload
    @shell = shell
    @server_universe_fetcher = server_universe || DEFAULT_SERVER_UNIVERSE
    @out = out
    @left_alone = []
  end

  # Names of the unconstrained dependencies the last #call did not re-pin.
  attr_reader :left_alone

  # Returns [{name:, version:}] for every community dependency the PR
  # changed that needs a new pin, plus every transitive community dependency
  # underneath them that needs one. head_sha is the commit being released,
  # whose metadata.rb constrains everything alongside it; next_version maps
  # that metadata.rb's content to the version the release will bump to (and
  # raises if it has none). env_pins returns { env_name => { selected:,
  # addable:, pins:, live: } } for every chef-repo environment.
  def call(repo_path, pr_number, head_sha: nil, next_version: nil, env_pins: -> { {} })
    @repo_path = repo_path
    @releasing = repo_path.split('/').last
    @head_sha = head_sha
    @next_version = next_version
    @release_metadata = nil
    @release_depends = nil
    @env_pins = env_pins
    @selected_envs = nil
    @all_envs = nil
    changed = changed_constraints(repo_path, pr_number).select { |name, _| community?(name) }
    moving, unconstrained = changed.partition { |name, constraint| constraint || !server_satisfies?(name, nil) }
    cookbooks = settle(moving)
    verify_landing!(cookbooks)
    @left_alone = unconstrained.map(&:first) - cookbooks.map { |c| c[:name] }
    @left_alone.each do |name|
      @out.puts "#{name} has no version constraint here and is already on the Chef server; not re-pinning it."
    end
    upload(cookbooks)
    cookbooks
  end

  # Parse the PR's metadata.rb patch for depends lines that were added or
  # whose constraint changed. Returns [[name, constraint-or-nil], ...].
  def changed_constraints(repo_path, pr_number)
    metadata = @github.pull_request_files(repo_path, pr_number).find { |f| f.filename == 'metadata.rb' }
    return [] unless metadata&.patch

    added = depends_in(metadata.patch, '+')
    removed = depends_in(metadata.patch, '-')
    added.reject { |dep| removed.include?(dep) }
  end

  def community?(name)
    @community ||= {}
    @community.fetch(name) { @community[name] = !@github.repository?("#{@org}/#{name}") }
  end

  # Upload [{name:, version:}] to the Chef server in a single knife call so
  # cookbooks that depend on one another satisfy each other's dependency
  # check.
  def upload(cookbooks)
    cookbooks.each { |c| @out.puts "Uploading community cookbook #{c[:name]} #{c[:version]}..." }
    return if @do_not_upload

    # The resolved version being on the Chef server already is the routine
    # case (another cookbook's bump uploaded it, or a re-run). Re-uploading a
    # frozen version exits non-zero, and the failure would also drop the dep
    # from the environment pin update - so an existing version is success,
    # not an error.
    missing = cookbooks.reject do |c|
      next false unless uploaded?(c[:name], c[:version])

      @out.puts "#{c[:name]} #{c[:version]} is already on the Chef server, skipping upload."
      true
    end
    return if missing.empty?

    Dir.mktmpdir('community-') do |dir|
      missing.each do |c|
        tarball = File.join(dir, "#{c[:name]}.tar.gz")
        @shell.call('knife', 'supermarket', 'download', c[:name], c[:version], '-m', @public_supermarket,
                    '-f', tarball)
        @shell.call('tar', '-xzf', tarball, '-C', dir)
      end
      @shell.call('knife', 'cookbook', 'upload', *missing.map { |c| c[:name] }, '--freeze', '-o', dir)
    end
  end

  # Whether this exact cookbook version already exists on the Chef server.
  def uploaded?(name, version)
    @shell.call('knife', 'cookbook', 'show', name, version)
    true
  rescue StandardError
    false
  end

  private

  # Run resolution passes until one finds exactly what it started from: the
  # cookbooks it re-pins (whose current pins then hold nothing back, and
  # whose environments matter) and what the chosen versions need of each
  # other. A conflict doesn't stop a pass - it is recorded and the pass goes
  # on with the best version it can, so every pass learns the whole shape and
  # its findings replace what came before. Only a settled pass is trusted:
  # its first conflict is the error, or its cookbooks are the answer. Coming
  # back round to an earlier start is treated as having no answer, though
  # one may exist that these passes cannot reach.
  def settle(moving)
    learned = { repinned: moving.map(&:first).sort, needs: {} }
    tried = []
    last_error = nil
    MAX_PASSES.times do
      cookbooks = begin
        resolve_pass(moving, learned)
      rescue Error
        @pass_warnings.each { |w| @out.puts w }
        raise
      end
      outcome = pass_outcome
      last_error = @conflicts.first || last_error
      settled = outcome == learned
      if settled || tried.include?(outcome)
        @pass_warnings.each { |w| @out.puts w }
        return cookbooks if settled && @conflicts.empty?

        raise(settled ? @conflicts.first : last_error || unsettled('went round in a cycle'))
      end
      tried << learned
      learned = outcome
    end
    raise(last_error || unsettled("ran #{MAX_PASSES} passes"))
  end

  def unsettled(why)
    Error.new("community dependency resolution #{why} without settling; pin these by hand in chef-repo")
  end

  # What a pass actually re-pinned and what the versions it chose need.
  def pass_outcome
    needs = @needs_seen.reject { |_, v| v.empty? }.transform_values { |v| v.uniq.sort }
    { repinned: @repinned.uniq.sort, needs: needs }
  end

  # One resolution of the direct dependencies and their closure, starting
  # from what the previous pass found: cookbooks it re-pinned (@excluded) and
  # what its versions needed (@needs). Conflicts land in @conflicts.
  def resolve_pass(moving, learned)
    @excluded = learned[:repinned]
    @needs = learned[:needs]
    @repinned = moving.map(&:first)
    @needs_seen = Hash.new { |h, k| h[k] = [] }
    @conflicts = []
    @pass_warnings = []
    direct = moving.map do |name, constraint|
      { name: name, version: resolve_accepted(name, [constraint].compact, @needs.fetch(name, [])) }
    end
    direct + transitive_closure(direct)
  end

  # Walk the dependency graph of everything resolved and collect every
  # community dependency the current pins cannot already satisfy. Constraints
  # from every dependent of a missing cookbook are merged; a conflicting
  # requirement on something already resolved is recorded, and the next pass
  # resolves with it up front.
  def transitive_closure(seed)
    resolved = seed.to_h { |c| [c[:name], c[:version]] }
    added = []
    queue = seed.map { |c| c[:name] }
    until queue.empty?
      name = queue.shift
      (unless_conflicted { dependencies_of(name, resolved.fetch(name)) } || {}).each do |dep, constraint|
        @needs_seen[dep] << constraint if constraint
        if resolved.key?(dep)
          verify_resolved(dep, resolved[dep], constraint)
          next
        end
        next if org_dependency?(dep) # its own pipeline releases it
        next if pins_satisfy?(dep, constraint)

        @repinned << dep
        version = unless_conflicted { resolve_accepted(dep, @needs_seen[dep].dup, @needs.fetch(dep, [])) }
        next unless version

        resolved[dep] = version
        added << { name: dep, version: version }
        queue << dep
      end
    end
    added
  end

  # Once a pass has a conflict it is walking fallback versions the answer may
  # never use, so a hard error there (a missing or deprecated cookbook only a
  # fallback needs) is recorded like any conflict instead of ending the run.
  def unless_conflicted
    yield
  rescue Error => e
    raise if @conflicts.empty?

    @conflicts << e
    nil
  end

  # Dependency constraints of a specific cookbook version, from the public
  # supermarket (versions are underscored in its URLs).
  def dependencies_of(name, version)
    fetch_json("#{@public_supermarket}/api/v1/cookbooks/#{name}/versions/#{version.tr('.', '_')}")
      .fetch('dependencies', {}) || {}
  end

  def verify_resolved(name, version, constraint)
    return if constraint.nil? || Gem::Requirement.new(constraint).satisfied_by?(Gem::Version.new(version))

    @conflicts << Error.new("conflicting requirements: #{name} #{version} was resolved but another " \
                            "dependency needs #{constraint}")
  end

  # An org cookbook found transitively is never uploaded here - it releases
  # through its own pipeline - but the server having no version of it at all
  # is worth a loud warning, since nothing else will say so until converge.
  def org_dependency?(name)
    return false if community?(name)

    warning = "WARNING: #{name} is an org cookbook the Chef server does not have; release it first."
    @pass_warnings << warning if (server_universe[name] || {}).empty? && !@pass_warnings.include?(warning)
    true
  end

  # All versions of a cookbook on the public supermarket. A DEPRECATED
  # cookbook stops the release outright: knife refuses to download one anyway
  # (while exiting 0, leaving a baffling tar error), and silently building on
  # abandoned cookbooks is how they fossilize into the infrastructure. Upload
  # it by hand if it is genuinely still wanted.
  def supermarket_versions(name)
    body = fetch_json("#{@public_supermarket}/api/v1/cookbooks/#{name}")
    if body['deprecated']
      replacement = body['replacement'] ? "replacement: #{body['replacement']}" : 'no replacement defined'
      raise Error, "'#{name}' is DEPRECATED on the public supermarket (#{replacement}). " \
                   'Not uploading it automatically - migrate off it, or upload it manually ' \
                   'if it is still needed.'
    end
    body['versions'].map { |url| Gem::Version.new(url.split('/').last.tr('_', '.')) }
  end

  def newest(versions, constraints)
    requirement = Gem::Requirement.new(constraints)
    versions.select { |v| requirement.satisfied_by?(v) }.max
  end

  # The newest version that own (this pass's constraints on name), what the
  # previous pass found the new versions need, and every cookbook pinned
  # alongside accept, refusing anything below a current pin: downgrading a
  # shared pin is a deliberate chef-repo change, not a side effect of a
  # release. Nothing matching own at all is final; any other conflict is
  # recorded and the newest version own allows stands in for the pass.
  def resolve_accepted(name, own, needs)
    own = ['>= 0'] if own.empty?
    versions = supermarket_versions(name)
    fallback = newest(versions, own)
    raise Error, "no version of '#{name}' satisfies '#{own.join(', ')}'" unless fallback

    constraints = own | needs
    unless newest(versions, constraints)
      @conflicts << Error.new("no version of '#{name}' satisfies '#{constraints.join(', ')}'")
      return fallback.to_s
    end

    holders = holders_of(name)
    version = newest(versions, constraints + holders.values)
    unless version
      @conflicts << holder_conflict(name, versions, constraints, holders)
      return newest(versions, constraints).to_s
    end
    # A downgrade is refused, but the newest version the release itself
    # accepts may re-pin whatever forced it down, so the pass goes on with it.
    return newest(versions, constraints).to_s if downgrade?(name, version)

    version.to_s
  end

  # Name the cookbooks that conflict on their own; when only the combination
  # does, every holder is part of the problem.
  def holder_conflict(name, versions, constraints, holders)
    blockers = holders.select { |_, c| newest(versions, constraints + [c]).nil? }.keys
    blockers = holders.keys if blockers.empty?
    Error.new("no version of #{name} satisfies '#{constraints.join(', ')}' and what the cookbooks pinned " \
              "alongside it need: #{blockers.join('; ')}. Loosen those first, then re-apply the bump label.")
  end

  # { "cookbook version needs name constraint (envs)" => constraint } for
  # every cookbook in envs (by default, wherever name's pin matters) that
  # constrains name. Pinned cookbooks' constraints come from /universe
  # (which reports an unconstrained depends as '>= 0.0.0', accepting
  # everything); the releasing cookbook's come from the metadata.rb being
  # released, wherever it lands - its pinned version is what this release
  # replaces, as is anything else the pass started out re-pinning.
  def holders_of(name, envs = landing_for(name))
    holders = Hash.new { |h, k| h[k] = [] }
    envs.each do |env, entry|
      release_requirement(name, entry).each { |own| holders[["#{@releasing} (this release)", own]] << env }
      entry[:pins].each do |pinned, pin|
        next if pinned == @releasing || @excluded.include?(pinned)

        version = pinned_version(pinned, pin)
        constraint = version && server_universe.dig(pinned, version.to_s, 'dependencies', name)
        holders[["#{pinned} #{version}", constraint]] << env if constraint && constraint != '>= 0.0.0'
      end
    end
    holders.to_h do |(holder, constraint), holder_envs|
      ["#{holder} needs #{name} #{constraint} (#{holder_envs.join(', ')})", constraint]
    end
  end

  # The metadata.rb being released, or nil without a head commit.
  def release_metadata
    return nil unless @head_sha

    @release_metadata ||= @github.contents(@repo_path, path: 'metadata.rb', ref: @head_sha).content.unpack1('m')
  end

  # { name => constraint-or-nil } from the depends lines of the metadata.rb
  # being released.
  def release_depends
    @release_depends ||= (release_metadata || '').each_line.filter_map do |line|
      match = DEPENDS_RE.match(line.strip)
      [match[2], match[4]] if match
    end.to_h
  end

  # [name, version, dependencies] for the releasing cookbook's new version,
  # or nil when it can't be known (no head commit or version bump given).
  def release_artifact
    return nil unless release_metadata && @next_version

    [@releasing, @next_version.call(release_metadata), release_depends.transform_values { |c| c || '>= 0' }]
  end

  # The release's own constraint on name, where it lands in this environment.
  def release_requirement(name, entry)
    own = release_depends[name]
    own && (entry[:addable] || entry[:pins].key?(@releasing)) ? [own] : []
  end

  def downgrade?(name, version)
    lower = landing_for(name).filter_map do |env, entry|
      pins = entry[:pins]
      pinned = pins.key?(name) && pinned_version(name, pins[name])
      "#{pinned} in #{env}" if pinned && pinned > version
    end
    return false if lower.empty?

    @conflicts << Error.new("#{name} #{version} is the newest version everything accepts, which would " \
                            "downgrade its pin from #{lower.join(', ')}. Downgrade it in chef-repo by hand " \
                            'if that is intended.')
    true
  end

  # Whether nothing needs to move for name: every current pin meets all that
  # this pass and the last found the new versions need of it (and the
  # release's own constraint where it lands), and wherever name floats (or no
  # environment is selected at all) the server has a version that all of
  # that and everything pinned there accepts.
  def pins_satisfy?(name, constraint)
    wanted = [constraint].compact | @needs_seen[name] | @needs.fetch(name, [])
    wanted = ['>= 0'] if wanted.empty?
    envs = landing_for(name)
    floating = {}
    envs.each do |env, entry|
      pinned = entry[:pins].key?(name) && pinned_version(name, entry[:pins][name])
      if pinned
        return false unless Gem::Requirement.new(wanted + release_requirement(name, entry)).satisfied_by?(pinned)
      else
        floating[env] = entry
      end
    end
    return true if floating.empty? && !envs.empty?

    server_satisfies?(name, wanted + holders_of(name, floating).values)
  end

  # Refuse the release if, with what it uploads and the pins the environment
  # bumper will write, any chef-repo environment would newly fail
  # env-pin-check. Uploads are the community versions the server lacks, with
  # their Supermarket dependencies; those it has keep the server's own.
  def verify_landing!(cookbooks)
    return if all_envs.empty?

    uploads = cookbooks.reject { |c| (server_universe[c[:name]] || {}).key?(c[:version]) }
                       .to_h { |c| [c[:name], { c[:version] => dependencies_of(c[:name], c[:version]) }] }
    release = release_artifact
    pins = cookbooks.to_h { |c| [c[:name], c[:version]] }
    pins[release[0]] = release[1] if release
    problems = LandingCheck.new(universe: server_universe, uploads: uploads, release: release, pins: pins)
                           .problems(all_envs)
    return if problems.empty?

    what = pins.map { |name, version| "#{name} #{version}" }.join(', ')
    raise Error, "releasing #{what.empty? ? @releasing : what} would make these chef-repo environments fail " \
                 "env-pin-check:\n#{problems.map { |p| "- #{p}" }.join("\n")}"
  end

  # The newest server version an environment pin selects, as chef-repo's
  # env-pin-check resolves it; nil when the server has none.
  def pinned_version(name, pin)
    newest((server_universe[name] || {}).keys.map { |v| Gem::Version.new(v) }, pin)
  end

  # { env_name => { addable:, pins: } } for the selected environments where
  # name's pin matters. The environment bumper updates every cookbook in the
  # bump wherever it is already pinned (even under 'all', where the releasing
  # cookbook may not be) and adds it where addable; and wherever anything
  # this run pins lands, name floats there if unpinned and must still satisfy
  # everything pinned alongside.
  def landing_for(name)
    moving = [@releasing, name] + @excluded
    selected_envs.select { |_, entry| entry[:addable] || moving.any? { |c| entry[:pins].key?(c) } }
  end

  def selected_envs
    @selected_envs ||= all_envs.select { |_, entry| entry[:selected] }
  end

  def all_envs
    @all_envs ||= @env_pins.call
  end

  def server_satisfies?(name, constraint)
    requirement = Gem::Requirement.new(Array(constraint || '>= 0'))
    (server_universe[name] || {}).keys.any? { |v| requirement.satisfied_by?(Gem::Version.new(v)) }
  end

  def server_universe
    @server_universe ||= @server_universe_fetcher.call
  end

  def depends_in(patch, sign)
    patch.each_line.filter_map do |line|
      next unless line.start_with?(sign)

      match = DEPENDS_RE.match(line[1..].strip)
      [match[2], match[4]] if match
    end
  end

  # Memoized: resolution passes revisit the same cookbooks and versions.
  def fetch_json(url)
    @fetched ||= {}
    @fetched[url] ||= fetch_json_uncached(url)
  end

  def fetch_json_uncached(url, redirects_left = 3)
    response = Net::HTTP.get_response(URI(url))
    if response.is_a?(Net::HTTPRedirection) && redirects_left.positive?
      return fetch_json_uncached(response['location'], redirects_left - 1)
    end
    raise Error, "supermarket API #{url} returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end
end
