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
# downloaded, uploaded frozen to the Chef server, and shared to the local
# supermarket. Only direct dependencies are handled; transitive resolution is
# deliberately out of scope.
class CommunityDeps
  class Error < StandardError
  end

  DEPENDS_RE = /\Adepends\s+(["'])([^"']+)\1(?:\s*,\s*(["'])([^"']+)\3)?/

  def initialize(github:, org:, public_supermarket:, local_supermarket:, shell:, do_not_upload: false, out: $stdout)
    @github = github
    @org = org
    @public_supermarket = public_supermarket
    @local_supermarket = local_supermarket
    @do_not_upload = do_not_upload
    @shell = shell
    @out = out
  end

  # Returns [{name:, version:}] for every community dependency the PR changed.
  def call(repo_path, pr_number)
    changed_constraints(repo_path, pr_number).filter_map do |name, constraint|
      next unless community?(name)

      version = resolve(name, constraint)
      upload(name, version)
      { name: name, version: version }
    end
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
    !@github.repository?("#{@org}/#{name}")
  end

  # Newest version on the public supermarket satisfying the constraint.
  def resolve(name, constraint)
    body = fetch_json("#{@public_supermarket}/api/v1/cookbooks/#{name}")
    versions = body['versions'].map { |url| url.split('/').last.tr('_', '.') }
    requirement = Gem::Requirement.new(constraint || '>= 0')
    version = versions.map { |v| Gem::Version.new(v) }.select { |v| requirement.satisfied_by?(v) }.max
    raise Error, "no version of '#{name}' satisfies '#{constraint}'" if version.nil?

    version.to_s
  end

  def upload(name, version)
    @out.puts "Uploading community cookbook #{name} #{version}..."
    return if @do_not_upload

    Dir.mktmpdir("community-#{name}-") do |dir|
      tarball = File.join(dir, "#{name}.tar.gz")
      @shell.call('knife', 'supermarket', 'download', name, version, '-m', @public_supermarket, '-f', tarball)
      @shell.call('tar', '-xzf', tarball, '-C', dir)
      @shell.call('knife', 'cookbook', 'upload', name, '--freeze', '-o', dir)
      @shell.call('knife', 'supermarket', 'share', name, 'Other', '-m', @local_supermarket, '-o', dir)
    end
  end

  private

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
