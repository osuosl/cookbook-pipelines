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
    # Merge with no release, for changes that don't affect production code.
    'bump/skip' => 'ededed',
    'env/all' => '1d76db',
    'env/default' => '1d76db',
  }.freeze

  # NOTE: issue_comment stays with the legacy freestyle jobs until cutover;
  # subscribing it here too would run two releases for one !bump comment.
  HOOK_EVENTS = %w(pull_request).freeze

  # Team access granted on every cookbook repo. 'push' is GitHub's API name
  # for write.
  TEAM_PERMISSIONS = {
    'chefs' => 'push',
    'ci' => 'admin',
    'core' => 'admin',
    'staff' => 'push',
  }.freeze

  # Repo settings kept in sync. Merge commits stay enabled - that is how PRs
  # land - but PR branches themselves must stay linear, which GitHub has no
  # setting for; oslCookbookCI fails a PR whose branch contains a merge
  # commit, and 'strict' protection below forces it to be up to date, so the
  # only way to satisfy both is a rebase.
  DESIRED_REPO_SETTINGS = {
    delete_branch_on_merge: true,
    # A merge commit is the only way PRs land: squash and rebase merging are
    # both off (allow_merge_commit itself is deliberately left alone).
    allow_rebase_merge: false,
    allow_squash_merge: false,
    allow_update_branch: true,
  }.freeze

  # Branch names that get protection whenever they exist, so a repo mid-way
  # through a master -> main rename has both covered.
  MIGRATION_BRANCHES = %w(master main).freeze

  # The org folder's PR check. Required on migrated repos, which also retires
  # the legacy GHPRB context so nobody has to swap it by hand.
  LEGACY_CHECK_RE = /\Achef-ci-linter-/

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

    @github.org_repos(org).reject(&:archived?).map(&:name).sort
  end

  # Full repo representation, memoized: the org listing omits some settings
  # (delete_branch_on_merge), so fetch each repo once and reuse it.
  def repo_info(repo_name)
    @repo_info ||= {}
    @repo_info[repo_name] ||= @github.repository("#{org}/#{repo_name}")
  end

  def sync_repo(repo_name, stats)
    repo_path = "#{org}/#{repo_name}"
    migrated = migrated?(repo_path)
    seed_labels(repo_path, stats)
    hooks = @github.hooks(repo_path)
    ensure_hook(repo_path, hooks, stats)
    remove_legacy_hooks(repo_path, repo_name, hooks, migrated, stats)
    ensure_teams(repo_path, stats)
    ensure_repo_settings(repo_name, repo_path, stats)
    ensure_branch_protection(repo_name, repo_path, migrated, stats)
  end

  def required_check
    @env.fetch('REQUIRED_CHECK', 'continuous-integration/jenkins/pr-merge')
  end

  # Grant the standing team access. Only writes when a team is missing or has
  # the wrong permission, so a steady-state run issues no mutations.
  def ensure_teams(repo_path, stats)
    current = @github.repository_teams(repo_path).to_h { |t| [t.slug, t.permission] }
    TEAM_PERMISSIONS.each do |slug, permission|
      next if current[slug] == permission

      act("grant #{slug} #{permission} on #{repo_path}") do
        @github.put("/orgs/#{org}/teams/#{slug}/repos/#{repo_path}", permission: permission)
      end
      stats[:teams_updated] += 1
    end
  end

  # Keep the merge/branch settings in sync; only writes the keys that drifted.
  def ensure_repo_settings(repo_name, repo_path, stats)
    current = repo_info(repo_name).to_h
    drift = DESIRED_REPO_SETTINGS.reject { |key, value| current[key] == value }
    return if drift.empty?

    act("update settings on #{repo_path} (#{drift.keys.join(', ')})") do
      @github.edit_repository(repo_path, **drift)
    end
    stats[:settings_updated] += 1
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
  def remove_legacy_hooks(repo_path, repo_name, hooks, migrated, stats)
    return unless migrated

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
  # default branch to the bot removes the merge button for everyone else and
  # forces releases through the bump labels.
  #
  # enforce_admins is deliberately FALSE: repo admins keep a manual escape
  # hatch for when the automation can't be used. The bot also holds admin (it
  # needs it to manage protection and hooks), so it would inherit that bypass
  # too - cookbook_bumper therefore checks mergeable_state itself and refuses
  # to merge a PR that branch protection would block for a normal user.
  #
  # CAUTION: the protection endpoint is a full-replace PUT. Existing settings
  # (required checks, review rules, team restrictions) are read first and
  # carried forward unchanged; only the push restriction and enforce_admins
  # are overlaid. Never turn this into a blind PUT - authoritative-on-apply
  # APIs have burned us before.
  def ensure_branch_protection(repo_name, repo_path, migrated, stats)
    return unless @env.fetch('PROTECT_BRANCHES', 'true') == 'true'

    bot = @env.fetch('GITHUB_USER')
    protection_branches(repo_name, repo_path).each do |branch|
      existing = begin
        @github.branch_protection(repo_path, branch)
      rescue Octokit::NotFound
        nil
      end

      desired = protection_request(existing, bot, migrated: migrated)
      if protection_current?(existing, desired, bot)
        stats[:protection_current] += 1
        next
      end

      act("protect #{repo_path}@#{branch} (merges restricted to #{bot}, up-to-date branches required)") do
        @github.protect_branch(repo_path, branch, desired)
      end
      stats[:protection_updated] += 1
    end
  end

  # The default branch plus whichever of master/main also exists.
  def protection_branches(repo_name, repo_path)
    default = repo_info(repo_name).default_branch
    ([default] | MIGRATION_BRANCHES).select do |name|
      name == default || branch_exists?(repo_path, name)
    end
  end

  def branch_exists?(repo_path, name)
    @github.branch(repo_path, name)
    true
  rescue Octokit::NotFound
    false
  end

  def protection_current?(existing, desired, bot)
    return false if existing.nil?

    users = (existing.restrictions&.users || []).map(&:login)
    return false unless users == [bot] && existing.enforce_admins&.enabled == false

    reviews = existing.required_pull_request_reviews
    return false if reviews && !reviews.dismiss_stale_reviews

    checks_current?(existing.required_status_checks, desired[:required_status_checks])
  end

  def checks_current?(existing_checks, desired_checks)
    return existing_checks.nil? if desired_checks.nil?
    return false if existing_checks.nil?

    existing_checks.strict == desired_checks[:strict] &&
      existing_checks.contexts.to_a.sort == desired_checks[:contexts].sort
  end

  # 'strict' is what makes GitHub require an up-to-date branch before merging.
  # It only has meaning alongside required contexts, so on migrated repos the
  # org folder's PR check is required and the legacy GHPRB context dropped -
  # that retires the old check without the manual swap that would otherwise
  # block every PR if done in the wrong order.
  def required_status_checks(existing, migrated:)
    contexts = (existing&.required_status_checks&.contexts || []).to_a
    if migrated
      contexts = contexts.grep_v(LEGACY_CHECK_RE)
      contexts |= [required_check]
    end
    return nil if contexts.empty?

    { strict: true, contexts: contexts }
  end

  # Build the full PUT body: desired restriction + everything the repo
  # already had. All four top-level keys are mandatory on this endpoint.
  def protection_request(existing, bot, migrated:)
    reviews = existing&.required_pull_request_reviews
    {
      # False on purpose: admins keep a manual merge escape hatch. See
      # ensure_branch_protection.
      enforce_admins: false,
      restrictions: {
        users: [bot],
        teams: (existing&.restrictions&.teams || []).map(&:slug),
      },
      required_status_checks: required_status_checks(existing, migrated: migrated),
      required_pull_request_reviews: reviews && {
        # Forced on where reviews are required at all: a new push dismisses
        # old approvals, so what merges is what was actually reviewed.
        dismiss_stale_reviews: true,
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
    @out.puts "  team grants:        #{stats[:teams_updated]}"
    @out.puts "  repo settings:      #{stats[:settings_updated]}"
    @out.puts "  protection updated: #{stats[:protection_updated]}"
    @out.puts "  protection current: #{stats[:protection_current]}"
    @out.puts "  failures:           #{failures.size}"
    failures.each { |f| @out.puts "    #{f}" }
  end
end
