#!/usr/bin/env ruby
require_relative '../lib/environment_bumper'

begin
  EnvironmentBumper.from_env.run
rescue EnvironmentBumper::Error => e
  abort "Error: #{e.message}"
end
