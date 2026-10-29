require "spec_helper"
require "support/integration_harness"

# Audit 2026-10-29, HTTP-6. ActionDispatch::SSL (`config.force_ssl`) fills
# Strict-Transport-Security only when the header is ABSENT (`||=`), so the
# controller's `:hsts` preset won and overrode the app's `config.ssl_options`
# (shortening Rails' 2-year default to 1 year, dropping `preload:`, adding
# includeSubDomains where `subdomains: false` was chosen). Under force_ssl the
# preset now steps aside; an explicit custom pair with another value is still
# honoured.
describe "SecureHeadable :hsts preset under config.force_ssl" do
  let(:preset_value) { ConcernsOnRails::Controllers::SecureHeadable::PRESETS[:hsts].last }

  def with_force_ssl(value)
    config = Struct.new(:force_ssl).new(value)
    app = Struct.new(:config).new(config)
    stub_const("Rails", Module.new)
    Rails.define_singleton_method(:application) { app }
  end

  def https_hsts(klass)
    env = Rack::MockRequest.env_for("https://example.com/")
    _status, headers, body = klass.action(:show).call(env)
    body.close if body.respond_to?(:close)
    headers["Strict-Transport-Security"] || headers["strict-transport-security"]
  end

  def controller_with(&declaration)
    IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::SecureHeadable

      class_eval(&declaration)
      define_method(:show) { render json: {} }
    end
  end

  it "skips the :hsts preset (HTTPS request) when force_ssl is on, leaving the header to ActionDispatch::SSL" do
    with_force_ssl(true)

    expect(https_hsts(controller_with { secure_headers :hsts })).to be_nil
  end

  it "keeps sending the preset when force_ssl is off, or when there is no Rails application" do
    with_force_ssl(false)
    expect(https_hsts(controller_with { secure_headers :hsts })).to eq(preset_value)

    stub_const("Rails", Module.new)
    Rails.define_singleton_method(:application) { nil }
    expect(https_hsts(controller_with { secure_headers :hsts })).to eq(preset_value)
  end

  it "still honours an explicit custom Strict-Transport-Security pair under force_ssl" do
    with_force_ssl(true)
    klass = controller_with { secure_headers "Strict-Transport-Security" => "max-age=63072000; includeSubDomains; preload" }

    expect(https_hsts(klass)).to eq("max-age=63072000; includeSubDomains; preload")
  end

  it "only affects the :hsts preset, not the other presets" do
    with_force_ssl(true)
    klass = controller_with { secure_headers :hsts, :nosniff }
    env = Rack::MockRequest.env_for("https://example.com/")
    _status, headers, body = klass.action(:show).call(env)
    body.close if body.respond_to?(:close)

    expect(headers["X-Content-Type-Options"]).to eq("nosniff")
  end

  it "reads force_ssl per request, not at class load" do
    config = Struct.new(:force_ssl).new(false)
    app = Struct.new(:config).new(config)
    stub_const("Rails", Module.new)
    Rails.define_singleton_method(:application) { app }
    klass = controller_with { secure_headers :hsts }

    expect(https_hsts(klass)).to eq(preset_value)
    config.force_ssl = true
    expect(https_hsts(klass)).to be_nil
  end
end
