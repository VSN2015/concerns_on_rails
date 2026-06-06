require "spec_helper"

describe ConcernsOnRails::Controllers::Localizable do
  # A minimal stand-in for ActionDispatch::Request (only #headers is used).
  FakeRequest = Struct.new(:headers) unless defined?(FakeRequest)

  around do |example|
    saved = [I18n.available_locales, I18n.default_locale]
    I18n.available_locales = %i[en fr de]
    I18n.default_locale = :en
    example.run
  ensure
    I18n.available_locales = saved[0]
    I18n.default_locale = saved[1]
  end

  # Build a controller (FakeController has no callback machinery, so stub
  # around_action) with the given localizable declaration; optionally attach a
  # fake request carrying an Accept-Language header.
  def controller(accept_language: nil, params: {}, &declaration)
    request = accept_language && FakeRequest.new({ "Accept-Language" => accept_language })
    klass = Class.new(FakeController) do
      def self.around_action(*); end
      include ConcernsOnRails::Controllers::Localizable

      class_eval(&declaration) if declaration
      define_method(:request) { request }
    end
    klass.new(params: params)
  end

  describe "#resolved_locale" do
    it "picks an allowed locale from params" do
      c = controller(params: { locale: "fr" }) { localizable available: %i[en fr de], default: :en }
      expect(c.resolved_locale).to eq(:fr)
    end

    it "falls back to the default when the param is not allowed" do
      c = controller(params: { locale: "es" }) { localizable available: %i[en fr de], default: :en }
      expect(c.resolved_locale).to eq(:en)
    end

    it "reads the first allowed match from the Accept-Language header" do
      c = controller(accept_language: "es-MX,fr-CA;q=0.9,en;q=0.8") do
        localizable available: %i[en fr de], default: :en
      end
      expect(c.resolved_locale).to eq(:fr)
    end

    it "ignores the header when header: false" do
      c = controller(accept_language: "fr") do
        localizable available: %i[en fr de], default: :de, header: false
      end
      expect(c.resolved_locale).to eq(:de)
    end

    it "honors a custom param name" do
      c = controller(params: { lang: "de" }) do
        localizable available: %i[en fr de], default: :en, param: :lang
      end
      expect(c.resolved_locale).to eq(:de)
    end

    it "never returns a locale I18n cannot switch to" do
      c = controller(params: { locale: "fr" }) { localizable available: %i[en fr], default: :en }
      I18n.available_locales = %i[en] # fr no longer configured in the app
      expect(c.resolved_locale).to eq(:en)
    end
  end

  describe "#switch_locale" do
    it "runs the block under the resolved locale and restores afterwards" do
      c = controller(params: { locale: "fr" }) { localizable available: %i[en fr de], default: :en }

      inside = c.switch_locale { I18n.locale }
      expect(inside).to eq(:fr)
      expect(I18n.locale).to eq(:en) # restored
    end
  end
end
