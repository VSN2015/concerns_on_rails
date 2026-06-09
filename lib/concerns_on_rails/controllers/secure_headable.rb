require "active_support/concern"

module ConcernsOnRails
  module Controllers
    # Adds modern security response headers and wires Rails' native
    # Content-Security-Policy DSL. Defense-in-depth on top of output escaping —
    # this does NOT scrub request params (context-blind and lossy) and never
    # re-enables the deprecated X-XSS-Protection auditor.
    #
    #   class ApplicationController < ActionController::Base
    #     include ConcernsOnRails::Controllers::SecureHeadable
    #
    #     # Apply preset headers, plus any custom "Header-Name" => "value" pairs:
    #     secure_headers :nosniff, :sameorigin_frame, :no_referrer_leak, :disable_legacy_xss
    #     secure_headers "Permissions-Policy" => "geolocation=()"
    #
    #     # Delegates to Rails' native CSP DSL — roll out report-only FIRST:
    #     content_security_policy_for(report_only: true) do |policy|
    #       policy.default_src :self
    #       policy.script_src  :self
    #       policy.object_src  :none
    #     end
    #   end
    #
    # The headers mitigate clickjacking / MIME-sniffing and (via CSP) XSS as
    # defense-in-depth — they are NOT a standalone XSS fix; output escaping
    # remains the primary defense. Per-controller CSP overrides the global
    # initializer for that controller. CSP nonce generation
    # (content_security_policy_nonce_generator / _nonce_directives) is app-wide
    # initializer configuration and intentionally stays out of this concern.
    #
    # Header presets (the `secure_headers` arguments):
    #   :nosniff            — X-Content-Type-Options: nosniff
    #   :sameorigin_frame   — X-Frame-Options: SAMEORIGIN
    #   :deny_frame         — X-Frame-Options: DENY
    #   :no_referrer_leak   — Referrer-Policy: strict-origin-when-cross-origin
    #   :no_cross_domain    — X-Permitted-Cross-Domain-Policies: none
    #   :disable_legacy_xss — X-XSS-Protection: 0 (the only correct modern value)
    module SecureHeadable
      extend ActiveSupport::Concern

      # Frozen, string-only header presets, each "Header-Name" => "value".
      # :disable_legacy_xss emits "0" deliberately — the legacy browser XSS
      # auditor was itself exploitable and is gone from modern browsers
      # (Rails 7+ ships "0"), so "0" is the only correct value.
      PRESETS = {
        nosniff: %w[X-Content-Type-Options nosniff],
        sameorigin_frame: %w[X-Frame-Options SAMEORIGIN],
        deny_frame: %w[X-Frame-Options DENY],
        no_referrer_leak: %w[Referrer-Policy strict-origin-when-cross-origin],
        no_cross_domain: %w[X-Permitted-Cross-Domain-Policies none],
        disable_legacy_xss: %w[X-XSS-Protection 0]
      }.freeze

      included do
        class_attribute :secure_headable_headers, instance_accessor: false, default: {}
        # after_action (not before) so the headers survive render and reinforce
        # Rails' middleware defaults when a name collides.
        after_action :apply_secure_headers
      end

      class_methods do
        # Register preset headers (by symbol) plus optional custom
        # "Header-Name" => "value" pairs. Later declarations win on collision.
        def secure_headers(*presets, **custom)
          resolved = presets.to_h do |key|
            PRESETS.fetch(key) do
              raise ArgumentError,
                    "ConcernsOnRails::Controllers::SecureHeadable: unknown preset '#{key}'. " \
                    "Valid presets: #{PRESETS.keys.join(', ')}"
            end
          end

          self.secure_headable_headers =
            secure_headable_headers.merge(resolved).merge(custom.transform_keys(&:to_s))
        end

        # Thin pass-through to Rails' native CSP DSL — never re-implement CSP.
        # Forwards per-action conditions (only: / except: / if: / unless:) and
        # the policy block straight through.
        def content_security_policy_for(report_only: false, **action_opts, &block)
          unless respond_to?(:content_security_policy)
            raise ArgumentError,
                  "ConcernsOnRails::Controllers::SecureHeadable: CSP requires " \
                  "ActionController::ContentSecurityPolicy (Rails 5.2+)"
          end

          # The policy block is ONLY accepted by content_security_policy; the
          # report-only variant is a flag toggle that takes no block. So always
          # define the policy via content_security_policy, then additionally mark
          # it report-only when requested — otherwise a report-only rollout would
          # silently register no policy at all (the block would be dropped).
          content_security_policy(**action_opts, &block)
          content_security_policy_report_only(true, **action_opts) if report_only
        end
      end

      # Public so subclasses can override; guarded exactly like Paginatable so
      # it no-ops cleanly when there is no response object.
      def apply_secure_headers
        return unless respond_to?(:response) && response

        self.class.secure_headable_headers.each { |name, value| response.set_header(name, value) }
      end
    end
  end
end
