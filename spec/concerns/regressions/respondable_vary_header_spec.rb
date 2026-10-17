require "spec_helper"
require "support/integration_harness"
require "json"

# Audit 2026-10-09, HTTP-5. render_success(headers: { "Vary" => ... }) did a
# plain set, so it overwrote the Vary that Localizable / Timezoneable write
# BEFORE the action (Accept-Language / Time-Zone), and -- Vary now being
# non-blank -- suppressed Rails' own `Vary: Accept` too. A shared cache keyed
# on URL + `Vary: Origin` then handed the French body to the next English
# client. Vary is as additive as Link (RFC 9110 §12.5.5).
describe "Respondable headers: Vary appends" do
  around do |example|
    saved = [I18n.available_locales, I18n.default_locale]
    I18n.available_locales = %i[en fr]
    I18n.default_locale = :en
    example.run
  ensure
    I18n.available_locales, I18n.default_locale = saved
  end

  def vary_of(result)
    result.header("Vary").to_s.split(",").map(&:strip)
  end

  def build(vary: "Origin", &block)
    IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Respondable

      class_eval(&block) if block
      define_method(:show) { render_success(data: { ok: true }, headers: { "Vary" => vary }) }
      define_method(:plain) { render_success(data: { ok: true }) }
    end
  end

  it "keeps Localizable's Accept-Language when the action adds a Vary dimension" do
    klass = build do
      include ConcernsOnRails::Controllers::Localizable

      localizable available: %i[en fr], default: :en
    end

    result = IntegrationHarness.dispatch(klass, :show, headers: { "Accept-Language" => "fr" })

    expect(result.header("Content-Language")).to eq("fr")
    expect(vary_of(result)).to include("Accept-Language", "Origin")
  end

  it "keeps Timezoneable's Time-Zone when the action adds a Vary dimension" do
    klass = build do
      include ConcernsOnRails::Controllers::Timezoneable

      timezoneable default: "UTC", response_header: true
    end

    result = IntegrationHarness.dispatch(klass, :show, headers: { "Time-Zone" => "Tokyo" })

    expect(vary_of(result)).to include("Time-Zone", "Origin")
  end

  it "keeps the dimensions Rails itself would have added (Vary: Accept) on a content-negotiated request" do
    klass = build
    accept = { "Accept" => "application/json" }

    without = IntegrationHarness.dispatch(klass, :plain, headers: accept)
    with = IntegrationHarness.dispatch(klass, :show, headers: accept)

    expect(vary_of(with)).to include(*vary_of(without), "Origin")
  end

  it "splits a multi-dimension value and de-duplicates case-insensitively" do
    klass = build(vary: "origin, Accept-Language, Origin") do
      include ConcernsOnRails::Controllers::Localizable

      localizable available: %i[en fr], default: :en
    end

    vary = vary_of(IntegrationHarness.dispatch(klass, :show, headers: { "Accept-Language" => "fr" }))

    expect(vary.map(&:downcase).tally.values).to all(eq(1))
    expect(vary.map(&:downcase)).to include("accept-language", "origin")
  end

  it "leaves a Vary: * response alone" do
    klass = build do
      before_action { response.set_header("Vary", "*") }
    end

    expect(IntegrationHarness.dispatch(klass, :show).header("Vary")).to eq("*")
  end

  it "lets a caller's Vary: * replace the named dimensions" do
    klass = build(vary: "*") do
      include ConcernsOnRails::Controllers::Localizable

      localizable available: %i[en fr], default: :en
    end

    expect(IntegrationHarness.dispatch(klass, :show, headers: { "Accept-Language" => "fr" }).header("Vary")).to eq("*")
  end

  it "still sets Vary when nothing else wrote one" do
    expect(vary_of(IntegrationHarness.dispatch(build, :show))).to include("Origin")
  end

  it "applies to render_created's headers: as well" do
    klass = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Respondable
      include ConcernsOnRails::Controllers::Localizable

      localizable available: %i[en fr], default: :en
      define_method(:create) { render_created(data: { id: 1 }, location: "/things/1", headers: { "Vary" => "Origin" }) }
    end

    result = IntegrationHarness.dispatch(klass, :create, method: "POST", headers: { "Accept-Language" => "fr" })

    expect(result.status).to eq(201)
    expect(vary_of(result)).to include("Accept-Language", "Origin")
  end
end
