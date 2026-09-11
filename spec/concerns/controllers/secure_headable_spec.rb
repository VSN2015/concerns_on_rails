require "spec_helper"

describe ConcernsOnRails::Controllers::SecureHeadable do
  # FakeController (controller_test_harness.rb) is a bare PORO with no callback
  # machinery, so we stub `after_action` to let the concern be included, then
  # exercise `apply_secure_headers` directly (the after_action wiring itself is
  # an ActionController responsibility, not this gem's).
  let(:base_class) do
    Class.new(FakeController) do
      def self.after_action(*); end
    end
  end

  # Build a controller class with the given secure_headers declaration applied.
  def controller_class(base, &declaration)
    Class.new(base) do
      include ConcernsOnRails::Controllers::SecureHeadable

      class_eval(&declaration) if declaration
    end
  end

  describe "#secure_headers presets" do
    it "sets a preset header on the response after apply_secure_headers" do
      klass = controller_class(base_class) { secure_headers :nosniff }
      controller = klass.new
      controller.apply_secure_headers

      expect(controller.response.headers["X-Content-Type-Options"]).to eq("nosniff")
    end

    it "emits X-XSS-Protection: 0 for :disable_legacy_xss (never the legacy auditor value)" do
      klass = controller_class(base_class) { secure_headers :disable_legacy_xss }
      controller = klass.new
      controller.apply_secure_headers

      value = controller.response.headers["X-XSS-Protection"]
      expect(value).to eq("0")
      expect(value).not_to eq("1; mode=block")
    end

    it "applies several presets at once" do
      klass = controller_class(base_class) do
        secure_headers :nosniff, :sameorigin_frame, :no_referrer_leak
      end
      controller = klass.new
      controller.apply_secure_headers
      headers = controller.response.headers

      expect(headers["X-Content-Type-Options"]).to eq("nosniff")
      expect(headers["X-Frame-Options"]).to eq("SAMEORIGIN")
      expect(headers["Referrer-Policy"]).to eq("strict-origin-when-cross-origin")
    end

    it "lets a later declaration win on a colliding header name" do
      klass = controller_class(base_class) do
        secure_headers :sameorigin_frame
        secure_headers :deny_frame
      end
      controller = klass.new
      controller.apply_secure_headers

      expect(controller.response.headers["X-Frame-Options"]).to eq("DENY")
    end

    it "merges custom \"Header-Name\" => value pairs" do
      klass = controller_class(base_class) do
        secure_headers "Permissions-Policy" => "geolocation=()"
      end
      controller = klass.new
      controller.apply_secure_headers

      expect(controller.response.headers["Permissions-Policy"]).to eq("geolocation=()")
    end

    it "raises on an unknown preset" do
      expect do
        controller_class(base_class) { secure_headers :teleport_shield }
      end.to raise_error(ArgumentError, /unknown preset/)
    end
  end

  describe "#apply_secure_headers" do
    it "no-ops cleanly when there is no response object" do
      klass = controller_class(base_class) { secure_headers :nosniff }
      controller = klass.new
      controller.response = nil

      expect { controller.apply_secure_headers }.not_to raise_error
    end
  end

  describe ".content_security_policy_for" do
    it "raises when the host has no native CSP support" do
      klass = controller_class(base_class)

      expect do
        klass.content_security_policy_for { |policy| policy }
      end.to raise_error(ArgumentError, /CSP requires/)
    end

    it "defines the policy via content_security_policy AND marks it report-only when report_only: true" do
      calls = []
      base = Class.new(base_class) do
        define_singleton_method(:content_security_policy) { |*a, **k, &b| calls << [:enforce, a, k, b] }
        define_singleton_method(:content_security_policy_report_only) { |*a, **k, &b| calls << [:report, a, k, b] }
      end
      klass = controller_class(base)
      block = ->(policy) { policy }

      klass.content_security_policy_for(report_only: true, &block)

      # The block MUST reach content_security_policy (the only block-accepting
      # method); report-only is an additional flag call that takes no block.
      enforce = calls.find { |c| c.first == :enforce }
      report  = calls.find { |c| c.first == :report }
      expect(enforce).not_to be_nil
      expect(enforce[3]).to eq(block)
      expect(report).not_to be_nil
      expect(report[1]).to eq([true])
      expect(report[3]).to be_nil
    end

    it "delegates to content_security_policy (enforcing) by default and forwards per-action options" do
      calls = []
      base = Class.new(base_class) do
        define_singleton_method(:content_security_policy) { |*a, **k, &b| calls << [:enforce, a, k, b] }
        define_singleton_method(:content_security_policy_report_only) { |*a, **k, &b| calls << [:report, a, k, b] }
      end
      klass = controller_class(base)
      block = ->(policy) { policy }

      klass.content_security_policy_for(only: :show, &block)

      expect(calls.size).to eq(1)
      kind, args, opts, forwarded = calls.first
      expect(kind).to eq(:enforce)
      expect(args).to eq([])
      expect(opts).to eq(only: :show)
      expect(forwarded).to eq(block)
    end
  end
  describe "modern presets and bundles" do
    def headers_for(*presets)
      klass = controller_class(base_class) { secure_headers(*presets) }
      controller = klass.new
      controller.apply_secure_headers
      controller.response.headers
    end

    it "adds HSTS, the cross-origin trio (COOP / COEP / CORP) and a conservative Permissions-Policy" do
      headers = headers_for(:hsts, :same_origin_opener, :require_corp_embedder, :same_origin_resource, :no_sensitive_permissions)
      expect(headers["Strict-Transport-Security"]).to eq("max-age=31536000; includeSubDomains")
      expect(headers["Cross-Origin-Opener-Policy"]).to eq("same-origin")
      expect(headers["Cross-Origin-Embedder-Policy"]).to eq("require-corp")
      expect(headers["Cross-Origin-Resource-Policy"]).to eq("same-origin")
      expect(headers["Permissions-Policy"])
        .to eq("accelerometer=(), camera=(), geolocation=(), gyroscope=(), magnetometer=(), microphone=(), payment=(), usb=()")
    end

    it "offers the popup-friendly COOP variant" do
      expect(headers_for(:same_origin_opener_allow_popups)["Cross-Origin-Opener-Policy"]).to eq("same-origin-allow-popups")
    end

    it ":recommended bundles the break-nothing baseline (no COEP/CORP/HSTS)" do
      headers = headers_for(:recommended)
      expect(headers).to include(
        "X-Content-Type-Options" => "nosniff",
        "X-Frame-Options" => "DENY",
        "Referrer-Policy" => "strict-origin-when-cross-origin",
        "X-Permitted-Cross-Domain-Policies" => "none",
        "X-XSS-Protection" => "0",
        "Cross-Origin-Opener-Policy" => "same-origin-allow-popups"
      )
      expect(headers).to have_key("Permissions-Policy")
      expect(headers).not_to have_key("Cross-Origin-Embedder-Policy")
      expect(headers).not_to have_key("Cross-Origin-Resource-Policy")
      expect(headers).not_to have_key("Strict-Transport-Security")
      expect(headers.size).to eq(7)
    end

    it ":cross_origin_isolation bundles COOP same-origin + COEP require-corp + CORP same-origin" do
      headers = headers_for(:cross_origin_isolation)
      expect(headers).to eq(
        "Cross-Origin-Opener-Policy" => "same-origin",
        "Cross-Origin-Embedder-Policy" => "require-corp",
        "Cross-Origin-Resource-Policy" => "same-origin"
      )
    end

    it "lets a later preset or custom value relax a bundled header (order wins)" do
      relaxed = headers_for(:recommended, :sameorigin_frame)
      expect(relaxed["X-Frame-Options"]).to eq("SAMEORIGIN")

      klass = controller_class(base_class) do
        secure_headers :recommended
        secure_headers "Permissions-Policy" => "geolocation=(self)"
      end
      controller = klass.new
      controller.apply_secure_headers
      expect(controller.response.headers["Permissions-Policy"]).to eq("geolocation=(self)")
    end

    it "lists presets and bundles in the unknown-preset error" do
      expect { controller_class(base_class) { secure_headers :nope } }
        .to raise_error(ArgumentError, /unknown preset 'nope'.*Valid presets: nosniff.*hsts.*Bundles: cross_origin_isolation, recommended/)
    end

    it "exposes the bundle map" do
      expect(described_class::BUNDLES.keys).to match_array(%i[cross_origin_isolation recommended])
      described_class::BUNDLES.each_value { |members| expect(members - described_class::PRESETS.keys).to be_empty }
    end
  end
end
