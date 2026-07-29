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
# `env/<name>`, `env/default`, and `env/all` labels select the chef-repo
# environments to pin.
#
# `bump/skip` merges the PR with no release at all, for changes that don't
# affect production cookbook code.
#
# Chained bumps (several related releases accumulating into ONE chef-repo PR)
# are requested with a `Cookbook-Chain: <name>` line in the PR description or
# in a commit message on the PR - labels can't carry free-form names without
# per-repo label churn. Use the same chain name on every PR in the series.
#
# A `!bump <level> [envs] [envs=a,b] [chain=name]` PR comment is retained as a
# fallback for ad-hoc input; commenters must have write access to the repo.
# An explicit `chain=` there overrides any Chain: directive.
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
  # bump/skip merges the PR with no release: for changes that don't affect
  # production cookbook code (CI config, docs, the migration Jenkinsfile).
  SKIP = 'skip'.freeze
  BUMP_LABEL_RE = %r{\Abump/(#{(LEVELS + [SKIP]).join('|')})\z}
  # States a non-admin could merge. The bot holds admin and would bypass
  # branch protection, so refuse anything else rather than exploiting that.
  MERGEABLE_STATES = %w(clean unstable).freeze
  ENV_LABEL_RE = %r{\Aenv/(\S+)\z}
  # Matches a 'Cookbook-Chain: <value>' line in a PR body or commit message.
  CHAIN_DIRECTIVE_RE = /^cookbook-chain:[ \t]*(\S+)[ \t]*$/i
  # Chain values may be a Gerrit-Depends-On-style PR reference instead of a
  # free-form name: a full PR URL or [org/]repo#123.
  CHAIN_PR_URL_RE = %r{\Ahttps?://github\.com/[^/]+/([^/]+)/pull/(\d+)/?\z}i
  CHAIN_PR_REF_RE = %r{\A(?:[\w.-]+/)?([\w.-]+)#(\d+)\z}
  COMMENT_RE = /\A!bump (#{(LEVELS + [SKIP]).join('|')})(\s.*)?\z/
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

    # The payload is attacker-controllable: the trigger endpoint is
    # unauthenticated apart from a shared token, so never act on a repo
    # outside our own org.
    verify_repo_in_org!

    pr = fetch_pr
    raise Error, 'PR is already merged.' if pr.merged

    authorize_actor!
    pr = wait_for_mergeable(pr)

    # bump/skip: merge only, no version bump, upload or environment bump.
    if request[:level] == SKIP
      merge!
      delete_source_branch(pr)
      @github.add_comment(repo_path, pr_number,
                          'Merged without a release (`bump/skip`): no version bump, upload or environment change.')
      @out.puts 'Merged with bump/skip; no release performed.'
      return nil
    end

    request = merge_labels_into(request, pr) if request[:source] == :label
    # An explicit chain= from the comment fallback wins; otherwise honor a
    # 'Cookbook-Chain: <value>' directive in the PR body or a commit message.
    request[:chain] ||= chain_directive(pr)
    request[:chain] = normalize_chain(request[:chain])

    merge!
    delete_source_branch(pr)

    version = release(pr)

    # The release is already published at this point, so a community upload
    # failure must not abort the run: it would skip the PR comment and the
    # environment bump, and the bump cannot be retried (the PR is merged).
    # Uploading an already-frozen shared dependency is a routine non-zero exit.
    community_error = nil
    community = begin
      @community_deps.call(repo_path, pr_number)
    rescue StandardError => e
      community_error = e
      @out.puts "Community dependency upload failed: #{e.class}: #{e.message}"
      []
    end

    announce(pr, request, version, community, community_error)

    result = {
      'cookbooks' => [{ 'name' => repo_name, 'version' => version }] +
                     community.map { |c| { 'name' => c[:name], 'version' => c[:version] } },
      'envs' => request[:envs].join(','),
      # Emit strings, never nil: a JSON null round-trips through Jenkins'
      # readJSON as a truthy JSONNull and becomes the literal chain "null".
      'chain' => request[:chain].to_s,
      'pr_link' => pr.html_url.to_s,
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

  # On the label path, environment selection comes from the PR's current labels.
  def merge_labels_into(request, pr)
    pr.labels.each do |label|
      if (match = ENV_LABEL_RE.match(label.name))
        request[:envs] << match[1]
      end
    end
    request
  end

  # A chain value travels as a 'Cookbook-Chain: <value>' line in the PR
  # description (preferred, visible to reviewers) or in a commit message on
  # the PR, in the style of git trailers / Gerrit's Depends-On. The most
  # recent commit wins when several carry the directive.
  def chain_directive(pr)
    body_match = pr.body.to_s.match(CHAIN_DIRECTIVE_RE)
    return body_match[1] if body_match

    @github.pull_request_commits(repo_path, pr_number).reverse_each do |c|
      match = c.commit.message.to_s.match(CHAIN_DIRECTIVE_RE)
      return match[1] if match
    end
    nil
  end

  # A chain value is either a free-form name or a PR reference (full URL or
  # [org/]repo#123, Gerrit Depends-On style). References are canonicalized to
  # 'repo-123' so every PR pointing at the same upstream lands on the same
  # chef-repo branch regardless of which form was used.
  def normalize_chain(value)
    return nil if value.nil? || value.empty?

    match = CHAIN_PR_URL_RE.match(value) || CHAIN_PR_REF_RE.match(value)
    return "#{match[1]}-#{match[2]}" if match

    value
  end

  # Releasing is far more privileged than labelling: it merges the PR, pushes
  # a tag to the base branch and freezes a version on the Chef server. GitHub
  # grants labelling to triage users who cannot merge or push, so require push
  # access explicitly for BOTH the label and the comment path rather than
  # trusting the label event itself.
  def authorize_actor!
    raise Error, 'Cannot determine who requested this bump.' if actor.nil? || actor.empty?

    level = actor_permission
    return if %w(admin write).include?(level)

    raise Error, "user '#{actor}' is not authorized to release #{repo_name} (needs write access)."
  end

  # Guard against a forged payload naming a repo we should never touch.
  def verify_repo_in_org!
    org = @env.fetch('GITHUB_ORG')
    return if repo_path.to_s.start_with?("#{org}/")

    raise Error, "refusing to act on '#{repo_path}': not in the '#{org}' organization."
  end

  def fetch_pr
    @github.pull_request(repo_path, pr_number)
  end

  def merge!
    @github.merge_pull_request(repo_path, pr_number)
  end

  # GitHub computes mergeability lazily; 'unknown' means "not done yet".
  # Checking mergeable_state (not just mergeable) stops the bot from silently
  # spending its own admin bypass on everyone's behalf.
  def wait_for_mergeable(pr)
    MERGEABLE_ATTEMPTS.times do
      verdict = mergeability(pr)
      return pr if verdict == :ok
      raise Error, verdict if verdict.is_a?(String)

      @sleeper.call(2) # :retry
      pr = fetch_pr
    end
    raise Error, 'PR mergeability is still unknown, try again.'
  end

  # :ok, :retry, or an error message.
  def mergeability(pr)
    state = pr.mergeable_state.to_s
    return :ok if MERGEABLE_STATES.include?(state)
    return :retry if state.empty? || state == 'unknown'
    return blocked_verdict(pr) if state == 'blocked'

    mergeable_error(state)
  end

  # A repo admin can merge a protected branch by hand, so honor that same
  # bypass for the admin who applied the label - otherwise an admin could
  # never release their own PR (GitHub forbids self-approval). The bypass
  # covers the REVIEW requirement only: a red or unfinished check still stops
  # the release, since that would publish a frozen version that failed CI.
  def blocked_verdict(pr)
    return mergeable_error('blocked') unless admin_actor?

    case commit_state(pr)
    when 'success'
      @review_waived = true
      @out.puts "Branch protection waived for admin '#{actor}' (checks are green)."
      :ok
    when 'pending'
      :retry
    else
      "PR is blocked and its checks are not passing (#{commit_state(pr)}); " \
      'an admin bypass does not cover failing checks.'
    end
  end

  # Combined commit status for the PR head. Jenkins reports via the statuses
  # API; if the org ever switches to the Checks API this needs to consider
  # check-runs too.
  def commit_state(pr)
    @commit_state ||= @github.combined_status(repo_path, pr.head.sha).state.to_s
  end

  def actor_permission
    @actor_permission ||= begin
      @github.permission_level(repo_path, actor).permission
    rescue Octokit::NotFound
      'none' # not a collaborator at all
    end
  end

  def admin_actor?
    actor_permission == 'admin'
  end

  def mergeable_error(state)
    case state
    when 'dirty'
      'PR has merge conflicts.'
    when 'blocked'
      'PR is blocked by branch protection: it needs an approving review and/or passing required checks.'
    when 'behind'
      'PR is out of date with its base branch; update the branch first.'
    when 'draft'
      'PR is still a draft.'
    else
      "PR is not in a mergeable state (#{state})."
    end
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
    repo = @git.clone(GithubHelpers.authenticated_url(repo_path, token: @env.fetch('GITHUB_TOKEN')), workdir)
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

  def announce(pr, request, version, community, community_error = nil)
    message = "Jenkins has merged this PR into `#{pr.base.ref}` and performed a " \
              "#{request[:level]}-level version bump to v#{version}."
    unless community.empty?
      uploads = community.map { |c| "#{c[:name]} #{c[:version]}" }.join(', ')
      message += " Community cookbooks uploaded: #{uploads}."
    end
    if community_error
      message += ' :warning: Community dependency upload failed and needs a manual check: ' \
                 "`#{community_error.message}`."
    end
    message += " Environment bump queued for: #{request[:envs].join(', ')}." unless request[:envs].empty?
    message += " Chained into `#{request[:chain]}`." if request[:chain]
    if @review_waived
      message += " :key: Merged using #{actor}'s admin bypass of branch protection " \
                 '(required checks were green).'
    end
    @github.add_comment(repo_path, pr_number, message)
  end

  def write_result(result)
    File.write(@env.fetch('RESULT_FILE', 'bump_result.json'), JSON.pretty_generate(result))
  end
end
