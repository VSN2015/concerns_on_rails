require "spec_helper"

# Accept-Language: "fr-CA, fr;q=0" -- the client explicitly refuses `fr`
# (RFC 9110 12.4.2: q=0 means "not acceptable"), yet Lookup truncation of
# fr-CA serves exactly the refused :fr.
RSpec.describe "Localizable serves a language the client refused with q=0" do
  around do |ex|
    saved = [I18n.available_locales, I18n.default_locale]
    I18n.available_locales = %i[en fr]
    I18n.default_locale = :en
    ex.run
  ensure
    I18n.available_locales, I18n.default_locale = saved
  end

  it "does not fall back to a q=0 language" do
    req = Struct.new(:headers).new({ "Accept-Language" => "fr-CA, fr;q=0" })
    klass = Class.new(FakeController) do
      def self.around_action(*); end
      include ConcernsOnRails::Controllers::Localizable

      localizable available: %i[en fr], default: :en
      define_method(:request) { req }
    end
    expect(klass.new.resolved_locale).to eq(:en)
  end

  it "compares the refusal case-insensitively with _ and - as one separator, and keeps trying later ranges" do
    I18n.available_locales = %i[en fr de]
    req = Struct.new(:headers).new({ "Accept-Language" => "fr_CA, FR;q=0, de;q=0.5" })
    klass = Class.new(FakeController) do
      def self.around_action(*); end
      include ConcernsOnRails::Controllers::Localizable

      localizable available: %i[en fr de], default: :en
      define_method(:request) { req }
    end
    expect(klass.new.resolved_locale).to eq(:de)
  end
end
