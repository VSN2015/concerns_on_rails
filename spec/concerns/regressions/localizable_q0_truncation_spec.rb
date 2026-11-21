require "spec_helper"

# Accept-Language: "fr-CA, fr;q=0" -- the client explicitly refuses `fr`
# (RFC 9110 12.4.2: q=0 means "not acceptable"), yet Lookup truncation of
# fr-CA serves exactly the refused :fr.
RSpec.describe "Localizable serves a language the client refused with q=0" do
  around do |ex|
    saved = [I18n.available_locales, I18n.default_locale]
    I18n.available_locales = %i[en fr de]
    I18n.default_locale = :en
    ex.run
  ensure
    I18n.available_locales, I18n.default_locale = saved
  end

  def locale_for(header)
    req = Struct.new(:headers).new({ "Accept-Language" => header })
    klass = Class.new(FakeController) do
      def self.around_action(*); end
      include ConcernsOnRails::Controllers::Localizable

      localizable available: %i[en fr de], default: :en
      define_method(:request) { req }
    end
    klass.new.resolved_locale
  end

  it "does not fall back to a q=0 language" do
    expect(locale_for("fr-CA, fr;q=0")).to eq(:en)
  end

  it "compares the refusal case-insensitively with _ and - as one separator, and keeps trying later ranges" do
    expect(locale_for("fr_CA, FR;q=0, de;q=0.5")).to eq(:de)
  end

  it "does not read a malformed weight as a refusal: that part is just dropped" do
    expect(locale_for("fr-CA, fr;q=0.5000")).to eq(:fr)
    expect(locale_for("fr-CA, fr;q=1.5")).to eq(:fr)
  end

  it "does not refuse a tag the same header also lists with q > 0, in either order" do
    expect(locale_for("fr, fr;q=0")).to eq(:fr)
    expect(locale_for("fr;q=0, fr")).to eq(:fr)
  end

  # `refused` was an Array scanned per lookup range: ~80 KB of mixed ranges
  # took ~24 s against ~1.3 s without the check (quadratic). A Set keeps it
  # linear: 4x the header must cost nowhere near the 16x a quadratic scan does.
  it "resolves a large mixed header in linear time" do
    seconds = lambda do |n|
      header = ("a;q=0," * n) + ("b," * (n * 3))
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect(locale_for(header)).to eq(:en)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    end
    seconds.call(100) # warm up
    expect(seconds.call(6600)).to be < seconds.call(1650) * 9
  end
end
