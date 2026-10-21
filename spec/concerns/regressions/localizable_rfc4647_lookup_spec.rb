require "spec_helper"
require "support/integration_harness"
require "json"

# Audit 2026-10-09, HTTP-6. The Accept-Language lookup tried only the full tag
# and then its primary subtag, so `zh-Hant-TW` (what iOS / macOS send) jumped
# straight past an available :"zh-Hant" to :zh -- usually Simplified Chinese --
# and `sr-Latn-RS` past :"sr-Latn" to Cyrillic :sr. RFC 4647 §3.4 Lookup
# truncates the range one subtag at a time from the right, dropping a
# singleton the cut leaves exposed.
describe "Localizable Accept-Language lookup (RFC 4647 §3.4)" do
  around do |example|
    saved = [I18n.available_locales, I18n.default_locale]
    I18n.available_locales = %i[en en-US zh zh-Hant sr sr_Latn pt pt_BR pt-BR fr]
    I18n.default_locale = :en
    example.run
  ensure
    I18n.available_locales, I18n.default_locale = saved
  end

  let(:fake_request) { Struct.new(:headers) }

  # FakeController has no callback machinery: stub around_action and read
  # resolved_locale directly.
  def resolve(accept_language, available)
    request = fake_request.new({ "Accept-Language" => accept_language })
    klass = Class.new(FakeController) do
      def self.around_action(*); end
      include ConcernsOnRails::Controllers::Localizable

      localizable available: available, default: :en
      define_method(:request) { request }
    end
    klass.new(params: {})
  end

  it "selects an available script locale before falling back to the language" do
    klass = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Localizable

      localizable available: %i[en zh zh-Hant], default: :en

      def show
        render json: { locale: I18n.locale }
      end
    end

    result = IntegrationHarness.dispatch(klass, :show, headers: { "Accept-Language" => "zh-Hant-TW" })

    expect(JSON.parse(result.body)["locale"]).to eq("zh-Hant")
    expect(result.header("Content-Language")).to eq("zh-Hant")
  end

  it "truncates one subtag at a time, matching `-` and `_` alike and returning the app's own symbol" do
    expect(resolve("sr-Latn-RS", %i[en sr sr_Latn]).resolved_locale).to eq(:sr_Latn)
    expect(resolve("zh-Hant-TW", %i[en zh]).resolved_locale).to eq(:zh)
    expect(resolve("fr-CA", %i[en fr]).resolved_locale).to eq(:fr)
  end

  it "drops a singleton the truncation leaves exposed, along with its subtag" do
    expect(resolve("en-US-x-pirate", %i[en en-US]).resolved_locale).to eq(:'en-US')
  end

  it "keeps the client's own spelling at every level, so an exact separator still wins" do
    expect(resolve("pt_BR-u-ca-gregory", %i[en pt pt-BR pt_BR]).resolved_locale).to eq(:pt_BR)
    expect(resolve("pt-BR-u-ca-gregory", %i[en pt pt_BR pt-BR]).resolved_locale).to eq(:'pt-BR')
  end

  it "still exhausts each range before the next one in preference order" do
    expect(resolve("zh-Hant-TW, en;q=0.9", %i[en zh]).resolved_locale).to eq(:zh)
    expect(resolve("de-AT;q=0.5, zh-Hant-TW", %i[en fr zh-Hant]).resolved_locale).to eq(:'zh-Hant')
  end

  # Such a range could never match (matching compares whole tags), and building
  # every prefix of a tag with thousands of subtags is quadratic work per request.
  it "never builds a range with more subtags than any available locale has" do
    controller = resolve("zh-#{(['ab'] * 5_000).join('-')}", %i[en zh zh-Hant])
    candidates = []
    allow(controller).to receive(:match_locale).and_wrap_original do |original, candidate, allowed|
      candidates << candidate.to_s
      original.call(candidate, allowed)
    end

    expect(controller.resolved_locale).to eq(:zh)
    expect(candidates.map { |candidate| candidate.count("-_") }.max).to be <= 1
  end
end
