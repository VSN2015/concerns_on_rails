require "spec_helper"

# Documented order: param -> Accept-Language -> default -> I18n.default_locale.
# A param that matches `available:` but not I18n.available_locales jumps
# straight to I18n.default_locale, skipping the header AND `default:`.
RSpec.describe "Localizable: a param I18n cannot switch to falls through header and default:" do
  around do |ex|
    saved = [I18n.available_locales, I18n.default_locale]
    I18n.available_locales = %i[en fr]
    I18n.default_locale = :en
    ex.run
  ensure
    I18n.available_locales, I18n.default_locale = saved
  end

  it "falls through to the Accept-Language header" do
    req = Struct.new(:headers).new({ "Accept-Language" => "fr" })
    klass = Class.new(FakeController) do
      def self.around_action(*); end
      include ConcernsOnRails::Controllers::Localizable

      localizable available: %i[en fr de], default: :en
      define_method(:request) { req }
    end
    expect(klass.new(params: { locale: "de" }).resolved_locale).to eq(:fr)
  end

  it "falls through to default:" do
    klass = Class.new(FakeController) do
      def self.around_action(*); end
      include ConcernsOnRails::Controllers::Localizable

      localizable available: %i[en fr de], default: :fr, header: false
      define_method(:request) { nil }
    end
    expect(klass.new(params: { locale: "de" }).resolved_locale).to eq(:fr)
  end
end
