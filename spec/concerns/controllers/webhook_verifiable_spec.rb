# frozen_string_literal: true

require "spec_helper"
require "openssl"

describe ConcernsOnRails::Controllers::WebhookVerifiable do
  WebhookFakeRequest = Struct.new(:headers, :raw_post) unless defined?(WebhookFakeRequest)

  WH_SECRET = "whsec_test"
  WH_BODY = '{"event":"order.paid","id":42}'

  let(:base_class) do
    Class.new(FakeController) do
      def self.before_action(*); end
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

  def stripe_sig(secret, body, t:)
    hex_hmac(secret, "#{t}.#{body}")
  end

  def stripe_header(secret, body, t:)
    "t=#{t},v1=#{stripe_sig(secret, body, t: t)}"
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
      c = instance(hex_class, body: WH_BODY + "x", headers: { "X-Sig" => hex_hmac(WH_SECRET, WH_BODY) })

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
      c = instance(stripe_class, headers: { "Stripe-Signature" => stripe_header(WH_SECRET, WH_BODY, t: now_i) })

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
      header = "t=#{now_i},v1=#{'0' * 64},v1=#{stripe_sig(WH_SECRET, WH_BODY, t: now_i)}"
      c = instance(stripe_class, headers: { "Stripe-Signature" => header })

      c.verify_webhook_signature!
      expect(c.webhook_verified?).to be(true)
    end

    it "ignores unknown keys (v0=, junk) and verifies via v1" do
      header = "t=#{now_i},v0=ignored,junk,v1=#{stripe_sig(WH_SECRET, WH_BODY, t: now_i)}"
      c = instance(stripe_class, headers: { "Stripe-Signature" => header })

      c.verify_webhook_signature!
      expect(c.webhook_verified?).to be(true)
    end

    it "renders 401 webhook_timestamp_stale for a t older than the tolerance" do
      stale = now_i - 301
      c = instance(stripe_class, headers: { "Stripe-Signature" => stripe_header(WH_SECRET, WH_BODY, t: stale) })

      c.verify_webhook_signature!
      expect_failure(c, :unauthorized, "webhook_timestamp_stale")
    end

    it "renders 401 webhook_timestamp_stale for a t in the future beyond the tolerance" do
      future = now_i + 301
      c = instance(stripe_class, headers: { "Stripe-Signature" => stripe_header(WH_SECRET, WH_BODY, t: future) })

      c.verify_webhook_signature!
      expect_failure(c, :unauthorized, "webhook_timestamp_stale")
    end

    it "honors a custom tolerance" do
      two_minutes_old = now_i - 120

      lenient = instance(stripe_class(tolerance: 5.minutes),
                         headers: { "Stripe-Signature" => stripe_header(WH_SECRET, WH_BODY, t: two_minutes_old) })
      lenient.verify_webhook_signature!
      expect(lenient.webhook_verified?).to be(true)

      strict = instance(stripe_class(tolerance: 1.minute),
                        headers: { "Stripe-Signature" => stripe_header(WH_SECRET, WH_BODY, t: two_minutes_old) })
      strict.verify_webhook_signature!
      expect_failure(strict, :unauthorized, "webhook_timestamp_stale")
    end

    it "rejects a v1 computed over the bare body instead of 't.body'" do
      c = instance(stripe_class, headers: { "Stripe-Signature" => "t=#{now_i},v1=#{hex_hmac(WH_SECRET, WH_BODY)}" })

      c.verify_webhook_signature!
      expect_failure(c, :unauthorized, "webhook_signature_invalid")
    end

    it "renders 400 webhook_signature_malformed when t is missing" do
      c = instance(stripe_class, headers: { "Stripe-Signature" => "v1=#{stripe_sig(WH_SECRET, WH_BODY, t: now_i)}" })

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
      replayed = "#{stripe_header(WH_SECRET, WH_BODY, t: stale)},t=#{now_i}"
      c = instance(stripe_class, headers: { "Stripe-Signature" => replayed })

      c.verify_webhook_signature!
      expect_failure(c, :unauthorized, "webhook_timestamp_stale")
    end

    it "ignores v1 values past the signature cap" do
      junk = Array.new(16) { "v1=#{'0' * 64}" }.join(",")
      header = "t=#{now_i},#{junk},v1=#{stripe_sig(WH_SECRET, WH_BODY, t: now_i)}"
      c = instance(stripe_class, headers: { "Stripe-Signature" => header })

      c.verify_webhook_signature!
      expect_failure(c, :unauthorized, "webhook_signature_invalid")
    end

    it "verifies an empty raw body (payload 't.')" do
      c = instance(stripe_class, body: "", headers: { "Stripe-Signature" => stripe_header(WH_SECRET, "", t: now_i) })

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

        def webhook_verification_failed(message:, status:, code:)
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
end
