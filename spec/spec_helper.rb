require "bundler/setup"
require "active_record"
require "concerns_on_rails"
require "faker"
require "simplecov"
require "support/database"
require "active_support/core_ext/time" # for Time.zone

Time.zone = "UTC"

SimpleCov.start do
  add_filter "/spec/"
end


RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
end
