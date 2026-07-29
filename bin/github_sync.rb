#!/usr/bin/env ruby
require_relative '../lib/github_sync'

begin
  result = GithubSync.from_env.run
  # Exit 2 signals partial failure; the Jenkinsfile maps it to UNSTABLE.
  exit 2 unless result[:failures].empty?
rescue GithubSync::Error => e
  abort "Error: #{e.message}"
end
