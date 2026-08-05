require 'digest'
require 'git'
require 'json'

require_relative 'github_helpers'

# Pins cookbook versions in chef-repo environment files and opens (or updates)
# a PR for the change.
#
# Parameters arrive as environment variables from the Jenkins job:
#   cookbooks — 'name:version[,name:version...]' (multi-cookbook)
#   envs      — 'all', 'default', or a comma list of environment names; the
#               'all'/'default' words may also appear inside the list
#   chain     — optional chain name: all bumps with the same chain accumulate
#               on one branch/PR (jenkins/chain-<name>) instead of opening a
#               new PR per bump
#   pr_link   — optional URL of the PR that triggered the bump
#
# The chef-repo default branch is resolved from the GitHub API — nothing here
# assumes master or main.
class EnvironmentBumper
  class Error < StandardError
  end

  def self.from_env
    new
  end

  def initialize(env: ENV, github: nil, git: Git, out: $stdout)
    @env = env
    @github = github || GithubHelpers.client
    @git = git
    @out = out
  end

  def chef_repo
    @env.fetch('CHEF_REPO')
  end

  def cookbooks
    @cookbooks ||= @env.fetch('cookbooks').split(',').map do |pair|
      name, version = pair.split(':')
      raise Error, "malformed cookbook pin '#{pair}'" if version.nil?

      { name: name, version: version }
    end
  end

  def chain
    value = @env['chain'].to_s.strip
    value.empty? ? nil : value
  end

  def pr_link
    value = @env['pr_link'].to_s.strip
    value.empty? ? nil : value
  end

  def default_environments
    @env.fetch('DEFAULT_ENVIRONMENTS', '').split(',')
  end

  def run
    default_branch = @github.repo(chef_repo).default_branch
    workdir = File.join(@env.fetch('WORKSPACE', Dir.pwd), 'chef-repo')
    FileUtils.rm_rf(workdir)
    repo = @git.clone(GithubHelpers.authenticated_url(chef_repo, token: @env.fetch('GITHUB_TOKEN')), workdir)
    repo.checkout(default_branch)

    branch, existing_branch = check_out_bump_branch(repo)
    env_entries = environments(workdir)
    envs = env_entries.keys
    result = Dir.chdir(workdir) { pin_versions(env_entries) }
    changed = (result[:updated].keys + result[:added].keys).uniq

    # A requested cookbook that landed nowhere is skipped: it has no existing
    # pin in the selected environments, and none of them was explicitly named
    # (pins are only ADDED to explicitly named environments - 'all' means
    # "update where present", never "introduce everywhere").
    skipped = cookbooks.map { |c| c[:name] } - changed
    skipped.each do |name|
      @out.puts "WARNING: '#{name}' is not pinned in any of: #{envs.join(', ')} - not bumped. " \
                'Name an environment explicitly (env/<name>) to add a new pin.'
    end

    if changed.empty?
      @out.puts 'No environment pins needed updating, nothing to do.'
      return nil
    end

    repo.add(all: true)
    repo.commit(commit_message(changed))
    # Non-chain branch names are content-addressed, so force-push makes
    # retries idempotent. Chain branches accumulate commits — never force.
    repo.push('origin', branch, force: !chain)

    upsert_pr(default_branch, branch, envs, existing_branch,
              changed: changed, skipped: skipped, added: result[:added])
  end

  private

  # Chain bumps share a deterministic branch and stack commits on it; one-off
  # bumps get a content-addressed branch name so retries reuse it.
  def check_out_bump_branch(repo)
    branch = if chain
               "jenkins/chain-#{chain}"
             else
               summary = cookbooks.map { |c| "#{c[:name]}-#{c[:version]}" }.join(',')
               digest = Digest::SHA1.hexdigest("#{summary}|#{@env['envs']}")[0, 7]
               "jenkins/#{cookbooks.first[:name]}-#{cookbooks.first[:version]}-#{digest}"
             end

    existing = chain && remote_branch?(repo, branch)
    if existing
      repo.checkout(branch)
      repo.pull('origin', branch)
    else
      repo.branch(branch).checkout
    end
    [branch, existing]
  end

  def remote_branch?(repo, branch)
    repo.branches.any? { |b| b.remote && b.name == branch }
  end

  # Expand the envs parameter into { env_name => addable }. Explicitly named
  # environments (and the curated default set) may gain NEW pins; environments
  # swept in by 'all' are update-only, so one label can't inject a brand-new
  # cookbook into every environment.
  def environments(workdir)
    entries = {}
    @env.fetch('envs').split(',').map(&:strip).reject(&:empty?).each do |token|
      case token
      when 'all'
        Dir.glob(File.join(workdir, 'environments/*.json')).each do |f|
          name = File.basename(f, '.json')
          entries[name] = false unless entries.key?(name)
        end
      when 'default'
        default_environments.each { |e| entries[e] = true }
      else
        entries[token] = true
      end
    end
    entries
  end

  # Update pins everywhere selected; add missing pins only where addable.
  # cookbook_versions is written back alphabetized, so a new pin lands in a
  # predictable place instead of accumulating at the bottom; files where
  # nothing changed are left untouched. Returns
  # { updated: {name => [envs]}, added: {name => [envs]} }.
  def pin_versions(env_entries)
    updated = Hash.new { |h, k| h[k] = [] }
    added = Hash.new { |h, k| h[k] = [] }
    env_entries.each do |env_name, addable|
      file = "environments/#{env_name}.json"
      raise Error, "environment file #{file} does not exist" unless File.exist?(file)

      data = JSON.parse(File.read(file))
      pins = data['cookbook_versions']
      changed = false
      cookbooks.each do |cookbook|
        pin = "= #{cookbook[:version]}"
        if pins.include?(cookbook[:name])
          next if pins[cookbook[:name]] == pin

          pins[cookbook[:name]] = pin
          updated[cookbook[:name]] << env_name
        elsif addable
          pins[cookbook[:name]] = pin
          added[cookbook[:name]] << env_name
        else
          next
        end
        changed = true
      end
      next unless changed

      data['cookbook_versions'] = pins.sort.to_h
      File.write(file, "#{JSON.pretty_generate(data)}\n")
    end
    { updated: updated, added: added }
  end

  # Describe only what was actually written, never what was merely requested.
  def summarize(changed, quote: false)
    cookbooks.select { |c| changed.include?(c[:name]) }
             .map { |c| quote ? "'#{c[:name]}' to #{c[:version]}" : "#{c[:name]} to v#{c[:version]}" }
             .join(', ')
  end

  def commit_message(changed)
    message = "Automatic version bump of #{summarize(changed)} by Jenkins"
    message += "\n\nTriggered by: #{pr_link}" if pr_link
    message
  end

  def skipped_note(skipped, envs)
    return '' if skipped.empty?

    "\n\n:warning: Not pinned in #{envs.join(', ')}, so left unchanged: " \
      "#{skipped.join(', ')}. Apply an explicit env/<name> label (or add the pin manually) " \
      'if they should be pinned.'
  end

  # New pins deserve their own callout: a reviewer treats "introduced a pin"
  # differently from "moved an existing pin forward".
  def added_note(added)
    return '' if added.empty?

    lines = added.map do |name, env_names|
      version = cookbooks.find { |c| c[:name] == name }[:version]
      "- #{name} #{version} in: #{env_names.join(', ')}"
    end
    "\n\n**Newly pinned** (not previously in these environments):\n#{lines.join("\n")}"
  end

  # One bullet for the chain PR's running inventory. Kept to a single line
  # deliberately; the per-release comment holds the full report.
  def inventory_line(summary, added, skipped)
    line = "- Added bump of #{summary}."
    line += " Includes changes from: #{pr_link}." if pr_link
    unless added.empty?
      pins = added.map { |name, env_names| "#{name} in #{env_names.join('/')}" }
      line += " Newly pinned: #{pins.join(', ')}."
    end
    line += " Left unchanged (not pinned): #{skipped.join(', ')}." unless skipped.empty?
    line
  end

  def upsert_pr(default_branch, branch, envs, existing_branch, changed:, skipped:, added:)
    open_pr = find_open_pr(branch) if existing_branch || !chain

    summary = summarize(changed, quote: true)
    if open_pr
      note = "Added bump of #{summary}."
      note += " Includes changes from: #{pr_link}." if pr_link
      note += added_note(added)
      note += skipped_note(skipped, envs)
      @github.add_comment(chef_repo, open_pr.number, note)
      # The comment above carries the full report; the description only
      # grows its one-line inventory, so it stays a readable list instead
      # of accumulating stacked report blocks with repeated headings.
      @github.update_pull_request(chef_repo, open_pr.number,
                                  body: "#{open_pr.body}\n#{inventory_line(summary, added, skipped)}")
      @out.puts "Updated existing PR: #{open_pr.html_url}"
      open_pr
    else
      title = chain ? "Chained cookbook bumps (#{chain})" : "Bump #{summary}"
      body = "This automatically generated PR bumps #{summary} in the following environments:" \
             "\n```\n#{envs.join("\n")}\n```\n"
      body += "\nThis includes the changes from: #{pr_link}." if pr_link
      body += "\n- Initial bump: #{summary}" if chain
      body += added_note(added)
      body += skipped_note(skipped, envs)
      pr = @github.create_pull_request(chef_repo, default_branch, branch, title, body)
      @out.puts "Created PR: #{pr.html_url}"
      pr
    end
  end

  # Also checked for non-chain branches: a re-run force-pushes the same
  # content-addressed branch, and creating a second PR for it would 422.
  def find_open_pr(branch)
    owner = chef_repo.split('/').first
    @github.pull_requests(chef_repo, state: 'open', head: "#{owner}:#{branch}").first
  end
end
