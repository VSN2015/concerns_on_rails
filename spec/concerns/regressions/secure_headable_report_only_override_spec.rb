require "spec_helper"
require "support/integration_harness"
require "action_dispatch/http/content_security_policy"

# Audit 2026-10-09, HTTP-2. Rails keeps the report-only flag in its own
# inherited before_action, not in the policy, and content_security_policy_for
# only ever forwarded `true`. So once a parent controller (or the app config)
# made the CSP report-only, a subclass's documented "override with an
# enforcing policy" -- content_security_policy_for(report_only: false) { ... } --
# added directives but stayed Report-Only: nothing was blocked and nothing
# warned. `report_only:` is now a three-state option: omitted / :inherit leaves
# the inherited flag alone (so an app that only adds a CDN to img_src keeps its
# report-only rollout), false enforces, true reports.
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

  def enforcing_parent
    IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::SecureHeadable

      content_security_policy_for(report_only: false) { |policy| policy.default_src :self }

      define_method(:show) { render html: request.content_security_policy_report_only.to_s }
    end
  end

  def app_level_controller(&policy_call)
    IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::SecureHeadable

      class_exec(&policy_call)

      define_method(:show) { render html: request.content_security_policy_report_only.to_s }
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

  it "enforces report_only: false over an app-wide report-only config" do
    admin = app_level_controller do
      content_security_policy_for(report_only: false) { |policy| policy.default_src :self }
    end

    _status, headers, body = csp_dispatch(admin, app_report_only: true)

    expect(body).to eq("false")
    expect(headers["content-security-policy"]).to eq("default-src 'self'")
    expect(headers).not_to have_key("content-security-policy-report-only")
  end

  it "leaves an app-wide report-only config alone when report_only: is omitted (a CDN allow-list must not start enforcing)" do
    cdn = app_level_controller do
      content_security_policy_for { |policy| policy.img_src :self, "https://cdn.example" }
    end

    _status, headers, body = csp_dispatch(cdn, app_report_only: true)

    expect(body).to eq("true")
    expect(headers["content-security-policy-report-only"]).to eq("img-src 'self' https://cdn.example")
    expect(headers).not_to have_key("content-security-policy")
  end

  it "keeps an app-wide enforcing config enforcing when report_only: is omitted" do
    cdn = app_level_controller do
      content_security_policy_for { |policy| policy.img_src :self }
    end

    _status, headers, body = csp_dispatch(cdn, app_report_only: false)

    expect(body).to eq("false")
    expect(headers["content-security-policy"]).to eq("img-src 'self'")
  end

  it "inherits a parent's report-only flag when a subclass omits report_only:, and for :inherit" do
    omitted = Class.new(report_only_parent) do
      content_security_policy_for { |policy| policy.img_src :self }
    end
    explicit = Class.new(report_only_parent) do
      content_security_policy_for(report_only: :inherit) { |policy| policy.img_src :self }
    end

    [omitted, explicit].each do |klass|
      _status, headers, body = csp_dispatch(klass)

      expect(body).to eq("true")
      expect(headers["content-security-policy-report-only"]).to include("default-src 'self'", "img-src 'self'")
      expect(headers).not_to have_key("content-security-policy")
    end
  end

  it "keeps report_only: true reporting (under an enforcing parent too)" do
    enforcing = enforcing_parent
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

  it "lets a later call in the same class change the mode: the last explicit report_only: wins, an omitted one keeps it" do
    flip_to_enforce = app_level_controller do
      content_security_policy_for(report_only: true) { |policy| policy.default_src :self }
      content_security_policy_for(report_only: false) { |policy| policy.img_src :self }
    end
    keep_reporting = app_level_controller do
      content_security_policy_for(report_only: true) { |policy| policy.default_src :self }
      content_security_policy_for { |policy| policy.img_src :self }
    end
    keep_enforcing = app_level_controller do
      content_security_policy_for(report_only: false) { |policy| policy.default_src :self }
      content_security_policy_for { |policy| policy.img_src :self }
    end

    _status, enforced, enforced_body = csp_dispatch(flip_to_enforce)
    _status, reported, reported_body = csp_dispatch(keep_reporting)
    _status, kept, kept_body = csp_dispatch(keep_enforcing, app_report_only: true)

    expect(enforced_body).to eq("false")
    expect(enforced["content-security-policy"]).to eq("default-src 'self'; img-src 'self'")
    expect(reported_body).to eq("true")
    expect(reported["content-security-policy-report-only"]).to eq("default-src 'self'; img-src 'self'")
    expect(kept_body).to eq("false")
    expect(kept["content-security-policy"]).to eq("default-src 'self'; img-src 'self'")
  end

  it "scopes the enforcing switch to the actions the call names" do
    admin = Class.new(report_only_parent) do
      content_security_policy_for(report_only: false, only: :show) { |policy| policy.script_src :self }
    end

    _status, show_headers, = csp_dispatch(admin, :show)
    _status, index_headers, index_body = csp_dispatch(admin, :index)

    expect(show_headers).to have_key("content-security-policy")
    expect(index_body).to eq("true")
    expect(index_headers).to have_key("content-security-policy-report-only")
    expect(index_headers).not_to have_key("content-security-policy")
  end

  it "refuses a report_only: that is not true, false or :inherit" do
    [nil, "false", :enforce, 1].each do |bad|
      klass = IntegrationHarness.build_controller { include ConcernsOnRails::Controllers::SecureHeadable }

      expect do
        klass.content_security_policy_for(report_only: bad) { |policy| policy.default_src :self }
      end.to raise_error(ArgumentError, /report_only/)
    end
  end
end
