source 'https://rubygems.org'

# Development/test only: the Jenkins pipelines run against cinc-workstation's
# embedded ruby and never invoke bundler, so no lockfile is committed. The
# runtime gems below are pinned to the exact versions the omnibus ships so CI
# and local runs exercise what production has. Bump them only when
# cinc-workstation itself moves.
gem 'faraday-http-cache', '2.7.0'
gem 'git', '4.4.0'
gem 'octokit', '5.6.1'

group :development, :test do
  gem 'rake'
  gem 'rspec', '~> 3.13'
  gem 'rubocop', '~> 1.81'
  gem 'webmock', '~> 3.25'
end
