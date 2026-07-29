require 'octokit'

require_relative 'github_helpers'

# Reconciles GitHub-side state for the label-driven bump workflow across every
# cookbook repo in the org: the bump/* and env/* labels, and the webhook that
# points pull_request events at the cookbook-uploader job's
# generic-webhook-trigger endpoint.
#
# This runs as the scheduled `github-sync` Jenkins job (every 30 minutes,
# matching the chef-client cadence, plus on demand), NOT from chef: an
# org-wide GitHub reconciliation inside every chef-client run made converge
# time proportional to org size and converge success dependent on GitHub
# availability.
#
# Parameters arrive as environment variables from the Jenkins job:
#   GITHUB_ORG           - org whose repos are synced
#   DEFAULT_ENVIRONMENTS - comma list; each gets an env/<name> label
#   REPOS                - optional comma list to limit the run (canary);
#                          empty means every non-archived repo in the org
#   DRY_RUN              - 'true' to report planned writes without performing them
#   WEBHOOK_ENDPOINT     - generic-webhook-trigger invoke URL (no token)
#   TRIGGER_TOKEN        - webhook auth token (from a Jenkins credential)
#   INSECURE_HOOK        - 'true' to allow insecure SSL on the hook (testing)
#   PROTECT_BRANCHES     - 'false' to skip default-branch protection management
#   GITHUB_USER          - the bot account (from the same Jenkins credential);
#                          the only account allowed to push/merge to default
#                          branches when protection is managed
#
# Every repo is synced independently: a failure on one is recorded and the run
# continues. The bin wrapper exits 2 when any repo failed so the Jenkins build
# can go UNSTABLE rather than red.
class GithubSync
  class Error < StandardError
  end

  LABEL_COLORS = {
    'bump/major' => 'b60205',
    'bump/minor' => 'd93f0b',
    'bump/patch' => '0e8a16',
    'env/all' => '1d76db',
    'env/default' => '1d76db',
  }.freeze

  # NOTE: issue_comment stays with the legacy freestyle jobs until cutover;
  # subscribing it here too would run two releases for one !bump comment.
  HOOK_EVENTS = %w(pull_request).freeze

  def self.from_env
    new
  end

  def initialize(env: ENV, github: nil, out: $stdout, sleeper: ->(s) { sleep s })
    @env = env
    @github = github || GithubHelpers.client(token: env.fetch('GITHUB_TOKEN'))
    @out = out
    @sleeper = sleeper
  end

  def run
    stats = Hash.new(0)
    failures = []
    repos.each do |repo_name|
      sync_repo(repo_name, stats)
    rescue Octokit::Error => e
      failures << "#{repo_name}: #{e.class}: #{e.message}"
      @out.puts "FAILED #{repo_name}: #{e.class}: #{e.message}"
    end
    report(stats, failures)
    { stats: stats, failures: failures }
  end

  private

  def org
    @env.fetch('GITHUB_ORG')
  end

  def dry_run?
    @env['DRY_RUN'] == 'true'
  end

  def endpoint
    @env.fetch('WEBHOOK_ENDPOINT')
  end

  def trigger_token
    @env.fetch('TRIGGER_TOKEN')
  end

  def desired_labels
    labels = LABEL_COLORS.dup
    @env.fetch('DEFAULT_ENVIRONMENTS', '').split(',').each do |e|
      labels["env/#{e.strip}"] = '1d76db' unless e.strip.empty?
    end
    labels
  end

  def repos
    requested = @env.fetch('REPOS', '').split(',').map(&:strip).reject(&:empty?)
    return requested unless requested.empty?

    discovered.map(&:name).sort
  end

  def discovered
    @discovered ||= @github.org_repos(org).reject(&:archived?)
  end

  def default_branch(repo_name)
    known = @discovered&.find { |r| r.name == repo_name }
    known ? known.default_branch : @github.repo("#{org}/#{repo_name}").default_branch
  end

  def sync_repo(repo_name, stats)
    repo_path = "#{org}/#{repo_name}"
    seed_labels(repo_path, stats)
    hooks = @github.hooks(repo_path)
    ensure_hook(repo_path, hooks, stats)
    remove_legacy_hooks(repo_path, repo_name, hooks, stats)
    ensure_branch_protection(repo_name, stats)
  end

  def seed_labels(repo_path, stats)
    # GitHub label uniqueness is case-insensitive.
    existing = @github.labels(repo_path).map { |l| l.name.downcase }
    desired_labels.each do |name, color|
      next if existing.include?(name.downcase)

      act("create label '#{name}' in #{repo_path}") do
        @github.add_label(repo_path, name, color)
      rescue Octokit::UnprocessableEntity
        nil # raced with another creator, or differing case; already there
      end
      stats[:labels_created] += 1
    end
  end

  def ensure_hook(repo_path, hooks, stats)
    hook_config = {
      url: "#{endpoint}?token=#{trigger_token}",
      content_type: 'json',
      insecure_ssl: @env['INSECURE_HOOK'] == 'true',
    }
    hook_options = { events: HOOK_EVENTS, active: true }

    ours = hooks.select do |h|
      h['name'] == 'web' && h['config']['url'].to_s.start_with?(endpoint)
    end

    if ours.empty?
      act("create webhook in #{repo_path}") do
        @github.create_hook(repo_path, 'web', hook_config, hook_options)
      end
      stats[:hooks_created] += 1
      return
    end

    ours.each do |hook|
      if hook_current?(hook, hook_config, hook_options)
        stats[:unchanged] += 1
        next
      end
      act("update webhook #{hook['id']} in #{repo_path}") do
        @github.edit_hook(repo_path, hook['id'], 'web', hook_config, hook_options)
      end
      stats[:hooks_updated] += 1
    end
  end

  def hook_current?(hook, config, options)
    hook['config']['url'] == config[:url] &&
      hook['config']['content_type'] == config[:content_type] &&
      hook['events'].sort == options[:events].sort &&
      hook['active'] == options[:active]
  end

  # A Jenkinsfile marks a repo as migrated to the label-driven pipeline. Its
  # legacy webhooks are then removed: the issue_comment hook pointing at the
  # old per-repo freestyle uploader job, and the /ghprbhook/ hook the GHPRB
  # plugin registered for the hand-made linter jobs. (The legacy job config
  # itself is chef-managed and removed by the osl-jenkins cookbook.)
  def remove_legacy_hooks(repo_path, repo_name, hooks, stats)
    return unless migrated?(repo_path)

    legacy_job = "cookbook-uploader-#{org}-#{repo_name}"
    hooks.each do |hook|
      next unless hook['name'] == 'web'

      url = hook['config']['url'].to_s
      next unless url.include?("/job/#{legacy_job}/") || url.include?('/ghprbhook/')

      act("remove legacy webhook #{hook['id']} from #{repo_path}") do
        @github.remove_hook(repo_path, hook['id'])
      end
      stats[:legacy_hooks_removed] += 1
    end
  end

  def migrated?(repo_path)
    @github.contents(repo_path, path: 'Jenkinsfile')
    true
  rescue Octokit::NotFound
    false
  end

  # Merging a PR is a push to the base branch, so restricting pushes on the
  # default branch to the bot user removes the merge button for everyone else
  # (enforce_admins included - admins are exactly who accidentally merges).
  # Releases must go through the bump labels; see the org docs.
  #
  # CAUTION: the protection endpoint is a full-replace PUT. Existing settings
  # (required checks, review rules) are read first and carried forward
  # unchanged; only the push restriction and enforce_admins are overlaid.
  # Never turn this into a blind PUT - authoritative-on-apply APIs have
  # burned us before.
  def ensure_branch_protection(repo_name, stats)
    return unless @env.fetch('PROTECT_BRANCHES', 'true') == 'true'

    repo_path = "#{org}/#{repo_name}"
    branch = default_branch(repo_name)
    bot = @env.fetch('GITHUB_USER')

    existing = begin
      @github.branch_protection(repo_path, branch)
    rescue Octokit::NotFound
      nil
    end

    if protection_current?(existing, bot)
      stats[:protection_current] += 1
      return
    end

    act("restrict merges on #{repo_path}@#{branch} to #{bot}") do
      @github.protect_branch(repo_path, branch, protection_request(existing, bot))
    end
    stats[:protection_updated] += 1
  end

  def protection_current?(existing, bot)
    return false if existing.nil?

    users = (existing.restrictions&.users || []).map(&:login)
    users == [bot] && existing.enforce_admins&.enabled
  end

  # Build the full PUT body: desired restriction + everything the repo
  # already had. All four top-level keys are mandatory on this endpoint.
  def protection_request(existing, bot)
    checks = existing&.required_status_checks
    reviews = existing&.required_pull_request_reviews
    {
      enforce_admins: true,
      restrictions: {
        users: [bot],
        teams: (existing&.restrictions&.teams || []).map(&:slug),
      },
      required_status_checks: checks && {
        strict: checks.strict,
        contexts: checks.contexts.to_a,
      },
      required_pull_request_reviews: reviews && {
        dismiss_stale_reviews: reviews.dismiss_stale_reviews,
        require_code_owner_reviews: reviews.require_code_owner_reviews,
        required_approving_review_count: reviews.required_approving_review_count,
      }.compact,
    }
  end

  # Perform (or, in dry-run, describe) a mutating GitHub call. GitHub asks for
  # at least one second between content-creating requests; nobody is waiting
  # on this job, so it can afford to be polite.
  def act(description)
    if dry_run?
      @out.puts "DRY RUN: would #{description}"
      return
    end
    @out.puts description
    yield
    @sleeper.call(1)
  end

  def report(stats, failures)
    @out.puts
    @out.puts "github-sync summary#{' (DRY RUN)' if dry_run?}:"
    @out.puts "  labels created:     #{stats[:labels_created]}"
    @out.puts "  hooks created:      #{stats[:hooks_created]}"
    @out.puts "  hooks updated:      #{stats[:hooks_updated]}"
    @out.puts "  hooks current:      #{stats[:unchanged]}"
    @out.puts "  legacy hooks gone:  #{stats[:legacy_hooks_removed]}"
    @out.puts "  protection updated: #{stats[:protection_updated]}"
    @out.puts "  protection current: #{stats[:protection_current]}"
    @out.puts "  failures:           #{failures.size}"
    failures.each { |f| @out.puts "    #{f}" }
  end
end
