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

    it "delegates to content_security_policy_report_only when report_only: true" do
      calls = []
      base = Class.new(base_class) do
        define_singleton_method(:content_security_policy) { |*a, **k, &b| calls << [:enforce, a, k, b] }
        define_singleton_method(:content_security_policy_report_only) { |*a, **k, &b| calls << [:report, a, k, b] }
      end
      klass = controller_class(base)
      block = ->(policy) { policy }

      klass.content_security_policy_for(report_only: true, &block)

      expect(calls.size).to eq(1)
      kind, args, _opts, forwarded = calls.first
      expect(kind).to eq(:report)
      expect(args).to eq([true])
      expect(forwarded).to eq(block)
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
end
