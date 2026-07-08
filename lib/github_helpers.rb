require 'faraday-http-cache'
require 'octokit'

module GithubHelpers
  module_function

  # Build an Octokit client with HTTP caching. Middleware is passed per-client
  # rather than set globally on Octokit so requiring this file has no side
  # effects on other Octokit users.
  def client(token: ENV.fetch('GITHUB_TOKEN'))
    stack = Faraday::RackBuilder.new do |builder|
      builder.use Faraday::HttpCache, serializer: Marshal, shared_cache: false
      builder.use Octokit::Response::RaiseError
      builder.adapter Faraday.default_adapter
    end
    client = Octokit::Client.new(access_token: token, middleware: stack)
    client.auto_paginate = true
    client
  end

  # HTTPS clone URL with the token embedded, for repos the app must push to.
  # Never log the return value.
  def authenticated_url(repo_path, token: ENV.fetch('GITHUB_TOKEN'))
    "https://x-access-token:#{token}@github.com/#{repo_path}.git"
  end
end
