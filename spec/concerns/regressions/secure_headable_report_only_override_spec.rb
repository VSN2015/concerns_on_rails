require "spec_helper"
require "support/integration_harness"
require "action_dispatch/http/content_security_policy"

# Audit 2026-10-09, HTTP-2. Rails keeps the report-only flag in its own
# inherited before_action, not in the policy, and content_security_policy_for
# only ever forwarded `true`. So once a parent controller (or the app config)
# made the CSP report-only, a subclass's documented "override with an
# enforcing policy" -- content_security_policy_for { ... } -- added directives
# but stayed Report-Only: nothing was blocked and nothing warned.
describe "SecureHeadable content_security_policy_for report-only override" do
  # Runs the action through the real CSP middleware, which picks the header
  # name from request.content_security_policy_report_only.
  def csp_dispatch(klass, action = :show, app_report_only: nil)
    env = Rack::MockRequest.env_for("/")
    env["action_dispatch.content_security_policy_report_only"] = app_report_only unless app_report_only.nil?
    app = ActionDispatch::ContentSecurityPolicy::Middleware.new(klass.action(action))
    status, headers, body = app.call(env)
    chunks = body.enum_for(:each).to_a
    body.close if body.respond_to?(:close)
    [status, headers.to_h.transform_keys(&:downcase), chunks.join]
  end

  let(:report_only_parent) do
    IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::SecureHeadable

      content_security_policy_for(report_only: true) { |policy| policy.default_src :self }

      def show
        render html: request.content_security_policy_report_only.to_s
      end

      def index
        render html: request.content_security_policy_report_only.to_s
      end
    end
  end

  it "enforces a subclass's report_only: false policy over an inherited report-only one" do
    admin = Class.new(report_only_parent) do
      content_security_policy_for(report_only: false) { |policy| policy.script_src :self }
    end

    _status, headers, body = csp_dispatch(admin)

    expect(body).to eq("false")
    expect(headers["content-security-policy"]).to include("default-src 'self'", "script-src 'self'")
    expect(headers).not_to have_key("content-security-policy-report-only")
  end

  it "enforces a bare content_security_policy_for { } over an app-wide report-only config (the documented admin override)" do
    admin = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::SecureHeadable

      content_security_policy_for { |policy| policy.default_src :self }

      def show
        render html: request.content_security_policy_report_only.to_s
      end
    end

    _status, headers, body = csp_dispatch(admin, app_report_only: true)

    expect(body).to eq("false")
    expect(headers["content-security-policy"]).to eq("default-src 'self'")
    expect(headers).not_to have_key("content-security-policy-report-only")
  end

  it "keeps report_only: true reporting (under an enforcing parent too)" do
    enforcing = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::SecureHeadable

      content_security_policy_for { |policy| policy.default_src :self }

      def show
        render html: request.content_security_policy_report_only.to_s
      end
    end
    rollout = Class.new(enforcing) do
      content_security_policy_for(report_only: true) { |policy| policy.img_src :self }
    end

    _status, parent_headers, = csp_dispatch(enforcing)
    _status, headers, body = csp_dispatch(rollout)

    expect(parent_headers).to have_key("content-security-policy")
    expect(body).to eq("true")
    expect(headers["content-security-policy-report-only"]).to include("img-src 'self'")
    expect(headers).not_to have_key("content-security-policy")
  end

  it "scopes the enforcing switch to the actions the call names" do
    admin = Class.new(report_only_parent) do
      content_security_policy_for(only: :show) { |policy| policy.script_src :self }
    end

    _status, show_headers, = csp_dispatch(admin, :show)
    _status, index_headers, index_body = csp_dispatch(admin, :index)

    expect(show_headers).to have_key("content-security-policy")
    expect(index_body).to eq("true")
    expect(index_headers).to have_key("content-security-policy-report-only")
    expect(index_headers).not_to have_key("content-security-policy")
  end
end
