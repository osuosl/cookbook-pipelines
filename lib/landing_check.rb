# Checks that a release leaves every chef-repo environment passing chef-repo's
# env-pin-check, independently of how its pins were chosen.
#
# env-pin-check is what chef-repo CI runs on the bump PR, so its algorithm is
# reproduced here exactly (see chef-repo scripts/env-pin-check.rb): each pin
# resolves to the newest server version it allows, then the dependency
# closure is walked breadth-first from the pins in file order, and an
# unpinned dependency floats to the newest version satisfying the first edge
# that reaches it - any later edge it fails is an error. That is stricter
# than the Chef server's own solver, but it is the gate the bump PR has to
# pass.
#
# Every environment is checked, not only the selected ones: the Chef server
# is shared, so a version this release puts on it becomes what unpinned
# dependencies float to everywhere. The selected environments also get the
# pins the environment bumper will write (each bumped cookbook where it is
# already pinned or the environment is addable). Each environment is checked
# in every state the release puts it in: with every upload on the server but
# the live pins (until the chef-repo bump PR merges, which can take days);
# with the new pins, written over those on the chain's branch when the
# release joins a chain; and, when community cookbooks go up ahead of the
# merge, with only those (should the merge then fail). Errors an environment
# already has in the same pins are not the release's; any other is, even in
# an environment that already fails for some other reason.
class LandingCheck
  # universe: the Chef server's /universe as it is now. uploads: { name =>
  # { version => dependencies } } for what goes up before the merge (community
  # cookbooks the server lacks). release: [name, version, dependencies] for
  # the releasing cookbook's new version, uploaded after the merge, or nil.
  # pins: { name => version } for the bumped cookbooks the environment bumper
  # writes, the release included.
  def initialize(universe:, uploads:, release:, pins:)
    @universe = universe
    @merge_failed_universe = with(universe, uploads)
    name, version, deps = release
    @final_universe = release ? with(@merge_failed_universe, name => { version => deps }) : @merge_failed_universe
    @bumped = pins
    @uploads = uploads
  end

  # ["env: error (state)", ...] for every env-pin-check error the release
  # would cause in environments ({ env => { selected:, addable:, pins:,
  # live: } }, live defaulting to pins).
  def problems(environments)
    environments.flat_map do |env, entry|
      live = entry.fetch(:live, entry[:pins])
      live_before = errors(live, @universe)
      landing_before = entry[:pins] == live ? live_before : errors(entry[:pins], @universe)
      states = { 'until the bump PR merges' => errors(live, @final_universe) - live_before,
                 'once it merges' => errors(bumped(entry), @final_universe) - landing_before, }
      states['if the merge fails'] = errors(live, @merge_failed_universe) - live_before unless @uploads.empty?
      when_seen = Hash.new { |h, k| h[k] = [] }
      states.each { |state, errs| errs.each { |e| when_seen[e] << state } }
      when_seen.map { |e, seen| "#{env}: #{e} (#{seen.join(', ')})" }
    end
  end

  # env-pin-check's own check, returning its errors.
  def errors(pins, universe)
    errors = []
    resolved = {}
    pins.each do |cb, constraint|
      unless universe.key?(cb)
        errors << "#{cb} (#{constraint}): cookbook not on chef server"
        next
      end
      ok = satisfying(universe, cb, Gem::Requirement.new(constraint))
      if ok.empty?
        errors << "#{cb} (#{constraint}): no such version on chef server"
      else
        resolved[cb] = newest(ok)
      end
    end

    queue = resolved.keys
    until queue.empty?
      cb = queue.shift
      ver = resolved[cb]
      (universe.dig(cb, ver, 'dependencies') || {}).each do |dep, constraint|
        req = Gem::Requirement.new(constraint)
        if resolved.key?(dep)
          unless req.satisfied_by?(Gem::Version.new(resolved[dep]))
            errors << "#{cb} #{ver} depends on #{dep} (#{constraint}) but the environment resolves " \
                      "#{dep} #{resolved[dep]}"
          end
        else
          candidates = satisfying(universe, dep, req)
          if candidates.empty?
            errors << "#{cb} #{ver} depends on #{dep} (#{constraint}): not satisfiable on chef server and not pinned"
          else
            resolved[dep] = newest(candidates)
            queue << dep
          end
        end
      end
    end
    errors
  end

  private

  # The pins once the environment bumper has written this release: updated
  # where pinned, added where addable, and the file re-sorted if it changed.
  def bumped(entry)
    return entry[:pins] unless entry[:selected]

    after = entry[:pins].dup
    @bumped.each do |name, version|
      after[name] = "= #{version}" if entry[:addable] || after.key?(name)
    end
    after == entry[:pins] ? after : after.sort.to_h
  end

  def with(universe, extra)
    extra.reduce(universe) do |merged, (name, versions)|
      merged.merge(name => (merged[name] || {}).merge(versions.transform_values { |d| { 'dependencies' => d } }))
    end
  end

  def satisfying(universe, name, req)
    (universe[name] || {}).keys.select { |v| req.satisfied_by?(Gem::Version.new(v)) }
  end

  def newest(versions)
    versions.max_by { |v| Gem::Version.new(v) }
  end
end
