require "spec_helper"
require "support/integration_harness"

# Audit 2026-10-29, HTTP-7. SecureHeadable compared header names
# case-sensitively: the HSTS guard (`name == HSTS_HEADER`) never recognised a
# custom "strict-transport-security" pair, so it went out over plain HTTP
# (RFC 6797 section 7.2 forbids that) and over an existing value; and custom
# keys were kept as given, so a lower-case "x-frame-options" next to a preset
# left TWO conflicting entries (two header lines on Rails < 7.1, whose response
# headers are a case-sensitive Hash).
describe "SecureHeadable header-name case" do
  def https_dispatch(klass, action = :show)
    env = Rack::MockRequest.env_for("https://example.com/")
    status, headers, body = klass.action(action).call(env)
    chunks = body.enum_for(:each).to_a
    body.close if body.respond_to?(:close)
    IntegrationHarness::Result.new(status, headers, chunks.join)
  end

  def controller_with(&declaration)
    IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::SecureHeadable

      class_eval(&declaration)
      define_method(:show) { render json: {} }
    end
  end

  describe "the merged header map" do
    it "folds a lower-case custom pair onto a preset: one entry, the later value, the first spelling" do
      klass = controller_with { secure_headers :deny_frame, "x-frame-options" => "SAMEORIGIN" }

      expect(klass.secure_headable_headers).to eq("X-Frame-Options" => "SAMEORIGIN")
    end

    it "folds across separate declarations and in either order" do
      klass = controller_with do
        secure_headers "x-frame-options" => "DENY"
        secure_headers :sameorigin_frame
      end

      expect(klass.secure_headable_headers).to eq("x-frame-options" => "SAMEORIGIN")
    end

    it "folds two custom spellings given in one call" do
      klass = controller_with { secure_headers "Permissions-Policy" => "a=()", "permissions-policy" => "b=()" }

      expect(klass.secure_headable_headers).to eq("Permissions-Policy" => "b=()")
    end

    it "keeps distinct headers distinct and a subclass's declaration from touching its parent's" do
      parent = controller_with { secure_headers :nosniff, "x-custom" => "1" }
      child = Class.new(parent) { secure_headers "X-CUSTOM" => "2", "X-Other" => "3" }

      expect(parent.secure_headable_headers).to eq("X-Content-Type-Options" => "nosniff", "x-custom" => "1")
      expect(child.secure_headable_headers)
        .to eq("X-Content-Type-Options" => "nosniff", "x-custom" => "2", "X-Other" => "3")
    end
  end

  describe "a lower-case custom Strict-Transport-Security pair" do
    let(:klass) { controller_with { secure_headers "strict-transport-security" => "max-age=63072000; preload" } }

    it "is withheld over plain HTTP" do
      result = IntegrationHarness.dispatch(klass, :show)

      expect(result.header("Strict-Transport-Security")).to be_nil
    end

    it "is sent once over HTTPS" do
      result = https_dispatch(klass)

      expect(result.header("Strict-Transport-Security")).to eq("max-age=63072000; preload")
    end

    it "does not overwrite an HSTS value already on the response, whatever its spelling" do
      c = Class.new(FakeController) { def self.after_action(*); end }
      c.include(ConcernsOnRails::Controllers::SecureHeadable)
      c.secure_headers "strict-transport-security" => "max-age=1"
      controller = c.new
      controller.response.set_header("Strict-Transport-Security", "max-age=63072000; preload")
      controller.apply_secure_headers
      expect(controller.response.headers).to eq("Strict-Transport-Security" => "max-age=63072000; preload")

      controller = c.new
      controller.response.set_header("strict-transport-security", "max-age=63072000; preload")
      controller.apply_secure_headers
      expect(controller.response.headers).to eq("strict-transport-security" => "max-age=63072000; preload")
    end
  end

  it "still treats the :hsts preset the same way (withheld over HTTP, sent over HTTPS)" do
    klass = controller_with { secure_headers :hsts }

    expect(IntegrationHarness.dispatch(klass, :show).header("Strict-Transport-Security")).to be_nil
    expect(https_dispatch(klass).header("Strict-Transport-Security")).to eq("max-age=31536000; includeSubDomains")
  end

  it "emits a lower-case custom X-Frame-Options over a preset as a single header with the later value" do
    klass = controller_with { secure_headers :deny_frame, "x-frame-options" => "SAMEORIGIN" }
    response_headers = IntegrationHarness.dispatch(klass, :show).headers

    frames = response_headers.select { |name, _| name.to_s.casecmp?("X-Frame-Options") }
    expect(frames.values).to eq(["SAMEORIGIN"])
  end

  # Rails < 7.1 response headers are a case-sensitive Hash and the framework's
  # default_headers carry "X-Frame-Options": a custom lower-case pair must
  # overwrite THAT entry, not sit next to it.
  it "writes over the spelling already on the response (Rails' default X-Frame-Options), leaving one header" do
    saved = ActionDispatch::Response.default_headers
    ActionDispatch::Response.default_headers = { "X-Frame-Options" => "SAMEORIGIN" }
    klass = controller_with { secure_headers "x-frame-options" => "DENY" }
    frames = IntegrationHarness.dispatch(klass, :show).headers.select { |name, _| name.to_s.casecmp?("X-Frame-Options") }

    expect(frames.values).to eq(["DENY"])
  ensure
    ActionDispatch::Response.default_headers = saved
  end

  it "adds the header under the registered spelling when the response has none" do
    klass = controller_with { secure_headers "x-custom-policy" => "on" }
    headers = IntegrationHarness.dispatch(klass, :show).headers

    expect(headers.select { |name, _| name.to_s.casecmp?("x-custom-policy") }.values).to eq(["on"])
  end
end
