require 'json'
require 'octokit'

# How a release's envs selection maps onto chef-repo environments, shared by
# the environment bumper (which writes the pins) and the cookbook bumper
# (which checks them before anything is merged), so the two cannot disagree
# about where a release lands.
module ChefRepoEnvironments
  class Error < StandardError
  end

  module_function

  # Expand envs tokens ('all', 'default' or environment names) into
  # { env_name => addable }. Explicitly named environments (and the curated
  # default set) may gain NEW pins; environments swept in by 'all' are
  # update-only, so one label can't inject a brand-new cookbook into every
  # environment.
  def expand(tokens, all:, default:)
    entries = {}
    tokens.each do |token|
      case token
      when 'all'
        all.each { |name| entries[name] = false unless entries.key?(name) }
      when 'default'
        default.each { |name| entries[name] = true }
      else
        entries[token] = true
      end
    end
    entries
  end

  # Chain bumps accumulate on one deterministic chef-repo branch.
  def chain_branch(chain)
    "jenkins/chain-#{chain}"
  end

  # Reads environment pins from chef-repo through the GitHub API, as they
  # stand where a release's environment bump will land: the chain's branch
  # when one is in flight, the default branch otherwise.
  class Pins
    def initialize(github:, chef_repo:, default_environments:)
      @github = github
      @chef_repo = chef_repo
      @default_environments = default_environments
    end

    # { env_name => { selected:, addable:, pins:, live: } } for every
    # environment in chef-repo. pins are read where the environment bump will
    # land (the chain's branch, when one is in flight); live are the default
    # branch's, which are what the Chef server and every other chef-repo PR
    # see until that bump merges. selected flags the environments this envs
    # selection reaches; which of them a given pin lands in is the caller's
    # call (the environment bumper updates a cookbook wherever it is already
    # pinned and adds it only where addable). The rest are never written but
    # still see whatever new versions the release puts on the Chef server.
    # Raises Error for a selected environment chef-repo does not have, which
    # the environment bumper would otherwise only hit after the merge.
    def environments(envs, chain: nil)
      ref = ref_for(chain)
      names = environment_names(ref)
      selection = ChefRepoEnvironments.expand(envs, all: names, default: @default_environments)
      missing = selection.keys - names
      raise Error, "no such chef-repo environment: #{missing.join(', ')} (check the env/* labels)" if missing.any?

      names.to_h do |name|
        pins = cookbook_versions(name, ref)
        live = ref ? live_versions(name) : pins
        [name, { selected: selection.key?(name), addable: selection[name] == true, pins: pins, live: live }]
      end
    end

    private

    def ref_for(chain)
      return nil unless chain

      branch = ChefRepoEnvironments.chain_branch(chain)
      @github.branch(@chef_repo, branch)
      branch
    rescue Octokit::NotFound
      nil
    end

    def environment_names(ref)
      @github.contents(@chef_repo, **contents_options('environments', ref))
             .map(&:name).select { |f| f.end_with?('.json') }.map { |f| File.basename(f, '.json') }
    end

    def cookbook_versions(name, ref)
      file = @github.contents(@chef_repo, **contents_options("environments/#{name}.json", ref))
      JSON.parse(file.content.unpack1('m'))['cookbook_versions'] || {}
    end

    # An environment the chain adds has no live pins yet.
    def live_versions(name)
      cookbook_versions(name, nil)
    rescue Octokit::NotFound
      {}
    end

    # No ref at all, rather than an empty one, reads the default branch.
    def contents_options(path, ref)
      ref ? { path: path, ref: ref } : { path: path }
    end
  end
end
