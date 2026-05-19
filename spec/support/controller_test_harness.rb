require "active_support/hash_with_indifferent_access"

# Lightweight, dependency-free test harness for the controller concerns.
# The four controller concerns in this gem only touch `params`, `response`,
# and (for Respondable) `render` — so we don't need a real Rails stack.
#
# Subclass FakeController in specs, include the concern under test, and
# instantiate with the params/response you need.
class FakeResponse
  attr_reader :headers

  def initialize
    @headers = {}
  end

  def set_header(key, value)
    @headers[key] = value
  end
end

class FakeController
  attr_accessor :params, :response
  attr_reader :rendered

  def initialize(params: {})
    @params = ActiveSupport::HashWithIndifferentAccess.new(params)
    @response = FakeResponse.new
    @rendered = nil
  end

  # Stand-in for ActionController::Base#render. Captures what would have
  # been rendered so specs can assert on the json body / status.
  def render(options)
    @rendered = options
  end
end
