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
    # `false`; `true` reads the `:time_zone` cookie, or pass a cookie name).
    module Timezoneable
      extend ActiveSupport::Concern

      included do
        class_attribute :timezoneable_options, instance_accessor: false, default: {}
        around_action :switch_time_zone
      end

      module ClassMethods
        def timezoneable(available: nil, default: nil, param: :time_zone, header: true, cookie: false)
          self.timezoneable_options = {
            available: validate_time_zones(available),
            default: validate_time_zone(default),
            param: param&.to_sym,
            header: header,
            cookie: cookie == true ? :time_zone : cookie.presence
          }
        end

        private

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
        Time.use_zone(resolved_time_zone, &)
      end

      # The ActiveSupport::TimeZone chosen for this request — always one `Time`
      # can switch to (falls back to the current `Time.zone`).
      def resolved_time_zone
        opts = self.class.timezoneable_options
        allowed = opts[:available]
        candidate = zone_from_param(opts, allowed) ||
                    zone_from_header(opts, allowed) ||
                    zone_from_cookie(opts, allowed) ||
                    opts[:default]

        resolve_zone(candidate) || Time.zone
      end

      private

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
        return nil unless key && respond_to?(:cookies) && cookies

        match_zone(cookies[key], allowed)
      end
    end
  end
end
