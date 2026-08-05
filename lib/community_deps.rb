require 'English'
require 'json'
require 'net/http'
require 'tmpdir'

# Detects community cookbook dependency changes in a merged PR and uploads the
# newly required versions to the Chef server and local supermarket.
#
# A dependency is "community" when no repo of the same name exists in the
# GitHub org (org repos release through their own bump pipeline). For each
# `depends` constraint the PR changed in metadata.rb, the newest version
# satisfying the constraint is resolved against the public Supermarket API,
# downloaded, and uploaded frozen to the Chef server. Community cookbooks are
# never shared to the local supermarket - that holds only org cookbooks. A
# version already present on the Chef server is skipped and treated as
# success so its environment pin still updates.
#
# The dependency graph of everything uploaded is then walked (the public
# Supermarket knows each version's dependencies) and any transitive community
# dependency the Chef server cannot already satisfy is uploaded and pinned
# the same way. A dependency the server *can* satisfy is left untouched:
# upgrading pins nobody asked for is not this job's call, and the chef-repo
# environment pin check reports unpinned floats.
class CommunityDeps
  class Error < StandardError
  end

  DEPENDS_RE = /\Adepends\s+(["'])([^"']+)\1(?:\s*,\s*(["'])([^"']+)\3)?/

  # The Chef server's full version index, fetched with the pipeline's knife
  # credentials. Injectable for tests.
  DEFAULT_SERVER_UNIVERSE = lambda do
    raw = `knife raw /universe`
    raise Error, 'failed to fetch /universe from the chef server' unless $CHILD_STATUS.success?

    JSON.parse(raw)
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
  end

  # Returns [{name:, version:}] for every community dependency the PR
  # changed, plus every missing transitive community dependency underneath
  # them.
  def call(repo_path, pr_number)
    direct = changed_constraints(repo_path, pr_number).filter_map do |name, constraint|
      next unless community?(name)

      version = resolve(name, constraint)
      upload(name, version)
      { name: name, version: version }
    end
    direct + transitive_closure(direct)
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

  # Newest version on the public supermarket satisfying the constraint(s).
  # A DEPRECATED cookbook stops the release outright: knife refuses to
  # download one anyway (while exiting 0, leaving a baffling tar error), and
  # silently building on abandoned cookbooks is how they fossilize into the
  # infrastructure. Upload it by hand if it is genuinely still wanted.
  def resolve(name, constraint)
    constraints = Array(constraint || '>= 0')
    constraints = ['>= 0'] if constraints.empty?
    body = fetch_json("#{@public_supermarket}/api/v1/cookbooks/#{name}")
    if body['deprecated']
      replacement = body['replacement'] ? "replacement: #{body['replacement']}" : 'no replacement defined'
      raise Error, "'#{name}' is DEPRECATED on the public supermarket (#{replacement}). " \
                   'Not uploading it automatically - migrate off it, or upload it manually ' \
                   'if it is still needed.'
    end
    versions = body['versions'].map { |url| url.split('/').last.tr('_', '.') }
    requirement = Gem::Requirement.new(constraints)
    version = versions.map { |v| Gem::Version.new(v) }.select { |v| requirement.satisfied_by?(v) }.max
    raise Error, "no version of '#{name}' satisfies '#{constraints.join(', ')}'" if version.nil?

    version.to_s
  end

  def upload(name, version)
    @out.puts "Uploading community cookbook #{name} #{version}..."
    return if @do_not_upload

    # The resolved version being on the Chef server already is the routine
    # case (another cookbook's bump uploaded it, or a re-run). Re-uploading a
    # frozen version exits non-zero, and the failure would also drop the dep
    # from the environment pin update - so an existing version is success,
    # not an error.
    if uploaded?(name, version)
      @out.puts "#{name} #{version} is already on the Chef server, skipping upload."
      return
    end

    Dir.mktmpdir("community-#{name}-") do |dir|
      tarball = File.join(dir, "#{name}.tar.gz")
      @shell.call('knife', 'supermarket', 'download', name, version, '-m', @public_supermarket, '-f', tarball)
      @shell.call('tar', '-xzf', tarball, '-C', dir)
      @shell.call('knife', 'cookbook', 'upload', name, '--freeze', '-o', dir)
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

  # Walk the dependency graph of everything just uploaded and upload any
  # community dependency the Chef server cannot already satisfy. Constraints
  # from every dependent of a missing cookbook are merged; conflicting
  # requirements on something already uploaded are an error rather than a
  # guess.
  def transitive_closure(seed)
    resolved = seed.to_h { |c| [c[:name], c[:version]] }
    constraints = Hash.new { |h, k| h[k] = [] }
    uploaded = []
    queue = seed.map { |c| c[:name] }
    until queue.empty?
      name = queue.shift
      dependencies_of(name, resolved.fetch(name)).each do |dep, constraint|
        constraints[dep] << constraint if constraint
        if resolved.key?(dep)
          verify_resolved!(dep, resolved[dep], constraint)
          next
        end
        next if org_dependency?(dep) # its own pipeline releases it
        next if server_satisfies?(dep, constraint)

        version = resolve(dep, constraints[dep])
        upload(dep, version)
        resolved[dep] = version
        uploaded << { name: dep, version: version }
        queue << dep
      end
    end
    uploaded
  end

  # Dependency constraints of a specific cookbook version, from the public
  # supermarket (versions are underscored in its URLs).
  def dependencies_of(name, version)
    fetch_json("#{@public_supermarket}/api/v1/cookbooks/#{name}/versions/#{version.tr('.', '_')}")
      .fetch('dependencies', {}) || {}
  end

  def verify_resolved!(name, version, constraint)
    return if constraint.nil? || Gem::Requirement.new(constraint).satisfied_by?(Gem::Version.new(version))

    raise Error, "conflicting requirements: #{name} #{version} was uploaded but another dependency needs #{constraint}"
  end

  # An org cookbook found transitively is never uploaded here - it releases
  # through its own pipeline - but the server having no version of it at all
  # is worth a loud warning, since nothing else will say so until converge.
  def org_dependency?(name)
    return false if community?(name)

    if (server_universe[name] || {}).empty?
      @out.puts "WARNING: #{name} is an org cookbook the Chef server does not have; release it first."
    end
    true
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

  def fetch_json(url, redirects_left = 3)
    response = Net::HTTP.get_response(URI(url))
    if response.is_a?(Net::HTTPRedirection) && redirects_left.positive?
      return fetch_json(response['location'], redirects_left - 1)
    end
    raise Error, "supermarket API #{url} returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end
end
