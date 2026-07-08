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
    env_files, envs = environment_files(workdir)
    changed = Dir.chdir(workdir) { pin_versions(env_files) }
    if changed.empty?
      @out.puts 'No environment pins needed updating, nothing to do.'
      return nil
    end

    repo.add(all: true)
    repo.commit(commit_message)
    # Non-chain branch names are content-addressed, so force-push makes
    # retries idempotent. Chain branches accumulate commits — never force.
    repo.push('origin', branch, force: !chain)

    upsert_pr(default_branch, branch, envs, existing_branch)
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

  # Expand the envs parameter into concrete environment file paths.
  def environment_files(workdir)
    tokens = @env.fetch('envs').split(',')
    envs = tokens.flat_map do |token|
      case token
      when 'all' then Dir.glob(File.join(workdir, 'environments/*.json')).map { |f| File.basename(f, '.json') }
      when 'default' then default_environments
      else token
      end
    end.uniq
    [envs.map { |e| "environments/#{e}.json" }, envs]
  end

  # Update pins for cookbooks already pinned in each environment. Returns the
  # cookbook names that changed at least one file.
  def pin_versions(env_files)
    changed = []
    env_files.each do |file|
      raise Error, "environment file #{file} does not exist" unless File.exist?(file)

      data = JSON.parse(File.read(file))
      cookbooks.each do |cookbook|
        pins = data['cookbook_versions']
        next unless pins.include?(cookbook[:name])
        next if pins[cookbook[:name]] == "= #{cookbook[:version]}"

        pins[cookbook[:name]] = "= #{cookbook[:version]}"
        changed << cookbook[:name]
      end
      File.write(file, "#{JSON.pretty_generate(data)}\n")
    end
    changed.uniq
  end

  def commit_message
    summary = cookbooks.map { |c| "#{c[:name]} to v#{c[:version]}" }.join(', ')
    message = "Automatic version bump of #{summary} by Jenkins"
    message += "\n\nTriggered by: #{pr_link}" if pr_link
    message
  end

  def upsert_pr(default_branch, branch, envs, existing_branch)
    owner = chef_repo.split('/').first
    open_pr = existing_branch && @github.pull_requests(chef_repo, state: 'open', head: "#{owner}:#{branch}").first

    summary = cookbooks.map { |c| "'#{c[:name]}' to #{c[:version]}" }.join(', ')
    if open_pr
      note = "Added bump of #{summary}."
      note += " Includes changes from: #{pr_link}." if pr_link
      @github.add_comment(chef_repo, open_pr.number, note)
      @github.update_pull_request(chef_repo, open_pr.number, body: "#{open_pr.body}\n- #{note}")
      @out.puts "Updated chain PR: #{open_pr.html_url}"
      open_pr
    else
      title = chain ? "Chained cookbook bumps (#{chain})" : "Bump #{summary}"
      body = "This automatically generated PR bumps #{summary} in the following environments:" \
             "\n```\n#{envs.join("\n")}\n```\n"
      body += "\nThis includes the changes from: #{pr_link}." if pr_link
      body += "\n- Initial bump: #{summary}" if chain
      pr = @github.create_pull_request(chef_repo, default_branch, branch, title, body)
      @out.puts "Created PR: #{pr.html_url}"
      pr
    end
  end
end
