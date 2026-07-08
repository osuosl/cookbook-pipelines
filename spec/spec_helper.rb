require 'json'
require 'tmpdir'
require 'webmock/rspec'

WebMock.disable_net_connect!

module SpecHelpers
  def fixture(name)
    File.read(File.join(__dir__, 'fixtures', name))
  end

  def json_fixture(name)
    JSON.parse(fixture(name))
  end
end

RSpec.configure do |config|
  config.include SpecHelpers
  config.disable_monkey_patching!
  config.order = :random
end
