#!/usr/bin/env ruby
require_relative '../lib/cookbook_bumper'

begin
  CookbookBumper.from_env.run
rescue CookbookBumper::Error, CommunityDeps::Error, ChefRepoEnvironments::Error => e
  abort "Error: #{e.message}"
end
