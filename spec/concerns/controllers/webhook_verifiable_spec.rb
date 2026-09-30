# frozen_string_literal: true

require "spec_helper"
require "openssl"
require "support/integration_harness"

describe ConcernsOnRails::Controllers::WebhookVerifiable do
  WebhookFakeRequest = Struct.new(:headers, :raw_post) unless defined?(WebhookFakeRequest)

  WH_SECRET = "whsec_test"
  WH_BODY = '{"event":"order.paid","id":42}'

  let(:base_class) do
    Class.new(FakeController) do
      def self.before_action(*); end
      def self.after_action(*); end
    end
  end

  def verifiable_class(&declaration)
    Class.new(base_class) do
      include ConcernsOnRails::Controllers::WebhookVerifiable

      class_eval(&declaration) if declaration
    end
  end

  def instance(klass, action: "receive", headers: {}, body: WH_BODY, params: {})
    c = klass.new(params: params)
    req = WebhookFakeRequest.new(headers, body)
    c.define_singleton_method(:request) { req }
    c.define_singleton_method(:action_name) { action }
    c
  end

  def hex_hmac(secret, body, digest: "SHA256")
    OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new(digest), secret, body)
  end

  def github_sig(secret, body)
    "sha256=#{hex_hmac(secret, body)}"
  end

  def shopify_sig(secret, body)
    [OpenSSL::HMAC.digest(OpenSSL::Digest.new("SHA256"), secret, body)].pack("m0")
  end

  def stripe_sig(secret, body, at:)
    hex_hmac(secret, "#{at}.#{body}")
  end

  def stripe_header(secret, body, at:)
    "t=#{at},v1=#{stripe_sig(secret, body, at: at)}"
  end

  def expect_failure(controller, status, code)
    expect(controller.rendered).not_to be_nil
    expect(controller.rendered[:status]).to eq(status)
    expect(controller.rendered[:json][:error][:code]).to eq(code)
    expect(controller.webhook_verified?).to be(false)
  end

  describe "#verify_webhook_signature! — dispatch" do
    it "does nothing for an action no rule covers" do
      klass = verifiable_class { verify_webhook :covered, secret: WH_SECRET, scheme: :hex, header: "X-Sig" }
      c = instance(klass, action: "other")

      c.verify_webhook_signature!
      expect(c.rendered).to be_nil
      expect(c.webhook_verified?).to be(false)
    end

    it "applies a rule with no actions (catch-all) to every action" do
      klass = verifiable_class { verify_webhook secret: WH_SECRET, scheme: :hex, header: "X-Sig" }
      c = instance(klass, action: "anything", headers: { "X-Sig" => hex_hmac(WH_SECRET, WH_BODY) })

      c.verify_webhook_signature!
      expect(c.rendered).to be_nil
      expect(c.webhook_verified?).to be(true)
    end

    it "uses the first matching rule when several cover one action" do
      klass = verifiable_class do
        verify_webhook :receive, secret: "first-secret", scheme: :hex, header: "X-Sig"
        verify_webhook :receive, secret: "second-secret", scheme: :hex, header: "X-Sig"
      end

      passing = instance(klass, headers: { "X-Sig" => hex_hmac("first-secret", WH_BODY) })
      passing.verify_webhook_signature!
      expect(passing.webhook_verified?).to be(true)

      failing = instance(klass, headers: { "X-Sig" => hex_hmac("second-secret", WH_BODY) })
      failing.verify_webhook_signature!
      expect_failure(failing, :unauthorized, "webhook_signature_invalid")
    end

    # Lookup is by SPECIFICITY: an action-specific rule naming the action wins
    # over any catch-all, whichever class declared either. Pre-fix it was
    # first-match over inherited-rules-first, so a parent's catch-all shadowed
    # every rule a subclass declared.
    it "prefers a subclass's specific rule over an inherited catch-all" do
      parent = verifiable_class { verify_webhook secret: "parent-secret", scheme: :hex, header: "X-Sig" }
      child = Class.new(parent) { verify_webhook :receive, secret: "child-secret", scheme: :hex, header: "X-Sig" }

      own = instance(child, headers: { "X-Sig" => hex_hmac("child-secret", WH_BODY) })
      own.verify_webhook_signature!
      expect(own.webhook_verified?).to be(true)

      # The parent's catch-all still covers every action the child did not name.
      other = instance(child, action: "other", headers: { "X-Sig" => hex_hmac("parent-secret", WH_BODY) })
      other.verify_webhook_signature!
      expect(other.webhook_verified?).to be(true)

      # And the parent itself is untouched by the child's declaration.
      expect(parent.webhook_rules.size).to eq(1)
      at_parent = instance(parent, headers: { "X-Sig" => hex_hmac("child-secret", WH_BODY) })
      at_parent.verify_webhook_signature!
      expect_failure(at_parent, :unauthorized, "webhook_signature_invalid")
    end

    # The reverse direction: a subclass adding a catch-all for its NEW actions
    # must not take over an action its parent named — nor drop that rule's
    # own replay:/scheme/tolerance.
    it "keeps an inherited specific rule (and its replay:) ahead of a subclass catch-all" do
      replay_store = Class.new do
        attr_reader :data

        def initialize
          @data = {}
        end

        def write(key, value, options = {})
          return nil if options[:unless_exist] && @data.key?(key)

          @data[key] = value
          true
        end

        def read(key)
          @data[key]
        end
      end.new
      parent = verifiable_class do
        verify_webhook :receive, secret: "parent-secret", scheme: :hex, header: "X-Sig", replay: replay_store
      end
      child = Class.new(parent) { verify_webhook secret: "generic", scheme: :hex, header: "X-Sig" }

      inherited = instance(child, headers: { "X-Sig" => hex_hmac("parent-secret", WH_BODY) })
      inherited.verify_webhook_signature!
      expect(inherited.webhook_verified?).to be(true)
      expect(replay_store.data.size).to eq(1)

      generic_on_receive = instance(child, headers: { "X-Sig" => hex_hmac("generic", WH_BODY) })
      generic_on_receive.verify_webhook_signature!
      expect_failure(generic_on_receive, :unauthorized, "webhook_signature_invalid")

      new_action = instance(child, action: "other", headers: { "X-Sig" => hex_hmac("generic", WH_BODY) })
      new_action.verify_webhook_signature!
      expect(new_action.webhook_verified?).to be(true)
    end

    # A shared concern module's `included { verify_webhook secret: ... }`
    # lands in the host BEFORE the host's own specific rules; that must boot
    # and the specific rules must still apply.
    it "lets a specific rule declared after a same-class catch-all match" do
      klass = verifiable_class do
        verify_webhook secret: "generic", scheme: :hex, header: "X-Sig"
        verify_webhook :receive, secret: "specific", scheme: :hex, header: "X-Sig"
      end

      specific = instance(klass, headers: { "X-Sig" => hex_hmac("specific", WH_BODY) })
      specific.verify_webhook_signature!
      expect(specific.webhook_verified?).to be(true)

      other = instance(klass, action: "other", headers: { "X-Sig" => hex_hmac("generic", WH_BODY) })
      other.verify_webhook_signature!
      expect(other.webhook_verified?).to be(true)
    end

    it "resolves across several levels: most-derived specific, then most-derived catch-all" do
      grandparent = verifiable_class do
        verify_webhook :receive, secret: "gp-specific", scheme: :hex, header: "X-Sig"
        verify_webhook secret: "gp-generic", scheme: :hex, header: "X-Sig"
      end
      parent = Class.new(grandparent) do
        verify_webhook :receive, :ping, secret: "p-first", scheme: :hex, header: "X-Sig"
        verify_webhook :receive, secret: "p-second", scheme: :hex, header: "X-Sig"
      end
      child = Class.new(parent) { verify_webhook secret: "c-generic", scheme: :hex, header: "X-Sig" }

      expect(child.webhook_rules.map { |rule| rule[:secret] })
        .to eq(%w[c-generic p-first p-second gp-specific gp-generic])

      verified = lambda do |action, secret|
        c = instance(child, action: action, headers: { "X-Sig" => hex_hmac(secret, WH_BODY) })
        c.verify_webhook_signature!
        c.webhook_verified?
      end
      expect(verified.call("receive", "p-first")).to be(true)   # parent's first specific rule
      expect(verified.call("receive", "p-second")).to be(false) # declaration order within a class
      expect(verified.call("receive", "c-generic")).to be(false)
      expect(verified.call("ping", "p-first")).to be(true)
      expect(verified.call("other", "c-generic")).to be(true)   # most-derived catch-all
      expect(verified.call("other", "gp-generic")).to be(false)
    end

    it "treats a controller without a usable request as a missing signature (no crash)" do
      klass = verifiable_class { verify_webhook :receive, secret: WH_SECRET, scheme: :hex, header: "X-Sig" }
      c = klass.new(params: {})
      c.define_singleton_method(:action_name) { "receive" }

      c.verify_webhook_signature!
      expect_failure(c, :unauthorized, "webhook_signature_missing")
    end
  end

  describe ":hex scheme" do
    def hex_class(secret: WH_SECRET, digest: :sha256)
      verifiable_class { verify_webhook :receive, secret: secret, scheme: :hex, header: "X-Sig", digest: digest }
    end

    it "passes with the correct HMAC and sets webhook_verified?" do
      c = instance(hex_class, headers: { "X-Sig" => hex_hmac(WH_SECRET, WH_BODY) })

      c.verify_webhook_signature!
      expect(c.rendered).to be_nil
      expect(c.webhook_verified?).to be(true)
    end

    it "renders 401 webhook_signature_invalid for a wrong signature" do
      c = instance(hex_class, headers: { "X-Sig" => hex_hmac("wrong-secret", WH_BODY) })

      c.verify_webhook_signature!
      expect_failure(c, :unauthorized, "webhook_signature_invalid")
    end

    it "renders 401 webhook_signature_missing when the header is absent" do
      c = instance(hex_class)

      c.verify_webhook_signature!
      expect_failure(c, :unauthorized, "webhook_signature_missing")
    end

    it "renders 401 webhook_signature_missing for a whitespace-only header" do
      c = instance(hex_class, headers: { "X-Sig" => "   " })

      c.verify_webhook_signature!
      expect_failure(c, :unauthorized, "webhook_signature_missing")
    end

    it "tolerates surrounding whitespace around a valid signature" do
      c = instance(hex_class, headers: { "X-Sig" => "  #{hex_hmac(WH_SECRET, WH_BODY)}\n" })

      c.verify_webhook_signature!
      expect(c.webhook_verified?).to be(true)
    end

    it "treats non-hex garbage as invalid without raising" do
      c = instance(hex_class, headers: { "X-Sig" => "zzzz-not-hex-\xC3\x28" })

      expect { c.verify_webhook_signature! }.not_to raise_error
      expect_failure(c, :unauthorized, "webhook_signature_invalid")
    end

    it "fails when the body was tampered with" do
      c = instance(hex_class, body: "#{WH_BODY}x", headers: { "X-Sig" => hex_hmac(WH_SECRET, WH_BODY) })

      c.verify_webhook_signature!
      expect_failure(c, :unauthorized, "webhook_signature_invalid")
    end

    it "honors digest: :sha1 and :sha512" do
      { sha1: "SHA1", sha512: "SHA512" }.each do |sym, name|
        c = instance(hex_class(digest: sym), headers: { "X-Sig" => hex_hmac(WH_SECRET, WH_BODY, digest: name) })

        c.verify_webhook_signature!
        expect(c.webhook_verified?).to be(true), "expected #{sym} to verify"
      end
    end

    it "verifies a nil raw body as the empty string" do
      c = instance(hex_class, body: nil, headers: { "X-Sig" => hex_hmac(WH_SECRET, "") })

      c.verify_webhook_signature!
      expect(c.webhook_verified?).to be(true)
    end
  end

  describe ":base64 / :github / :shopify schemes" do
    it ":base64 passes with strict Base64 and rejects the hex encoding of the same HMAC" do
      klass = verifiable_class { verify_webhook :receive, secret: WH_SECRET, scheme: :base64, header: "X-Sig" }

      good = instance(klass, headers: { "X-Sig" => shopify_sig(WH_SECRET, WH_BODY) })
      good.verify_webhook_signature!
      expect(good.webhook_verified?).to be(true)

      bad = instance(klass, headers: { "X-Sig" => hex_hmac(WH_SECRET, WH_BODY) })
      bad.verify_webhook_signature!
      expect_failure(bad, :unauthorized, "webhook_signature_invalid")
    end

    it ":github passes 'sha256=<hex>' read from X-Hub-Signature-256" do
      klass = verifiable_class { verify_webhook :receive, secret: WH_SECRET, scheme: :github }
      c = instance(klass, headers: { "X-Hub-Signature-256" => github_sig(WH_SECRET, WH_BODY) })

      c.verify_webhook_signature!
      expect(c.webhook_verified?).to be(true)
    end

    it ":github rejects the bare hex digest without the 'sha256=' prefix" do
      klass = verifiable_class { verify_webhook :receive, secret: WH_SECRET, scheme: :github }
      c = instance(klass, headers: { "X-Hub-Signature-256" => hex_hmac(WH_SECRET, WH_BODY) })

      c.verify_webhook_signature!
      expect_failure(c, :unauthorized, "webhook_signature_invalid")
    end

    it ":github rejects a 'sha1=...' value (wrong scheme prefix)" do
      klass = verifiable_class { verify_webhook :receive, secret: WH_SECRET, scheme: :github }
      c = instance(klass, headers: { "X-Hub-Signature-256" => "sha1=#{hex_hmac(WH_SECRET, WH_BODY, digest: 'SHA1')}" })

      c.verify_webhook_signature!
      expect_failure(c, :unauthorized, "webhook_signature_invalid")
    end

    it "header: overrides a preset's default header" do
      klass = verifiable_class { verify_webhook :receive, secret: WH_SECRET, scheme: :github, header: "X-Custom-Sig" }
      c = instance(klass, headers: { "X-Custom-Sig" => github_sig(WH_SECRET, WH_BODY) })

      c.verify_webhook_signature!
      expect(c.webhook_verified?).to be(true)
    end

    it ":shopify passes strict Base64 in X-Shopify-Hmac-Sha256" do
      klass = verifiable_class { verify_webhook :receive, secret: WH_SECRET, scheme: :shopify }
      c = instance(klass, headers: { "X-Shopify-Hmac-Sha256" => shopify_sig(WH_SECRET, WH_BODY) })

      c.verify_webhook_signature!
      expect(c.webhook_verified?).to be(true)
    end
  end

  describe "secret resolution" do
    it "instance_execs a callable secret per request (multi-tenant via params)" do
      klass = verifiable_class do
        verify_webhook :receive, secret: -> { params[:tenant_secret] }, scheme: :hex, header: "X-Sig"
      end
      c = instance(klass, params: { tenant_secret: "tenant-1-secret" },
                          headers: { "X-Sig" => hex_hmac("tenant-1-secret", WH_BODY) })

      c.verify_webhook_signature!
      expect(c.webhook_verified?).to be(true)
    end

    it "accepts an Array of secrets — any match passes (rotation)" do
      klass = verifiable_class { verify_webhook :receive, secret: %w[new-secret old-secret], scheme: :hex, header: "X-Sig" }

      %w[new-secret old-secret].each do |secret|
        c = instance(klass, headers: { "X-Sig" => hex_hmac(secret, WH_BODY) })
        c.verify_webhook_signature!
        expect(c.webhook_verified?).to be(true), "expected #{secret} to verify"
      end
    end

    it "accepts a callable returning an Array" do
      klass = verifiable_class do
        verify_webhook :receive, secret: -> { %w[new-secret old-secret] }, scheme: :hex, header: "X-Sig"
      end
      c = instance(klass, headers: { "X-Sig" => hex_hmac("old-secret", WH_BODY) })

      c.verify_webhook_signature!
      expect(c.webhook_verified?).to be(true)
    end

    it "raises ArgumentError when the secret resolves to nil at request time" do
      klass = verifiable_class { verify_webhook :receive, secret: -> {}, scheme: :hex, header: "X-Sig" }
      c = instance(klass, headers: { "X-Sig" => "anything" })

      expect { c.verify_webhook_signature! }.to raise_error(ArgumentError, /secret resolved blank/)
    end

    # valid_webhook_secret? accepts anything with #call, but the secret was
    # instance_exec'd — a TypeError (a 500 any sender could trigger) for a
    # non-Proc callable.
    it "resolves a callable object secret, handing it the controller" do
      tenant_secrets = Class.new { def call(controller) = "secret-#{controller.params[:tenant]}" }.new
      klass = verifiable_class { verify_webhook :receive, secret: tenant_secrets, scheme: :hex, header: "X-Sig" }
      c = instance(klass, headers: { "X-Sig" => hex_hmac("secret-acme", WH_BODY) }, params: { tenant: "acme" })

      c.verify_webhook_signature!
      expect(c.webhook_verified?).to be(true)
    end

    it "resolves a zero-argument callable (a Method) and callables inside a rotation Array" do
      vault = Class.new { def self.current = "new-secret" }
      old = Class.new { def call(_controller) = "old-secret" }.new
      klass = verifiable_class { verify_webhook :receive, secret: [vault.method(:current), old], scheme: :hex, header: "X-Sig" }

      %w[new-secret old-secret].each do |secret|
        c = instance(klass, headers: { "X-Sig" => hex_hmac(secret, WH_BODY) })
        c.verify_webhook_signature!
        expect(c.webhook_verified?).to be(true), "expected #{secret} to verify"
      end
    end

    it "verifies a callable object secret end to end through a real controller" do
      secret = Class.new { def call(*) = "s3cr3t" }.new
      klass = IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::WebhookVerifiable

        verify_webhook :receive, secret: secret, scheme: :hex, header: "X-Sig"
        def receive = head(:ok)
      end
      env = Rack::MockRequest.env_for("/", method: "POST", input: WH_BODY, "HTTP_X_SIG" => hex_hmac("s3cr3t", WH_BODY))

      expect(klass.action(:receive).call(env).first).to eq(200)
    end

    it "raises ArgumentError when the secret resolves to an empty string" do
      klass = verifiable_class { verify_webhook :receive, secret: -> { "" }, scheme: :hex, header: "X-Sig" }
      c = instance(klass, headers: { "X-Sig" => "anything" })

      expect { c.verify_webhook_signature! }.to raise_error(ArgumentError, /secret resolved blank/)
    end
  end

  describe ":stripe scheme" do
    around { |example| travel_to(Time.utc(2026, 1, 1, 12, 0, 0)) { example.run } }

    def stripe_class(tolerance: nil)
      verifiable_class { verify_webhook :receive, secret: WH_SECRET, scheme: :stripe, tolerance: tolerance }
    end

    def now_i = Time.now.to_i

    it "passes a freshly signed header within the default tolerance" do
      c = instance(stripe_class, headers: { "Stripe-Signature" => stripe_header(WH_SECRET, WH_BODY, at: now_i) })

      c.verify_webhook_signature!
      expect(c.rendered).to be_nil
      expect(c.webhook_verified?).to be(true)
    end

    it "renders 401 webhook_signature_invalid for a wrong v1" do
      c = instance(stripe_class, headers: { "Stripe-Signature" => "t=#{now_i},v1=#{'0' * 64}" })

      c.verify_webhook_signature!
      expect_failure(c, :unauthorized, "webhook_signature_invalid")
    end

    it "passes when any one of multiple v1 values matches (key roll)" do
      header = "t=#{now_i},v1=#{'0' * 64},v1=#{stripe_sig(WH_SECRET, WH_BODY, at: now_i)}"
      c = instance(stripe_class, headers: { "Stripe-Signature" => header })

      c.verify_webhook_signature!
      expect(c.webhook_verified?).to be(true)
    end

    it "ignores unknown keys (v0=, junk) and verifies via v1" do
      header = "t=#{now_i},v0=ignored,junk,v1=#{stripe_sig(WH_SECRET, WH_BODY, at: now_i)}"
      c = instance(stripe_class, headers: { "Stripe-Signature" => header })

      c.verify_webhook_signature!
      expect(c.webhook_verified?).to be(true)
    end

    it "renders 401 webhook_timestamp_stale for a t older than the tolerance" do
      stale = now_i - 301
      c = instance(stripe_class, headers: { "Stripe-Signature" => stripe_header(WH_SECRET, WH_BODY, at: stale) })

      c.verify_webhook_signature!
      expect_failure(c, :unauthorized, "webhook_timestamp_stale")
    end

    it "renders 401 webhook_timestamp_stale for a t in the future beyond the tolerance" do
      future = now_i + 301
      c = instance(stripe_class, headers: { "Stripe-Signature" => stripe_header(WH_SECRET, WH_BODY, at: future) })

      c.verify_webhook_signature!
      expect_failure(c, :unauthorized, "webhook_timestamp_stale")
    end

    it "honors a custom tolerance" do
      two_minutes_old = now_i - 120

      lenient = instance(stripe_class(tolerance: 5.minutes),
                         headers: { "Stripe-Signature" => stripe_header(WH_SECRET, WH_BODY, at: two_minutes_old) })
      lenient.verify_webhook_signature!
      expect(lenient.webhook_verified?).to be(true)

      strict = instance(stripe_class(tolerance: 1.minute),
                        headers: { "Stripe-Signature" => stripe_header(WH_SECRET, WH_BODY, at: two_minutes_old) })
      strict.verify_webhook_signature!
      expect_failure(strict, :unauthorized, "webhook_timestamp_stale")
    end

    it "rejects a v1 computed over the bare body instead of 't.body'" do
      c = instance(stripe_class, headers: { "Stripe-Signature" => "t=#{now_i},v1=#{hex_hmac(WH_SECRET, WH_BODY)}" })

      c.verify_webhook_signature!
      expect_failure(c, :unauthorized, "webhook_signature_invalid")
    end

    it "renders 400 webhook_signature_malformed when t is missing" do
      c = instance(stripe_class, headers: { "Stripe-Signature" => "v1=#{stripe_sig(WH_SECRET, WH_BODY, at: now_i)}" })

      c.verify_webhook_signature!
      expect_failure(c, :bad_request, "webhook_signature_malformed")
    end

    it "renders 400 webhook_signature_malformed for non-numeric and negative t" do
      ["t=abc,v1=#{'0' * 64}", "t=-5,v1=#{'0' * 64}", "t=1.5,v1=#{'0' * 64}"].each do |header|
        c = instance(stripe_class, headers: { "Stripe-Signature" => header })

        c.verify_webhook_signature!
        expect_failure(c, :bad_request, "webhook_signature_malformed")
      end
    end

    it "renders 400 webhook_signature_malformed when no v1 is present" do
      c = instance(stripe_class, headers: { "Stripe-Signature" => "t=#{now_i},v0=#{'0' * 64}" })

      c.verify_webhook_signature!
      expect_failure(c, :bad_request, "webhook_signature_malformed")
    end

    it "renders 400 webhook_signature_malformed for a garbage header" do
      c = instance(stripe_class, headers: { "Stripe-Signature" => "lolwut" })

      c.verify_webhook_signature!
      expect_failure(c, :bad_request, "webhook_signature_malformed")
    end

    it "uses the first t for both checks: appending a fresh t cannot resurrect a stale header" do
      stale = now_i - 3600
      replayed = "#{stripe_header(WH_SECRET, WH_BODY, at: stale)},t=#{now_i}"
      c = instance(stripe_class, headers: { "Stripe-Signature" => replayed })

      c.verify_webhook_signature!
      expect_failure(c, :unauthorized, "webhook_timestamp_stale")
    end

    it "ignores v1 values past the signature cap" do
      junk = Array.new(16) { "v1=#{'0' * 64}" }.join(",")
      header = "t=#{now_i},#{junk},v1=#{stripe_sig(WH_SECRET, WH_BODY, at: now_i)}"
      c = instance(stripe_class, headers: { "Stripe-Signature" => header })

      c.verify_webhook_signature!
      expect_failure(c, :unauthorized, "webhook_signature_invalid")
    end

    it "verifies an empty raw body (payload 't.')" do
      c = instance(stripe_class, body: "", headers: { "Stripe-Signature" => stripe_header(WH_SECRET, "", at: now_i) })

      c.verify_webhook_signature!
      expect(c.webhook_verified?).to be(true)
    end
  end

  describe "failure rendering" do
    it "uses the inline error envelope with the right status" do
      klass = verifiable_class { verify_webhook :receive, secret: WH_SECRET, scheme: :hex, header: "X-Sig" }
      c = instance(klass)

      c.verify_webhook_signature!
      expect(c.rendered[:status]).to eq(:unauthorized)
      expect(c.rendered[:json]).to eq(success: false,
                                      error: { message: "X-Sig header is missing.", code: "webhook_signature_missing" })
    end

    it "delegates to render_error when Respondable-style helper is present" do
      klass = verifiable_class { verify_webhook :receive, secret: WH_SECRET, scheme: :hex, header: "X-Sig" }
      c = instance(klass)
      captured = nil
      c.define_singleton_method(:render_error) do |message:, status:, code:|
        captured = { message: message, status: status, code: code }
      end

      c.verify_webhook_signature!
      expect(captured[:status]).to eq(:unauthorized)
      expect(captured[:code]).to eq("webhook_signature_missing")
      expect(c.rendered).to be_nil
    end

    it "webhook_verification_failed is overridable for custom rendering" do
      klass = verifiable_class do
        verify_webhook :receive, secret: WH_SECRET, scheme: :hex, header: "X-Sig"

        def webhook_verification_failed(code:, **)
          render json: { custom: code }, status: :forbidden
        end
      end
      c = instance(klass)

      c.verify_webhook_signature!
      expect(c.rendered[:status]).to eq(:forbidden)
      expect(c.rendered[:json]).to eq(custom: "webhook_signature_missing")
    end

    it "verifies two providers on one controller, each by its own rule" do
      klass = verifiable_class do
        verify_webhook :github_hook, secret: "gh-secret", scheme: :github
        verify_webhook :shopify_hook, secret: "shop-secret", scheme: :shopify
      end

      gh = instance(klass, action: "github_hook", headers: { "X-Hub-Signature-256" => github_sig("gh-secret", WH_BODY) })
      gh.verify_webhook_signature!
      expect(gh.webhook_verified?).to be(true)

      shop = instance(klass, action: "shopify_hook",
                             headers: { "X-Shopify-Hmac-Sha256" => shopify_sig("shop-secret", WH_BODY) })
      shop.verify_webhook_signature!
      expect(shop.webhook_verified?).to be(true)

      cross = instance(klass, action: "github_hook", headers: { "X-Hub-Signature-256" => github_sig("shop-secret", WH_BODY) })
      cross.verify_webhook_signature!
      expect_failure(cross, :unauthorized, "webhook_signature_invalid")
    end
  end

  describe ".verify_webhook argument validation" do
    def declare(&block)
      expect { verifiable_class(&block) }
    end

    it "rejects an unknown scheme" do
      declare { verify_webhook :a, secret: "s", scheme: :nope }
        .to raise_error(ArgumentError, /unknown scheme :nope/)
    end

    it "rejects :hex and :base64 without a header" do
      %i[hex base64].each do |scheme|
        declare { verify_webhook :a, secret: "s", scheme: scheme }
          .to raise_error(ArgumentError, /requires an explicit :header/), "expected :#{scheme} to require a header"
      end
    end

    it "rejects a blank header" do
      declare { verify_webhook :a, secret: "s", scheme: :github, header: "  " }
        .to raise_error(ArgumentError, /:header must be a non-blank String/)
    end

    it "rejects invalid secrets at declaration time" do
      [nil, "", "   ", 123, [], ["ok", ""]].each do |bad|
        declare { verify_webhook :a, secret: bad, scheme: :hex, header: "X-Sig" }
          .to raise_error(ArgumentError, /:secret must be/), "expected rejection for #{bad.inspect}"
      end
    end

    it "rejects :tolerance with a non-stripe scheme" do
      declare { verify_webhook :a, secret: "s", scheme: :github, tolerance: 60 }
        .to raise_error(ArgumentError, /:tolerance only applies to scheme :stripe/)
    end

    it "rejects a non-positive tolerance" do
      declare { verify_webhook :a, secret: "s", scheme: :stripe, tolerance: 0 }
        .to raise_error(ArgumentError, /:tolerance must be a positive duration/)
    end

    it "rejects an unsupported digest" do
      declare { verify_webhook :a, secret: "s", scheme: :hex, header: "X-Sig", digest: :md5 }
        .to raise_error(ArgumentError, /unsupported digest :md5/)
    end

    it "rejects a non-sha256 digest with a provider preset scheme" do
      declare { verify_webhook :a, secret: "s", scheme: :github, digest: :sha1 }
        .to raise_error(ArgumentError, /pins SHA256/)
    end
  end

  describe "replay protection (replay: / replay_ttl:)" do
    class FakeReplayStore
      attr_reader :data, :writes

      def initialize
        @data = {}
        @writes = []
      end

      # nil (not false) on a lost unless_exist race — the same falsey contract
      # Rails.cache#write exposes, minus RuboCop calling a writer a predicate.
      def write(key, value, options = {})
        return nil if options[:unless_exist] && @data.key?(key)

        @writes << [key, value, options]
        @data[key] = value
        true
      end

      def read(key)
        @data[key]
      end

      # Returns the removed value (nil when absent), like Hash#delete —
      # WebhookVerifiable ignores the return value of delete.
      def delete(key)
        @data.delete(key)
      end
    end

    # Every write fails the way Rails' Redis/memcached stores fail when the
    # server is unreachable: falsy return, nothing stored, no exception.
    class UnreachableReplayStore
      def write(_key, _value, _options = {})
        nil
      end

      def read(_key)
        nil
      end

      def delete(_key)
        nil
      end
    end

    let(:store) { FakeReplayStore.new }

    after { ConcernsOnRails.config.cache_store = nil }

    def replay_class(replay: store, **extra)
      s = replay
      verifiable_class { verify_webhook :receive, secret: WH_SECRET, scheme: :hex, header: "X-Sig", replay: s, **extra }
    end

    it "accepts the first delivery and rejects an identical second one with 409 webhook_replayed" do
      klass = replay_class
      headers = { "X-Sig" => hex_hmac(WH_SECRET, WH_BODY) }

      first = instance(klass, headers: headers)
      first.verify_webhook_signature!
      expect(first.rendered).to be_nil
      expect(first.webhook_verified?).to be(true)

      second = instance(klass, headers: headers)
      second.verify_webhook_signature!
      expect_failure(second, :conflict, "webhook_replayed")
    end

    it "lets a different delivery (different body, different signature) through" do
      klass = replay_class
      instance(klass, headers: { "X-Sig" => hex_hmac(WH_SECRET, WH_BODY) }).verify_webhook_signature!
      other_body = '{"event":"order.refunded","id":43}'
      c = instance(klass, headers: { "X-Sig" => hex_hmac(WH_SECRET, other_body) }, body: other_body)
      c.verify_webhook_signature!
      expect(c.rendered).to be_nil
      expect(c.webhook_verified?).to be(true)
    end

    it "lets the provider retry when the handler failed, instead of burning the delivery" do
      klass = replay_class
      headers = { "X-Sig" => hex_hmac(WH_SECRET, WH_BODY) }

      # The handler 500s, so the delivery was never processed. Every retry of
      # the same body carries the same signature, so a claim held for the full
      # replay_ttl would lose the delivery permanently.
      failed = instance(klass, headers: headers)
      failed.verify_webhook_signature!
      failed.response.status = 500
      failed.send(:commit_webhook_replay_claim)

      retried = instance(klass, headers: headers)
      retried.verify_webhook_signature!
      expect(retried.rendered).to be_nil
      expect(retried.webhook_verified?).to be(true)

      # And once a delivery really is handled, the duplicate is still rejected.
      retried.send(:commit_webhook_replay_claim)
      duplicate = instance(klass, headers: headers)
      duplicate.verify_webhook_signature!
      expect_failure(duplicate, :conflict, "webhook_replayed")
    end

    it "accepts deliveries while the store is unreachable instead of rejecting every one" do
      klass = replay_class(replay: UnreachableReplayStore.new)
      c = instance(klass, headers: { "X-Sig" => hex_hmac(WH_SECRET, WH_BODY) })
      c.verify_webhook_signature!
      expect(c.rendered).to be_nil
      expect(c.webhook_verified?).to be(true)
    end

    it "records the key only after the signature verified — a forged delivery consumes nothing" do
      klass = replay_class
      forged = instance(klass, headers: { "X-Sig" => "deadbeef" })
      forged.verify_webhook_signature!
      expect_failure(forged, :unauthorized, "webhook_signature_invalid")
      expect(store.writes).to be_empty
    end

    it "writes the digest of the signature header with unless_exist and the ttl (default 24 hours)" do
      klass = replay_class
      instance(klass, headers: { "X-Sig" => hex_hmac(WH_SECRET, WH_BODY) }).verify_webhook_signature!
      key, _value, options = store.writes.first
      expect(key).to match(/\Awebhook_replay:.+#receive:[0-9a-f]{64}\z/)
      expect(key).not_to include(hex_hmac(WH_SECRET, WH_BODY))
      expect(options).to eq(expires_in: 60, unless_exist: true)

      fresh_store = FakeReplayStore.new
      short = replay_class(replay: fresh_store, replay_ttl: 10.minutes)
      c = instance(short, headers: { "X-Sig" => hex_hmac(WH_SECRET, WH_BODY) })
      c.verify_webhook_signature!
      expect(fresh_store.writes.last[2][:expires_in]).to eq(60) # the claim
      c.send(:commit_webhook_replay_claim)
      expect(fresh_store.writes.last[2][:expires_in]).to eq(600) # the real ttl
    end

    it "scopes the replay key per controller action" do
      klass = verifiable_class do
        verify_webhook :receive, :backup, secret: WH_SECRET, scheme: :hex, header: "X-Sig", replay: FakeReplayStore.new
      end
      headers = { "X-Sig" => hex_hmac(WH_SECRET, WH_BODY) }
      instance(klass, action: "receive", headers: headers).verify_webhook_signature!
      other = instance(klass, action: "backup", headers: headers)
      other.verify_webhook_signature!
      expect(other.rendered).to be_nil
    end

    it "replay: true uses the gem-wide cache_store, and raises the setup hint when none is configured" do
      klass = replay_class(replay: true)
      headers = { "X-Sig" => hex_hmac(WH_SECRET, WH_BODY) }
      expect { instance(klass, headers: headers).verify_webhook_signature! }
        .to raise_error(ArgumentError, /no store configured.*replay:/)

      ConcernsOnRails.setup { |c| c.cache_store = store }
      instance(klass, headers: headers).verify_webhook_signature!
      second = instance(klass, headers: headers)
      second.verify_webhook_signature!
      expect_failure(second, :conflict, "webhook_replayed")
    end

    it "protects Stripe deliveries too (same header replayed within tolerance)" do
      now = Time.now.to_i
      klass = verifiable_class { verify_webhook :receive, secret: WH_SECRET, scheme: :stripe, replay: FakeReplayStore.new }
      headers = { "Stripe-Signature" => stripe_header(WH_SECRET, WH_BODY, at: now) }
      instance(klass, headers: headers).verify_webhook_signature!
      second = instance(klass, headers: headers)
      second.verify_webhook_signature!
      expect_failure(second, :conflict, "webhook_replayed")
    end

    # The Stripe header is parsed, not compared: unknown keys and whitespace
    # around the commas are ignored, so a captured header can be mutated into
    # unlimited distinct-but-still-valid strings. Keying off the raw header let
    # every one of them through, which is no replay protection at all.
    it "keys Stripe off the signed payload, so a padded or re-spaced header is still a replay" do
      now = Time.now.to_i
      klass = verifiable_class { verify_webhook :receive, secret: WH_SECRET, scheme: :stripe, replay: FakeReplayStore.new }
      canonical = stripe_header(WH_SECRET, WH_BODY, at: now)
      instance(klass, headers: { "Stripe-Signature" => canonical }).verify_webhook_signature!

      ["#{canonical},v0=deadbeef", canonical.sub(",", ", ")].each do |mutated|
        c = instance(klass, headers: { "Stripe-Signature" => mutated })
        c.verify_webhook_signature!
        expect_failure(c, :conflict, "webhook_replayed")
      end
    end

    it "validates the options at class load" do
      expect { replay_class(replay: nil, replay_ttl: 1.hour) }.to raise_error(ArgumentError, /:replay_ttl requires :replay/)
      expect { replay_class(replay: "nope") }.to raise_error(ArgumentError, /:replay must be true or a store responding to #write/)
      expect { replay_class(replay_ttl: 0) }.to raise_error(ArgumentError, /:replay_ttl must be a positive duration/)
    end

    # A store that writes but cannot be read back silently disables the whole
    # feature: a falsy unless_exist write is indistinguishable from a store
    # outage, so without #read every delivery is waved through.
    it "rejects a write-only store instead of silently providing no protection" do
      write_only = Class.new do
        # Never actually reached — both paths reject the store first. 1 rather
        # than true so RuboCop doesn't read a writer as a predicate.
        def write(_key, _value, _options = {})
          1
        end
      end
      expect { replay_class(replay: write_only.new) }
        .to raise_error(ArgumentError, /:replay must be true or a store responding to #write and #read/)

      ConcernsOnRails.setup { |c| c.cache_store = write_only.new }
      klass = replay_class(replay: true)
      expect { instance(klass, headers: { "X-Sig" => hex_hmac(WH_SECRET, WH_BODY) }).verify_webhook_signature! }
        .to raise_error(ArgumentError, /does not respond to #read/)
    end

    # `replay: Rails.env.production?` must not blow up the class body in
    # development — false is "off", not a malformed store.
    it "treats replay: false as off" do
      klass = replay_class(replay: false)
      expect(klass.webhook_rules.first[:replay]).to be_nil
      expect(klass.webhook_rules.first[:replay_ttl]).to be_nil
      headers = { "X-Sig" => hex_hmac(WH_SECRET, WH_BODY) }
      instance(klass, headers: headers).verify_webhook_signature!
      second = instance(klass, headers: headers)
      second.verify_webhook_signature!
      expect(second.rendered).to be_nil
      expect(second.webhook_verified?).to be(true)

      expect { replay_class(replay: false, replay_ttl: 1.hour) }
        .to raise_error(ArgumentError, /:replay_ttl requires :replay/)
    end

    it "exposes the replay settings on the rule" do
      rule = replay_class(replay_ttl: 1.hour).webhook_rules.first
      expect(rule[:replay]).to equal(store)
      expect(rule[:replay_ttl]).to eq(3600)
      plain = verifiable_class { verify_webhook :receive, secret: WH_SECRET, scheme: :hex, header: "X" }
      expect(plain.webhook_rules.first[:replay]).to be_nil
    end
  end

  describe "#webhook_verification_failed" do
    # The Authorizable precedent (1.22): a gate that cannot render its own
    # rejection must raise, never return nil — returning let the action run on
    # an unverified payload. See authorizable_spec.rb "fails CLOSED".
    it "fails CLOSED when there is no response object" do
      klass = verifiable_class { verify_webhook :receive, secret: WH_SECRET, scheme: :github }
      c = instance(klass, headers: { "X-Hub-Signature-256" => github_sig("wrong", WH_BODY) })
      c.response = nil

      expect { c.verify_webhook_signature! }.to raise_error(/refusing to fail open/)
      expect(c.webhook_verified?).to be false
    end

    it "fails CLOSED when the signature header is missing and there is no response object" do
      klass = verifiable_class { verify_webhook :receive, secret: WH_SECRET, scheme: :github }
      c = instance(klass)
      c.response = nil

      expect { c.verify_webhook_signature! }.to raise_error(/refusing to fail open/)
    end

    it "still renders when there is no response but a render_error override exists" do
      klass = verifiable_class do
        verify_webhook :receive, secret: WH_SECRET, scheme: :github

        def render_error(message:, status:, code: nil, **)
          @rendered = { message: message, status: status, code: code }
        end
      end
      c = instance(klass, headers: { "X-Hub-Signature-256" => github_sig("wrong", WH_BODY) })
      c.response = nil

      expect { c.verify_webhook_signature! }.not_to raise_error
      expect(c.instance_variable_get(:@rendered)).to include(code: "webhook_signature_invalid")
    end
  end

  describe "an unresolvable action name" do
    it "does not skip verification when rules are declared" do
      klass = verifiable_class { verify_webhook :receive, secret: WH_SECRET, scheme: :github }
      c = klass.new(params: {})
      req = WebhookFakeRequest.new({}, WH_BODY)
      c.define_singleton_method(:request) { req }
      # No action_name at all — previously webhook_rule_for_action returned nil
      # and every webhook was accepted without a signature check.
      c.verify_webhook_signature!

      expect(c.webhook_verified?).to be false
      expect_failure(c, :unauthorized, "webhook_signature_missing")
    end

    it "does not skip verification when action_name is blank" do
      klass = verifiable_class { verify_webhook :receive, secret: WH_SECRET, scheme: :github }
      c = instance(klass, action: "")

      c.verify_webhook_signature!

      expect(c.webhook_verified?).to be false
      expect_failure(c, :unauthorized, "webhook_signature_missing")
    end

    # With several per-provider rules and no catch-all there is no honest way
    # to pick one: verifying a GitHub delivery against Stripe's secret rejects
    # a perfectly valid payload with "signature invalid", sending the provider
    # chasing a signing bug that does not exist. Still fails closed — the
    # action does not run — but says what actually went wrong.
    it "raises rather than verifying against an arbitrary provider's secret" do
      klass = verifiable_class do
        verify_webhook :stripe_hook, secret: WH_SECRET, scheme: :stripe
        verify_webhook :github_hook, secret: "other-secret", scheme: :github
      end
      c = instance(klass, action: "")

      expect { c.verify_webhook_signature! }
        .to raise_error(/cannot tell which action/)
    end

    it "uses the catch-all rule when one is declared" do
      klass = verifiable_class do
        verify_webhook :github_hook, secret: "other-secret", scheme: :github
        verify_webhook secret: WH_SECRET, scheme: :github
      end
      c = instance(klass, action: "")

      c.verify_webhook_signature!

      expect(c.webhook_verified?).to be false
      expect_failure(c, :unauthorized, "webhook_signature_missing")
    end

    it "still verifies normally when the action IS resolvable and uncovered" do
      klass = verifiable_class { verify_webhook :receive, secret: WH_SECRET, scheme: :github }
      c = instance(klass, action: "index")

      expect(c.verify_webhook_signature!).to be_nil
      expect(c.rendered).to be_nil
    end
  end

  # Through the REAL callback chain: Rails skips after_action callbacks when a
  # later before_action halts, or when the action raises. The replay claim was
  # written in the before_action and only ever promoted/released in the
  # after_action, so in both cases it sat there for REPLAY_CLAIM_TTL and the
  # provider's retry of a delivery that was never processed got a 409.
  describe "replay claim through real ActionController dispatch" do
    class WebhookBoomError < StandardError
    end

    let(:store) do
      Class.new do
        attr_reader :data

        def initialize
          @data = {}
        end

        def write(key, value, options = {})
          return nil if options[:unless_exist] && @data.key?(key)

          @data[key] = value
          true
        end

        def read(key)
          @data[key]
        end

        def delete(key)
          @data.delete(key)
        end
      end.new
    end

    let(:controller) do
      replay_store = store
      IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::WebhookVerifiable

        verify_webhook :receive, secret: WH_SECRET, scheme: :hex, header: "X-Sig", replay: replay_store
        # A LATER filter (declared after the include) that can halt — an app's
        # maintenance switch, a feature flag, a tenant check.
        before_action { head :service_unavailable if request.headers["X-Halt"] }

        rescue_from(WebhookBoomError) { render json: { error: "handled" }, status: :unprocessable_entity }

        def receive
          raise WebhookBoomError if request.headers["X-Boom"]

          render json: { ok: true }
        end
      end
    end

    def deliver(extra_headers = {})
      headers = { "X-Sig" => hex_hmac(WH_SECRET, "id=1") }.merge(extra_headers)
      IntegrationHarness.dispatch(controller, :receive, method: "POST", params: { id: "1" }, headers: headers)
    end

    it "releases the claim when a later before_action halts, so the provider's retry is processed" do
      expect(deliver("X-Halt" => "1").status).to eq(503)
      expect(store.data).to be_empty

      expect(deliver.status).to eq(200)
      expect(deliver.status).to eq(409) # processed now, so a real duplicate is still a replay
    end

    it "releases the claim when the action raises, even when rescue_from renders a non-5xx" do
      expect(deliver("X-Boom" => "1").status).to eq(422)
      expect(store.data).to be_empty

      expect(deliver.status).to eq(200)
    end

    it "promotes the claim to replay_ttl after a completed action, exactly as before" do
      expect(deliver.status).to eq(200)
      expect(store.data.size).to eq(1)
      expect(deliver.status).to eq(409)
    end

    it "keeps the replay callbacks out of action_methods" do
      expect(controller.action_methods).to include("receive")
      expect(controller.action_methods).not_to include("guard_webhook_replay_claim", "commit_webhook_replay_claim")
    end

    context "when the store's #delete raises" do
      let(:store) do
        Class.new do
          attr_reader :data

          def initialize
            @data = {}
          end

          def write(key, value, options = {})
            return nil if options[:unless_exist] && @data.key?(key)

            @data[key] = value
            true
          end

          def read(key)
            @data[key]
          end

          def delete(_key)
            raise IOError, "store went away"
          end
        end.new
      end

      it "does not turn a later filter's halt into a 500" do
        expect(deliver("X-Halt" => "1").status).to eq(503)
      end

      it "never masks the action's own exception" do
        expect(deliver("X-Boom" => "1").status).to eq(422) # still rescued as WebhookBoomError
      end

      it "logs the failed release" do
        output = StringIO.new
        controller.logger = Logger.new(output)
        deliver("X-Halt" => "1")
        expect(output.string).to match(/could not release.*IOError: store went away/)
      end
    end
  end
end
