require "spec_helper"
require "support/integration_harness"

# ErrorHandleable renders the malformed-query 400 from its own process_action
# frame, above Instrumentation -- before the callback chain, so SecureHeadable's
# prepend_before_action never ran and the response carries none of its headers.
RSpec.describe "SecureHeadable headers on ErrorHandleable's early 400" do
  it "carries the declared security headers" do
    klass = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::SecureHeadable
      include ConcernsOnRails::Controllers::ErrorHandleable

      secure_headers "Permissions-Policy" => "camera=()", "Cross-Origin-Resource-Policy" => "same-origin"
      define_method(:index) { render json: {} }
    end
    env = Rack::MockRequest.env_for("/")
    env["QUERY_STRING"] = "q=%FF"
    status, headers, _body = klass.action(:index).call(env)
    expect(status).to eq(400)
    expect(headers["cross-origin-resource-policy"] || headers["Cross-Origin-Resource-Policy"]).to eq("same-origin")
  end
end
