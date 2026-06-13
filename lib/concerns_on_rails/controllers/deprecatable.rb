require "active_support/concern"
require "active_support/notifications"
require "date"
require "time"

module ConcernsOnRails
  module Controllers
    # Standards-based API endpoint deprecation — the receiving end of an API
    # retirement plan (how Stripe / GitHub / Zalando sunset versions). Declare
    # which actions are deprecated and the standard signalling headers go out on
    # every response so clients (and their SDKs) can discover the deprecation,
    # the migration docs, the successor endpoint, and the hard cut-off — then
    # optionally enforce a 410 Gone once that cut-off passes.
    #
    #   class Api::V1::OrdersController < ApplicationController
    #     include ConcernsOnRails::Controllers::Deprecatable
    #
    #     deprecate_actions :index, :show,
    #       deprecated_at: "2026-06-01",
    #       sunset_at:     "2026-12-31T00:00:00Z",
    #       link:          "https://docs.example.com/v1-migration",
    #       successor:     "https://api.example.com/v2/orders",
    #       after_sunset:  :gone,
    #       notify:        -> { StatsD.increment("api.v1.orders.deprecated") }
    #   end
    #
    # Headers emitted (always — including on the 410, so the failure is
    # self-documenting):
    #   * Deprecation — RFC 9745. The final form is a structured-fields Date
    #     item: "@<unix-seconds>" of `deprecated_at`. `header_format: :legacy`
    #     emits the still-widely-deployed pre-RFC draft form, the literal "true".
    #   * Sunset      — RFC 8594. An IMF-fixdate (HTTP-date) via Time#httpdate,
    #     NOT ISO 8601 — hand-rolling that is the classic bug.
    #   * Link        — RFC 8288. rel="deprecation" (the migration doc) and/or
    #     rel="successor-version" (the replacement endpoint), APPENDED to any
    #     Link header already on the response (pagination / CDN), never clobbered.
    #
    # `sunset_at` is an INSTANT, not a calendar day: a bare date "2026-12-31" is
    # normalised to 00:00 UTC, so the endpoint dies at the START of that day, not
    # end-of-day. Times are parsed eagerly at declaration time and normalised to
    # UTC.
    #
    # THE LAST MATCHING RULE WINS (deliberately the reverse of Idempotentable's
    # first-match): deprecation rules are configuration overrides, not guards, so
    # a V1 base controller's catch-all `deprecate_actions` is naturally
    # overridden by a later, action-specific declaration in a subclass. Exactly
    # one rule applies per request and exactly one Deprecation header is emitted.
    # With no positional actions a rule is a catch-all for the whole controller
    # (the WebhookVerifiable convention).
    #
    # `after_sunset: :gone` (requires `sunset_at`) halts with 410 once the sunset
    # instant is reached (the boundary instant counts as sunset — inclusive). The
    # default `:headers` NEVER blocks, however long past sunset — flip to `:gone`
    # only once metrics show callers have migrated. `on_deprecated_access` is that
    # metrics seam: it instruments "deprecated_endpoint.concerns_on_rails" and
    # runs `notify:`. A raising `notify` propagates on purpose — a broken metrics
    # hook should be loud, not silently swallowed (WebhookVerifiable's stance).
    module Deprecatable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Controllers::Deprecatable".freeze
      VALID_AFTER_SUNSET = %i[headers gone].freeze
      VALID_HEADER_FORMATS = %i[rfc9745 legacy].freeze
      UNPARSEABLE = "could not be parsed (pass a Time, Date, DateTime, or parseable String)".freeze

      included do
        class_attribute :deprecatable_rules, instance_accessor: false, default: []
        before_action :apply_api_deprecations
      end

      module ClassMethods
        # Declare a deprecation rule. No positional actions = catch-all for the
        # whole controller. Repeatable; rules accumulate (reassigned, never
        # mutated, so subclasses inherit) and the LAST one matching the current
        # action wins.
        def deprecate_actions(*actions, deprecated_at: nil, sunset_at: nil, link: nil, successor: nil,
                              after_sunset: :headers, header_format: :rfc9745, notify: nil)
          actions = actions.flatten.map(&:to_s)
          after_sunset = after_sunset.to_sym
          header_format = header_format.to_sym

          deprecated_time = parse_deprecation_time(deprecated_at)
          sunset_time = sunset_at.nil? ? nil : parse_deprecation_time(sunset_at)
          validate_deprecate_actions!(deprecated_at: deprecated_at, deprecated_time: deprecated_time,
                                      sunset_at: sunset_at, sunset_time: sunset_time, link: link,
                                      successor: successor, after_sunset: after_sunset, notify: notify)
          unless VALID_HEADER_FORMATS.include?(header_format)
            raise ArgumentError, "#{LABEL}: :header_format must be one of #{VALID_HEADER_FORMATS.join(', ')}"
          end

          rule = { actions: actions, deprecated_at: deprecated_time, sunset_at: sunset_time,
                   link: link, successor: successor, after_sunset: after_sunset,
                   header_format: header_format, notify: notify }
          self.deprecatable_rules = deprecatable_rules + [rule]
        end

        private

        def validate_deprecate_actions!(deprecated_at:, deprecated_time:, sunset_at:, sunset_time:,
                                        link:, successor:, after_sunset:, notify:)
          raise ArgumentError, "#{LABEL}: :deprecated_at is required" if deprecated_at.nil?
          raise ArgumentError, "#{LABEL}: :deprecated_at #{UNPARSEABLE}" if deprecated_time.nil?

          validate_deprecation_sunset!(sunset_at, sunset_time, deprecated_time, after_sunset)
          validate_deprecation_link!(:link, link)
          validate_deprecation_link!(:successor, successor)
          raise ArgumentError, "#{LABEL}: :notify must be callable" unless notify.nil? || notify.respond_to?(:call)
        end

        def validate_deprecation_sunset!(sunset_at, sunset_time, deprecated_time, after_sunset)
          unless VALID_AFTER_SUNSET.include?(after_sunset)
            raise ArgumentError, "#{LABEL}: :after_sunset must be one of #{VALID_AFTER_SUNSET.join(', ')}"
          end

          unless sunset_at.nil?
            raise ArgumentError, "#{LABEL}: :sunset_at #{UNPARSEABLE}" if sunset_time.nil?
            raise ArgumentError, "#{LABEL}: :sunset_at must be on or after :deprecated_at" if sunset_time < deprecated_time
          end

          raise ArgumentError, "#{LABEL}: after_sunset: :gone requires :sunset_at" if after_sunset == :gone && sunset_time.nil?
        end

        def validate_deprecation_link!(name, value)
          return if value.nil?
          return if value.is_a?(String) && !value.strip.empty?

          raise ArgumentError, "#{LABEL}: :#{name} must be a non-blank String"
        end

        # Eager parse to a UTC Time. A bare Date (or date-only String) becomes
        # midnight UTC — sunset is an instant at the START of the day.
        def parse_deprecation_time(value)
          case value
          # TimeWithZone listed explicitly: it lies about is_a?(Time) but
          # Module#=== checks the real ancestry, so `when Time` alone would
          # miss it — and Time.current / 1.month.from_now are exactly the
          # values Rails hosts pass.
          when ActiveSupport::TimeWithZone, Time then value.utc
          when DateTime then value.to_time.utc
          when Date then Time.utc(value.year, value.month, value.day)
          when String then parse_deprecation_string(value)
          end
        end

        def parse_deprecation_string(value)
          return nil if value.strip.empty?

          # DateTime.parse reads a zoneless string as UTC (+00:00) regardless of
          # the host's system timezone — deterministic — and honours an explicit
          # offset when one is present.
          DateTime.parse(value).to_time.utc
        rescue ArgumentError, TypeError
          nil
        end
      end

      # before_action entry point. Public so host apps can
      # `skip_before_action :apply_api_deprecations` or override it.
      def apply_api_deprecations
        rule = deprecation_rule_for_action
        return nil unless rule

        # Order matters: headers go out unconditionally (so even the 410 carries
        # them), THEN we record the access, THEN enforce. Recording before
        # enforcing means metrics still count callers who get the 410.
        emit_deprecation_headers(rule)
        on_deprecated_access(rule)
        enforce_deprecation_sunset(rule)
      end

      # Public override point + instrumentation seam. Default: emit an
      # ActiveSupport::Notifications event and run the rule's `notify:` callable
      # (instance_exec'd, so it can read controller state). A raising `notify`
      # propagates by design.
      def on_deprecated_access(rule)
        ActiveSupport::Notifications.instrument(
          "deprecated_endpoint.concerns_on_rails",
          controller: deprecation_controller_name, action: deprecation_action_name,
          deprecated_at: rule[:deprecated_at], sunset_at: rule[:sunset_at]
        )
        instance_exec(&rule[:notify]) if rule[:notify]
      end

      # True when some rule covers the current action.
      def deprecation_active?
        !deprecation_rule_for_action.nil?
      end

      # True when the matching rule has a sunset_at that the clock has reached.
      def sunset_passed?
        deprecation_sunset_reached?(deprecation_rule_for_action)
      end

      private

      def deprecation_rule_for_action
        action = deprecation_action_name
        return nil unless action

        # Last match wins — see the module comment. reverse_each.find returns the
        # most recently declared rule covering this action (catch-all or not).
        self.class.deprecatable_rules.reverse_each.find do |rule|
          rule[:actions].empty? || rule[:actions].include?(action)
        end
      end

      def emit_deprecation_headers(rule)
        return unless respond_to?(:response) && response

        response.set_header("Deprecation", deprecation_header_value(rule))
        response.set_header("Sunset", rule[:sunset_at].httpdate) if rule[:sunset_at]
        emit_deprecation_link_header(rule)
      end

      def deprecation_header_value(rule)
        # :legacy is the pre-RFC draft form everyone already ships; :rfc9745 is
        # the structured-fields Date item finalised in RFC 9745.
        return "true" if rule[:header_format] == :legacy

        "@#{rule[:deprecated_at].to_i}"
      end

      def emit_deprecation_link_header(rule)
        parts = []
        parts << "<#{rule[:link]}>; rel=\"deprecation\"" if rule[:link]
        parts << "<#{rule[:successor]}>; rel=\"successor-version\"" if rule[:successor]
        return if parts.empty?

        value = parts.join(", ")
        # Append, never clobber: pagination / CDN may already have set Link.
        existing = response.headers["Link"]
        value = "#{existing}, #{value}" unless existing.to_s.empty?
        response.set_header("Link", value)
      end

      def enforce_deprecation_sunset(rule)
        return unless rule[:after_sunset] == :gone
        return unless deprecation_sunset_reached?(rule)

        message = "This endpoint was sunset on #{rule[:sunset_at].httpdate}."
        return render_error(message: message, status: :gone, code: "endpoint_sunset") if respond_to?(:render_error)
        return unless respond_to?(:response) && response

        render json: { success: false, error: { message: message, code: "endpoint_sunset" } }, status: :gone
      end

      # Inclusive: the boundary instant itself counts as sunset.
      def deprecation_sunset_reached?(rule)
        !!(rule && rule[:sunset_at] && deprecation_now >= rule[:sunset_at])
      end

      def deprecation_action_name
        respond_to?(:action_name) ? action_name.to_s : nil
      end

      def deprecation_controller_name
        return controller_path if respond_to?(:controller_path)

        self.class.name
      end

      # Single clock seam so travel_to drives everything in specs.
      def deprecation_now
        Time.now.utc
      end
    end
  end
end
