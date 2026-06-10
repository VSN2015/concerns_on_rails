require "active_support/concern"
require "active_support/security_utils"
require "openssl"
require "digest"

module ConcernsOnRails
  module Controllers
    # HMAC signature verification for inbound webhooks — the receiving side of
    # Stripe/GitHub/Shopify-style integrations. The action only runs when the
    # signature over the raw request body verifies; otherwise a 401/400 is
    # rendered and the action never executes.
    #
    #   class WebhooksController < ApplicationController
    #     include ConcernsOnRails::Controllers::WebhookVerifiable
    #
    #     verify_webhook :stripe,  secret: -> { ENV["STRIPE_WEBHOOK_SECRET"] },  scheme: :stripe
    #     verify_webhook :github,  secret: -> { ENV["GITHUB_WEBHOOK_SECRET"] },  scheme: :github
    #     verify_webhook :shopify, secret: [NEW_SECRET, OLD_SECRET],             scheme: :shopify
    #     verify_webhook :custom,  secret: "s3cr3t", scheme: :hex, header: "X-Acme-Signature"
    #     # verify_webhook secret: ...    # no actions = catch-all (declare specific rules first)
    #
    #     def stripe; ...; end
    #   end
    #
    # Schemes (header defaults in parentheses):
    #   :github  ("X-Hub-Signature-256")    value "sha256=<hex>"
    #   :shopify ("X-Shopify-Hmac-Sha256")  value strict-Base64 of the binary HMAC
    #   :stripe  ("Stripe-Signature")       value "t=<unix>,v1=<hex>[,v1=...]"; the
    #            signed payload is "#{t}.#{body}"; every v1 is tried (rotation);
    #            `tolerance:` (default 300s, Stripe-only) rejects |now - t| beyond
    #            the window, replayed and far-future headers alike
    #   :hex / :base64                       plain hex / strict-Base64 HMAC of the
    #            body; these have no standard header so `header:` is required;
    #            `digest:` (:sha256 default, :sha1/:sha512) applies to these only
    #
    # secret: a non-blank String, a callable (instance_exec'd per request — use
    # `-> { ENV[...] }` for boot-order safety or read params for multi-tenant
    # secrets), or an Array of those (rotation: any match passes). A secret that
    # resolves blank at request time raises ArgumentError — a misconfigured
    # endpoint must alert the operator, not 401 into the provider's silent
    # retry loop.
    #
    # Failures render through `webhook_verification_failed(message:, status:,
    # code:)` (delegates to Respondable's render_error when present; override
    # it to customize): missing/blank header -> 401 "webhook_signature_missing";
    # mismatch -> 401 "webhook_signature_invalid"; stale/future Stripe
    # timestamp -> 401 "webhook_timestamp_stale"; unparseable Stripe header ->
    # 400 "webhook_signature_malformed". After a pass, `webhook_verified?` is
    # true.
    #
    # IMPORTANT:
    #   * Include/declare this BEFORE Idempotentable (and other around filters
    #     that cache responses) — a 401 that runs inside Idempotentable's
    #     around_action would be cached and replayed for the full ttl.
    #     Verifying before Throttleable also stops forged traffic from burning
    #     legitimate rate budget.
    #   * Webhook endpoints receive third-party POSTs: skip CSRF yourself
    #     (`skip_before_action :verify_authenticity_token`) along with any
    #     session auth filters.
    #   * The signature covers the raw bytes — parse `request.raw_post` in the
    #     action; re-serializing `params` may not round-trip byte-for-byte.
    #     Anything that rewrites the body before the controller breaks
    #     verification.
    #   * In tests, `skip_before_action :verify_webhook_signature!` or sign the
    #     payload for real with OpenSSL::HMAC.
    module WebhookVerifiable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Controllers::WebhookVerifiable".freeze
      SCHEMES = {
        hex: { header: nil, encoding: :hex },
        base64: { header: nil, encoding: :base64 },
        github: { header: "X-Hub-Signature-256", encoding: :hex, prefix: "sha256=" },
        shopify: { header: "X-Shopify-Hmac-Sha256", encoding: :base64 },
        stripe: { header: "Stripe-Signature", encoding: :stripe }
      }.freeze
      # Schemes whose wire format pins the digest — `digest:` cannot override it.
      PINNED_DIGEST_SCHEMES = %i[github shopify stripe].freeze
      SUPPORTED_DIGESTS = { sha256: "SHA256", sha1: "SHA1", sha512: "SHA512" }.freeze
      STRIPE_DEFAULT_TOLERANCE = 300 # seconds; Stripe's recommended window
      # Stripe sends at most two v1 values (during secret rolls); the cap is
      # cheap hygiene against a header stuffed with thousands of candidates.
      MAX_STRIPE_SIGNATURES = 16
      STRIPE_TIMESTAMP_FORMAT = /\A\d+\z/

      included do
        class_attribute :webhook_rules, instance_accessor: false, default: []
        before_action :verify_webhook_signature!
      end

      module ClassMethods
        # Declare signature verification for the given actions (none =
        # catch-all). Each call appends a rule; the FIRST rule matching the
        # current action wins, so declare specific rules before a catch-all.
        def verify_webhook(*actions, secret:, scheme: :hex, header: nil, tolerance: nil, digest: :sha256)
          actions = actions.flatten.map(&:to_s)
          scheme = scheme.to_sym
          digest = digest.to_sym
          validate_verify_webhook!(secret: secret, scheme: scheme, header: header, tolerance: tolerance, digest: digest)

          rule = { actions: actions, secret: secret, scheme: scheme,
                   header: (header || SCHEMES[scheme][:header]).to_s,
                   tolerance: scheme == :stripe ? (tolerance || STRIPE_DEFAULT_TOLERANCE).to_i : nil,
                   digest: digest }
          self.webhook_rules = webhook_rules + [rule]
        end

        private

        def validate_verify_webhook!(secret:, scheme:, header:, tolerance:, digest:)
          unless SCHEMES.key?(scheme)
            raise ArgumentError, "#{LABEL}: unknown scheme :#{scheme} (supported: #{SCHEMES.keys.join(', ')})"
          end
          unless valid_webhook_secret?(secret)
            raise ArgumentError, "#{LABEL}: :secret must be a non-blank String, a callable, or a non-empty Array of those"
          end
          validate_webhook_header!(scheme, header)
          validate_webhook_tolerance!(scheme, tolerance)
          validate_webhook_digest!(scheme, digest)
        end

        def validate_webhook_header!(scheme, header)
          if header.nil?
            return if SCHEMES[scheme][:header]

            # No industry-standard generic header exists; guessing one would
            # silently 401 every request. Fail at declaration time instead.
            raise ArgumentError, "#{LABEL}: scheme :#{scheme} requires an explicit :header"
          end
          raise ArgumentError, "#{LABEL}: :header must be a non-blank String" if header.to_s.strip.empty?
        end

        def validate_webhook_tolerance!(scheme, tolerance)
          return if tolerance.nil?
          raise ArgumentError, "#{LABEL}: :tolerance only applies to scheme :stripe" unless scheme == :stripe
          raise ArgumentError, "#{LABEL}: :tolerance must be a positive duration" unless tolerance.to_i.positive?
        end

        def validate_webhook_digest!(scheme, digest)
          unless SUPPORTED_DIGESTS.key?(digest)
            raise ArgumentError, "#{LABEL}: unsupported digest :#{digest} (supported: #{SUPPORTED_DIGESTS.keys.join(', ')})"
          end
          return unless digest != :sha256 && PINNED_DIGEST_SCHEMES.include?(scheme)

          raise ArgumentError, "#{LABEL}: scheme :#{scheme} pins SHA256 — :digest cannot be overridden"
        end

        def valid_webhook_secret?(value)
          case value
          when Array then value.any? && value.all? { |entry| valid_webhook_secret?(entry) }
          when String then !value.strip.empty?
          else value.respond_to?(:call)
          end
        end
      end

      # before_action entry point. Public and named so apps can
      # `skip_before_action :verify_webhook_signature!` (e.g. in tests).
      def verify_webhook_signature!
        rule = webhook_rule_for_action
        return unless rule

        value = read_webhook_header(rule)
        if value.nil?
          return webhook_verification_failed(message: "#{rule[:header]} header is missing.",
                                             status: :unauthorized, code: "webhook_signature_missing")
        end

        secrets = resolve_webhook_secrets!(rule)
        webhook_render_outcome(rule, webhook_verification_outcome(rule, value, secrets))
      end

      # True once the current request's signature has verified.
      def webhook_verified?
        !!@webhook_verified
      end

      # Single funnel for all failure outcomes (override point). Uses
      # Respondable's render_error when available, otherwise the same inline
      # envelope as Throttleable / Idempotentable.
      def webhook_verification_failed(message:, status:, code:)
        return unless respond_to?(:response) && response

        return render_error(message: message, status: status, code: code) if respond_to?(:render_error)

        render json: { success: false, error: { message: message, code: code } }, status: status
      end

      private

      def webhook_rule_for_action
        action = respond_to?(:action_name) ? action_name.to_s : nil
        return nil unless action

        self.class.webhook_rules.find { |rule| rule[:actions].empty? || rule[:actions].include?(action) }
      end

      def webhook_render_outcome(rule, outcome)
        case outcome
        when :ok
          @webhook_verified = true
          nil
        when :malformed
          webhook_verification_failed(message: "#{rule[:header]} header could not be parsed.",
                                      status: :bad_request, code: "webhook_signature_malformed")
        when :stale
          webhook_verification_failed(message: "#{rule[:header]} timestamp is outside the allowed tolerance.",
                                      status: :unauthorized, code: "webhook_timestamp_stale")
        else
          webhook_verification_failed(message: "#{rule[:header]} signature does not match the request body.",
                                      status: :unauthorized, code: "webhook_signature_invalid")
        end
      end

      def webhook_verification_outcome(rule, value, secrets)
        return verify_stripe_signature(rule, value, secrets) if rule[:scheme] == :stripe

        body = webhook_raw_body
        matched = secrets.any? do |secret|
          webhook_secure_compare(value, compute_webhook_signature(rule, secret, body))
        end
        matched ? :ok : :invalid
      end

      # The expected value is always ENCODED and compared as a string — the
      # attacker-controlled header is never hex/Base64-decoded, so garbage
      # input cannot raise, it just fails the comparison.
      def compute_webhook_signature(rule, secret, payload)
        preset = SCHEMES[rule[:scheme]]
        digest = OpenSSL::Digest.new(SUPPORTED_DIGESTS[rule[:digest]])
        case preset[:encoding]
        when :hex
          "#{preset[:prefix]}#{OpenSSL::HMAC.hexdigest(digest, secret, payload)}"
        when :base64
          # pack("m0") = strict Base64, no trailing newline. Avoids the base64
          # gem, which is no longer a default gem on Ruby 3.4.
          [OpenSSL::HMAC.digest(digest, secret, payload)].pack("m0")
        end
      end

      def verify_stripe_signature(rule, value, secrets)
        parsed = parse_stripe_header(value)
        return :malformed unless parsed

        # Symmetric window: rejects replayed (old t) and pre-dated (future t)
        # headers alike. Time.now so travel_to works in specs.
        return :stale if (Time.now.to_i - parsed[:timestamp]).abs > rule[:tolerance]

        payload = "#{parsed[:timestamp]}.#{webhook_raw_body}"
        expected = secrets.map { |secret| OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new("SHA256"), secret, payload) }
        matched = parsed[:signatures].any? { |sig| expected.any? { |exp| webhook_secure_compare(sig, exp) } }
        matched ? :ok : :invalid
      end

      # "t=<unix>,v1=<hex>[,v1=...]" — unknown keys (v0 etc.) are ignored. The
      # FIRST valid t wins and feeds both the tolerance check and the signed
      # payload, so appending a fresh t to a captured stale header cannot
      # resurrect it (its v1 was computed over the original t).
      def parse_stripe_header(value)
        timestamp = nil
        signatures = []
        value.split(",").each do |pair|
          key, val = pair.split("=", 2)
          key = key.to_s.strip
          val = val.to_s.strip
          if key == "t" && timestamp.nil? && val.match?(STRIPE_TIMESTAMP_FORMAT)
            timestamp = val.to_i
          elsif key == "v1" && !val.empty? && signatures.length < MAX_STRIPE_SIGNATURES
            signatures << val
          end
        end
        return nil unless timestamp && signatures.any?

        { timestamp: timestamp, signatures: signatures }
      end

      def read_webhook_header(rule)
        return nil unless respond_to?(:request) && request.respond_to?(:headers) && request.headers

        # scrub first: an invalid-UTF-8 byte in the attacker-controlled header
        # must fail the comparison, not raise Encoding::CompatibilityError out
        # of strip / regexp matching (a user-triggerable 500).
        value = request.headers[rule[:header]].to_s.scrub.strip
        value.empty? ? nil : value
      end

      def webhook_raw_body
        return "" unless respond_to?(:request) && request.respond_to?(:raw_post)

        request.raw_post.to_s
      end

      # Callables are instance_exec'd per request (multi-tenant secrets can
      # read params); an Array means rotation. Resolving blank is a server
      # misconfiguration — raise loudly rather than 401 every delivery.
      def resolve_webhook_secrets!(rule)
        resolved = Array(rule[:secret]).flat_map do |candidate|
          Array(candidate.respond_to?(:call) ? instance_exec(&candidate) : candidate)
        end
        if resolved.empty? || resolved.any? { |secret| secret.to_s.strip.empty? }
          action = respond_to?(:action_name) ? action_name : "unknown"
          raise ArgumentError, "#{LABEL}: :secret resolved blank for action '#{action}' — " \
                               "verification cannot proceed with an empty secret."
        end
        resolved.map(&:to_s)
      end

      # Constant-time comparison, portable across Rails 5.0-8: both sides are
      # collapsed to fixed-length SHA256 digests first (pre-5.2 secure_compare
      # short-circuited on length mismatch; 5.2+ digests internally — double
      # digesting is harmless).
      def webhook_secure_compare(a, b)
        ActiveSupport::SecurityUtils.secure_compare(::Digest::SHA256.digest(a), ::Digest::SHA256.digest(b))
      end
    end
  end
end
