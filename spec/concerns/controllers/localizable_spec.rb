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

    it "rejects a header locale with q=0 (not acceptable)" do
      c = controller(accept_language: "fr;q=0,de") do
        localizable available: %i[en fr de], default: :en
      end
      expect(c.resolved_locale).to eq(:de)
    end

    it "honors q-value preference order, not header order" do
      c = controller(accept_language: "en;q=0.8,fr;q=0.9") do
        localizable available: %i[en fr de], default: :en
      end
      expect(c.resolved_locale).to eq(:fr)
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
  describe "response headers (Content-Language / Vary)" do
    it "sets Content-Language to the resolved locale while switching" do
      c = controller(params: { locale: "fr" }) { localizable available: %i[en fr de], default: :en }
      c.switch_locale { nil }
      expect(c.response.headers["Content-Language"]).to eq("fr")
    end

    it "appends Vary: Accept-Language when the header is a locale source, merging with an existing Vary" do
      c = controller(accept_language: "de") { localizable available: %i[en fr de], default: :en }
      c.response.set_header("Vary", "Accept")
      c.switch_locale { nil }
      expect(c.response.headers["Vary"]).to eq("Accept, Accept-Language")
      expect(c.response.headers["Content-Language"]).to eq("de")

      again = controller(accept_language: "de") { localizable available: %i[en fr de], default: :en }
      again.response.set_header("Vary", "Accept-Language")
      again.switch_locale { nil }
      expect(again.response.headers["Vary"]).to eq("Accept-Language") # de-duplicated
    end

    it "does not add Vary when header: false (the locale cannot depend on Accept-Language)" do
      c = controller(params: { locale: "fr" }) { localizable available: %i[en fr de], default: :en, header: false }
      c.switch_locale { nil }
      expect(c.response.headers["Content-Language"]).to eq("fr")
      expect(c.response.headers).not_to have_key("Vary")
    end

    it "can be switched off with response_headers: false" do
      c = controller(accept_language: "fr") { localizable available: %i[en fr de], default: :en, response_headers: false }
      c.switch_locale { nil }
      expect(c.response.headers).not_to have_key("Content-Language")
      expect(c.response.headers).not_to have_key("Vary")
    end

    it "emits a BCP 47 tag (underscore locales become dashed)" do
      saved = I18n.available_locales
      I18n.available_locales = %i[en pt_BR]
      c = controller(params: { locale: "pt_BR" }) { localizable available: %i[en pt_BR], default: :en }
      c.switch_locale { nil }
      expect(c.response.headers["Content-Language"]).to eq("pt-BR")
    ensure
      I18n.available_locales = saved
    end

    it "writes the headers before the action, so a raising action (rescue_from path) still carries them" do
      c = controller(accept_language: "de") { localizable available: %i[en fr de], default: :en }
      expect { c.switch_locale { raise "boom" } }.to raise_error("boom")
      expect(c.response.headers["Content-Language"]).to eq("de")
      expect(c.response.headers["Vary"]).to eq("Accept-Language")
    end

    it "is a no-op on a controller without a response object" do
      klass = Class.new do
        def self.around_action(*); end
        # no ActiveSupport here — stub what the included block needs
        def self.class_attribute(*, **); end

        def self.localizable_options
          {}
        end
        include ConcernsOnRails::Controllers::Localizable
      end
      bare = klass.new
      allow(bare).to receive(:resolved_locale).and_return(:en)
      expect(bare.switch_locale { I18n.locale }).to eq(:en)
    end
  end
end
