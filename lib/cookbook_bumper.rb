require 'English'
require 'git'
require 'json'

require_relative 'community_deps'
require_relative 'github_helpers'

# Merges a cookbook PR and releases a new version of the cookbook.
#
# Triggered from a GitHub webhook payload (pull_request or issue_comment
# event). The primary interface is labels: applying `bump/major`,
# `bump/minor`, or `bump/patch` to a PR merges it and performs the release;
# `env/<name>`, `env/default`, `env/all`, and `chain/<name>` labels select the
# chef-repo environments to pin and an optional chain PR to accumulate into.
# Authorization is GitHub-native: only users who can label a PR (triage+) can
# trigger a bump.
#
# A `!bump <level> [envs] [envs=a,b] [chain=name]` PR comment is retained as a
# fallback for ad-hoc input; commenters must have write access to the repo.
#
# The release: merge the PR, bump the version in metadata.rb, prepend a
# CHANGELOG entry, tag, push to the PR's base branch (no branch name is ever
# assumed), upload to the Chef server and supermarket, and upload any
# community cookbooks whose `depends` constraints the PR changed. If any
# environments were requested, a result file is written for the Jenkins
# pipeline to hand to the environment-bumper job.
class CookbookBumper
  class Error < StandardError
  end

  LEVELS = %w(major minor patch).freeze
  BUMP_LABEL_RE = %r{\Abump/(#{LEVELS.join('|')})\z}
  ENV_LABEL_RE = %r{\Aenv/(\S+)\z}
  CHAIN_LABEL_RE = %r{\Achain/(\S+)\z}
  COMMENT_RE = /\A!bump (#{LEVELS.join('|')})(\s.*)?\z/
  METADATA_FILE = 'metadata.rb'.freeze
  CHANGELOG_FILE = 'CHANGELOG.md'.freeze
  VERSION_RE = /^(version\s+)(["'])(\d+\.\d+\.\d+)\2$/
  MERGEABLE_ATTEMPTS = 5

  def self.from_env
    payload = ENV['payload'] || $stdin.read
    new(payload: JSON.parse(payload))
  end

  def initialize(payload:, env: ENV, github: nil, git: Git, community_deps: nil,
                 shell: nil, sleeper: ->(s) { sleep s }, out: $stdout)
    @payload = payload
    @env = env
    @github = github || GithubHelpers.client
    @git = git
    @shell = shell || ->(*cmd) { system(*cmd) || raise(Error, "command failed: #{cmd.first}") }
    @sleeper = sleeper
    @out = out
    @community_deps = community_deps || CommunityDeps.new(
      github: @github,
      org: env.fetch('GITHUB_ORG'),
      public_supermarket: env.fetch('PUBLIC_SUPERMARKET_URL', 'https://supermarket.chef.io'),
      local_supermarket: env.fetch('LOCAL_SUPERMARKET_URL', 'https://supermarket.osuosl.org'),
      do_not_upload: do_not_upload?,
      shell: @shell
    )
  end

  # Returns the result hash when a bump was performed, nil when the payload
  # wasn't a bump request. Raises CookbookBumper::Error on a refused bump.
  def run
    request = parse_trigger
    if request.nil?
      @out.puts 'Not a bump request, nothing to do.'
      return nil
    end

    pr = fetch_pr
    raise Error, 'PR is already merged.' if pr.merged

    authorize_commenter! if request[:source] == :comment
    pr = wait_for_mergeable(pr)

    request = merge_labels_into(request, pr) if request[:source] == :label

    @github.merge_pull_request(repo_path, pr_number)
    delete_source_branch(pr)

    version = release(pr)
    community = @community_deps.call(repo_path, pr_number)
    announce(pr, request, version, community)

    result = {
      'cookbooks' => [{ 'name' => repo_name, 'version' => version }] +
                     community.map { |c| { 'name' => c[:name], 'version' => c[:version] } },
      'envs' => request[:envs].join(','),
      'chain' => request[:chain],
      'pr_link' => pr.html_url,
    }
    write_result(result) unless request[:envs].empty?
    result
  end

  private

  def repo_path
    @payload['repository']['full_name']
  end

  def repo_name
    @payload['repository']['name']
  end

  def pr_number
    @payload.dig('pull_request', 'number') || @payload.dig('issue', 'number')
  end

  def pr_title
    @payload.dig('pull_request', 'title') || @payload.dig('issue', 'title')
  end

  def actor
    @payload.dig('sender', 'login') || @payload.dig('comment', 'user', 'login')
  end

  def do_not_upload?
    @env['DO_NOT_UPLOAD'] == 'true'
  end

  # Detect whether this payload is a bump request and extract level/envs/chain.
  def parse_trigger
    if @payload['action'] == 'labeled' && @payload.key?('pull_request')
      match = BUMP_LABEL_RE.match(@payload.dig('label', 'name').to_s)
      return nil unless match

      { source: :label, level: match[1], envs: [], chain: nil }
    elsif @payload['action'] == 'created' && @payload.key?('comment')
      return nil unless @payload.dig('issue', 'pull_request')

      parse_comment(@payload.dig('comment', 'body').to_s)
    end
  end

  def parse_comment(body)
    match = COMMENT_RE.match(body.strip)
    return nil unless match

    request = { source: :comment, level: match[1], envs: [], chain: nil }
    match[2].to_s.split.each do |token|
      key, value = token.split('=', 2)
      case key
      when 'chain' then request[:chain] = value
      when 'envs' then request[:envs] = expand_env_words(value)
      else request[:envs] = expand_env_words(token)
      end
    end
    request
  end

  # Legacy '~' and '*' keywords map onto the label-era 'default'/'all' tokens.
  def expand_env_words(list)
    list.split(',').map do |env_name|
      { '~' => 'default', '*' => 'all' }.fetch(env_name, env_name)
    end
  end

  # On the label path, env/chain selection comes from the PR's current labels.
  def merge_labels_into(request, pr)
    pr.labels.each do |label|
      if (match = ENV_LABEL_RE.match(label.name))
        request[:envs] << match[1]
      elsif (match = CHAIN_LABEL_RE.match(label.name))
        request[:chain] = match[1]
      end
    end
    request
  end

  # Label application is authorized by GitHub itself (triage+). Comments are
  # open to anyone, so require push access for the fallback path.
  def authorize_commenter!
    level = @github.permission_level(repo_path, actor).permission
    return if %w(admin write).include?(level)

    raise Error, "user '#{actor}' is not authorized to bump via comment (needs write access)."
  end

  def fetch_pr
    @github.pull_request(repo_path, pr_number)
  end

  # GitHub computes mergeability lazily; nil means "not done yet".
  def wait_for_mergeable(pr)
    MERGEABLE_ATTEMPTS.times do
      return pr if pr.mergeable
      raise Error, 'PR cannot be merged cleanly.' if pr.mergeable == false

      @sleeper.call(2)
      pr = fetch_pr
    end
    raise Error, 'PR mergeability is still unknown, try again.'
  end

  def delete_source_branch(pr)
    return unless pr.head.repo && pr.head.repo.full_name == repo_path

    @github.delete_branch(repo_path, pr.head.ref)
  rescue Octokit::UnprocessableEntity
    nil # already deleted, e.g. by repo auto-delete settings
  end

  # Clone the repo, bump metadata/CHANGELOG on the PR's base branch, tag and
  # push. Returns the new version. Uses pr.base.ref throughout — works
  # identically for master- and main-defaulted repos.
  def release(pr)
    base = pr.base.ref
    workdir = File.join(@env.fetch('WORKSPACE', Dir.pwd), 'cookbook')
    FileUtils.rm_rf(workdir)
    repo = @git.clone(GithubHelpers.authenticated_url(repo_path), workdir)
    repo.checkout(base)

    version = Dir.chdir(workdir) do
      bump_metadata.tap { |v| prepend_changelog(v) }
    end

    repo.add(all: true)
    repo.commit("Automatic #{level_of(pr)}-level version bump to v#{version} by Jenkins")
    repo.add_tag("v#{version}")
    repo.push('origin', base, tags: true)

    upload_cookbook(workdir)
    version
  end

  def level_of(_pr)
    @level_of ||= parse_trigger[:level]
  end

  def bump_metadata
    version = nil
    metadata = File.read(METADATA_FILE).gsub(VERSION_RE) do
      version = inc_version(Regexp.last_match(3), LEVELS.index(level_of(nil)))
      "#{Regexp.last_match(1)}#{Regexp.last_match(2)}#{version}#{Regexp.last_match(2)}"
    end
    raise Error, "no version line found in #{METADATA_FILE}" if version.nil?

    File.write(METADATA_FILE, metadata)
    version
  end

  def prepend_changelog(version)
    entry = "#{version} (#{Time.now.strftime('%Y-%m-%d')})"
    entry += "\n#{'-' * entry.length}"
    entry += "\n- #{pr_title}\n\n"
    changelog = File.read(CHANGELOG_FILE).sub(/^(.*\d+\.\d+\.\d+)/, "#{entry}\\1")
    File.write(CHANGELOG_FILE, changelog)
  end

  def inc_version(version, level)
    parts = version.split('.')
    parts[level] = parts[level].to_i.next.to_s
    ((level + 1)...3).each { |i| parts[i] = '0' }
    parts.join('.')
  end

  def upload_cookbook(workdir)
    @out.puts "Uploading #{repo_name} cookbook to the Chef server..."
    return if do_not_upload?

    parent = File.expand_path('..', workdir)
    @shell.call('knife', 'cookbook', 'upload', repo_name, '--freeze', '-o', parent)
    @shell.call('knife', 'supermarket', 'share', repo_name, 'Other',
                '-m', @env.fetch('LOCAL_SUPERMARKET_URL', 'https://supermarket.osuosl.org'), '-o', parent)
  end

  def announce(pr, request, version, community)
    message = "Jenkins has merged this PR into `#{pr.base.ref}` and performed a " \
              "#{request[:level]}-level version bump to v#{version}."
    unless community.empty?
      uploads = community.map { |c| "#{c[:name]} #{c[:version]}" }.join(', ')
      message += " Community cookbooks uploaded: #{uploads}."
    end
    message += " Environment bump queued for: #{request[:envs].join(', ')}." unless request[:envs].empty?
    message += " Chained into `#{request[:chain]}`." if request[:chain]
    @github.add_comment(repo_path, pr_number, message)
  end

  def write_result(result)
    File.write(@env.fetch('RESULT_FILE', 'bump_result.json'), JSON.pretty_generate(result))
  end
end
