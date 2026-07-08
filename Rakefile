require 'rspec/core/rake_task'
require 'rubocop/rake_task'

RuboCop::RakeTask.new(:style)
RSpec::Core::RakeTask.new(:spec)

task default: %i(style spec)
