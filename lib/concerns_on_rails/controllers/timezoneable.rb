require "active_support/concern"

module ConcernsOnRails
  module Controllers
    # Per-request `Time.zone` selection from the request params, the `Time-Zone`
    # header, and/or a cookie, wrapped in an `around_action` so `Time.zone` is set
    # for the action and restored afterwards. The time analogue of Localizable
    # (which does the same for `I18n.locale`). Dependency-free.
    #
    #   class ApplicationController < ActionController::Base
    #     include ConcernsOnRails::Controllers::Timezoneable
    #
    #     timezoneable available: ["UTC", "Eastern Time (US & Canada)"], default: "UTC"
    #     # timezoneable param: :tz, header: false, cookie: :time_zone
    #   end
    #
    # Resolution order: `params[param]` → `Time-Zone` header → cookie (if enabled)
    # → `default` → the current `Time.zone`. Every value — the configured
    # `available:`/`default:` AND each request candidate — is resolved through
    # `ActiveSupport::TimeZone[...]`, so a zone accepted at boot can never be
    # rejected at request time.
    #
    # Options: `available:` (allow-list applied to param/header/cookie matching;
    # `default:` bypasses it, mirroring Localizable), `default:`, `param:`
    # (default `:time_zone`), `header:` (default `true`), `cookie:` (default
    # `false`; `true` reads the `:time_zone` cookie, or pass a cookie name),
    # `persist:` (default `false`; `true` or a Hash of cookie options — a zone
    # chosen via the PARAM is written into the `cookie:` so it sticks; needs
    # `cookie:`), `response_header:` (default `false`; `true` emits
    # `X-Time-Zone: <name>`, or pass a header name; `Vary: Time-Zone` is
    # appended when the header source is on). `time_zone_source` reports which
    # source won.
    module Timezoneable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Controllers::Timezoneable".freeze
      DEFAULT_RESPONSE_HEADER = "X-Time-Zone".freeze
      DEFAULT_PERSIST = { expires: 1.year }.freeze

      included do
        class_attribute :timezoneable_options, instance_accessor: false, default: {}
        around_action :switch_time_zone
      end

      module ClassMethods
        def timezoneable(available: nil, default: nil, param: :time_zone, header: true, cookie: false,
                         persist: false, response_header: false)
          cookie_name = cookie == true ? :time_zone : cookie.presence
          self.timezoneable_options = {
            available: validate_time_zones(available),
            default: validate_time_zone(default),
            param: param&.to_sym,
            header: header,
            cookie: cookie_name,
            persist: validate_persist(persist, cookie_name),
            response_header: response_header == true ? DEFAULT_RESPONSE_HEADER : response_header.presence
          }
        end

        private

        # persist: true → the default cookie options; a Hash overrides them.
        # Persisting needs a cookie to write into.
        def validate_persist(persist, cookie_name)
          return nil if persist == false || persist.nil?
          raise ArgumentError, "#{LABEL}: persist: requires cookie: (the cookie to write the chosen zone into)" unless cookie_name

          persist.is_a?(Hash) ? DEFAULT_PERSIST.merge(persist) : DEFAULT_PERSIST
        end

        def validate_time_zones(zones)
          return nil if zones.nil?

          Array(zones).map { |zone| validate_time_zone(zone) }
        end

        # Resolve a single configured zone to an ActiveSupport::TimeZone at boot,
        # raising on an unknown name so misconfiguration fails fast.
        def validate_time_zone(zone)
          return nil if zone.nil?

          ActiveSupport::TimeZone[zone] ||
            raise(ArgumentError, "ConcernsOnRails::Controllers::Timezoneable: unknown time zone '#{zone}'")
        end
      end

      # Public so subclasses can override; runs the action under the resolved
      # zone. UNGUARDED on purpose — it touches `Time` globally, not the response
      # (mirrors Localizable#switch_locale).
      def switch_time_zone(&)
        zone = resolved_time_zone
        persist_time_zone(zone)
        apply_time_zone_response_header(zone)
        # Skip the wrapper when it would be a no-op — with nothing configured
        # (or the client asking for the current zone) every action used to run
        # inside a pointless Time.use_zone block.
        return yield if Time.zone && zone && zone.name == Time.zone.name

        Time.use_zone(zone, &)
      end

      # The ActiveSupport::TimeZone chosen for this request — always one `Time`
      # can switch to (falls back to the current `Time.zone`). Memoized per
      # request: resolution costs up to three TimeZone lookups plus an
      # allow-list scan.
      def resolved_time_zone
        return @resolved_time_zone if defined?(@resolved_time_zone) && @resolved_time_zone

        @resolved_time_zone, @time_zone_source = resolve_time_zone_with_source
        @resolved_time_zone
      end

      # Which source produced `resolved_time_zone`: :param, :header, :cookie,
      # :default, or :current (nothing matched — the ambient Time.zone stands).
      def time_zone_source
        resolved_time_zone
        @time_zone_source
      end

      private

      def resolve_time_zone_with_source
        opts = self.class.timezoneable_options
        allowed = opts[:available]
        %i[param header cookie].each do |source|
          zone = send("zone_from_#{source}", opts, allowed)
          return [zone, source] if zone
        end
        default = resolve_zone(opts[:default])
        default ? [default, :default] : [Time.zone, :current]
      end

      # An explicit ?time_zone= choice is the one worth remembering — a header
      # is per-request client state and the cookie already holds its own value.
      def persist_time_zone(zone)
        opts = self.class.timezoneable_options
        return unless opts[:persist] && zone && time_zone_source == :param
        # ActionController declares #cookies PRIVATE, so a bare respond_to? is
        # false on Base and this guard silently disabled the whole feature.
        # (ActionController::API has no cookies at all, and still skips.)
        return unless respond_to?(:cookies, true) && cookies

        cookies[opts[:cookie]] = opts[:persist].merge(value: zone.name)
      end

      # X-Time-Zone (or the configured name) plus Vary: Time-Zone when the
      # request header can influence the choice — appended and de-duplicated,
      # never clobbered (Localizable's Content-Language rule).
      def apply_time_zone_response_header(zone)
        name = self.class.timezoneable_options[:response_header]
        return unless name && zone && respond_to?(:response) && response.respond_to?(:set_header)

        response.set_header(name, zone.name)
        append_vary_time_zone if self.class.timezoneable_options[:header]
      end

      def append_vary_time_zone
        existing = response.headers["Vary"].to_s.split(",").map(&:strip).reject(&:empty?)
        return if existing.any? { |value| value.casecmp?("Time-Zone") }

        response.set_header("Vary", (existing + ["Time-Zone"]).join(", "))
      end

      # Match a raw source value against the allow-list (when present), returning
      # the resolved TimeZone or nil so the resolution chain falls through.
      def match_zone(raw, allowed)
        return nil if raw.blank?

        zone = ActiveSupport::TimeZone[raw.to_s]
        return nil unless zone
        return nil if allowed&.none? { |z| z.name == zone.name }

        zone
      end

      # Final coercion: `default` is already a TimeZone; the Time.zone fallback is
      # handled by the caller.
      def resolve_zone(candidate)
        return nil if candidate.blank?
        return candidate if candidate.is_a?(ActiveSupport::TimeZone)

        ActiveSupport::TimeZone[candidate.to_s]
      end

      def zone_from_param(opts, allowed)
        return nil unless opts[:param] && respond_to?(:params) && params

        match_zone(params[opts[:param]], allowed)
      end

      def zone_from_header(opts, allowed)
        return nil unless opts[:header] && respond_to?(:request)

        req = request
        header = req.respond_to?(:headers) ? req.headers["Time-Zone"] : nil
        match_zone(header, allowed)
      end

      def zone_from_cookie(opts, allowed)
        key = opts[:cookie]
        return nil unless key && respond_to?(:cookies, true) && cookies

        match_zone(cookies[key], allowed)
      end
    end
  end
end
