#!/usr/bin/env ruby
require_relative '../lib/cookbook_bumper'

begin
  CookbookBumper.from_env.run
rescue CookbookBumper::Error => e
  abort "Error: #{e.message}"
end
