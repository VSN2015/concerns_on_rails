require "action_controller"
require "rack/mock"

# Dispatches a single action through the REAL ActionController stack —
# callback chain, rescue_from, ActionController::Parameters — which the
# dependency-free FakeController harness cannot reproduce (it feeds
# HashWithIndifferentAccess params and never runs a real callback chain;
# that gap is exactly how the 1.22 Parameters / rescue_from regressions
# stayed green in 3,600+ lines of controller specs).
#
# ActionController::Metal.action(name) returns a Rack app, so no routes are
# needed for `render json:` / `head`.
module IntegrationHarness
  Result = Struct.new(:status, :headers, :body) do
    # Rack 3 downcases response header names; accept either spelling.
    def header(name)
      headers[name] || headers[name.downcase]
    end
  end

  module_function

  def dispatch(controller_class, action, method: "GET", query: "")
    env = Rack::MockRequest.env_for("/?#{query}", method: method)
    status, headers, body = controller_class.action(action).call(env)
    chunks = []
    body.each { |chunk| chunks << chunk }
    body.close if body.respond_to?(:close)
    Result.new(status, headers, chunks.join)
  end

  # Anonymous ActionController::Base subclass with a stable controller_path
  # (some instrumentation paths ask for it and anonymous classes have no name).
  def build_controller(&block)
    Class.new(ActionController::Base) do
      def self.controller_path
        "integration_harness"
      end

      class_eval(&block) if block
    end
  end
end
