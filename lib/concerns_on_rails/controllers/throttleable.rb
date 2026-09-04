require "active_support/concern"
require "concerns_on_rails/support/error_envelope"

module ConcernsOnRails
  module Controllers
    # Per-request rate limiting with a store-agnostic, injectable backend. When a
    # rule's limit is exceeded the request is halted with 429 plus
    # `Retry-After` and `X-RateLimit-Limit` / `X-RateLimit-Remaining` /
    # `X-RateLimit-Reset` headers.
    #
    #   class Api::BaseController < ApplicationController
    #     include ConcernsOnRails::Controllers::Throttleable
    #
    #     self.throttleable_store = Rails.cache               # must support atomic #increment
    #
    #     throttle_by limit: 100, period: 1.minute                          # by IP (default)
    #     throttle_by limit: 5,   period: 1.minute, only: :create,
    #                 by: -> { current_user&.id || request.remote_ip }
    #     throttle_by limit: 1000, period: 1.hour, unless: :staff?          # skip conditions
    #   end
    #
    # When several rules apply to one request the X-RateLimit-* headers
    # describe the TIGHTEST one (fewest requests remaining). A throttled
    # request instruments "rate_limited.concerns_on_rails" (see
    # `on_rate_limited`, the override point) before the 429 is rendered.
    #
    # Fixed-window counter: the key embeds a floored time bucket
    # (`epoch / period`) so each window starts clean and `X-RateLimit-Reset` is
    # exact. The store MUST support atomic increment-with-expiry (`Rails.cache`
    # with `#increment`, or Redis); a non-atomic store under-counts under
    # concurrency. There is no in-process default store on purpose — configure
    # one explicitly (per controller as above, or once for the whole app via
    # `ConcernsOnRails.setup { |c| c.cache_store = -> { Rails.cache } }`) or
    # the first throttled request raises ArgumentError.
    module Throttleable
      extend ActiveSupport::Concern

      # Default discriminator — one counter per client IP. Evaluated with
      # instance_exec on the controller, so `request` resolves normally.
      DEFAULT_DISCRIMINATOR = -> { request.remote_ip }

      included do
        class_attribute :throttleable_rules, instance_accessor: false, default: []
        class_attribute :throttleable_store, instance_accessor: false, default: nil
        before_action :enforce_throttles
      end

      module ClassMethods
        # Declare a rate-limit rule. `limit` requests per `period` (a Duration or
        # seconds), bucketed by `by:` (a callable, default per-IP). `only:`/
        # `except:` scope it to a subset of actions (mutually exclusive). `if:`/
        # `unless:` (a Symbol naming a controller method, or a callable
        # instance_exec'd on the controller) skip the rule per request — staff
        # accounts, internal IPs, feature flags; both may be given, and both must
        # pass. `name:` disambiguates the counter key when several rules share a
        # discriminator.
        def throttle_by(limit:, period:, by: nil, only: nil, except: nil, name: nil, if: nil, unless: nil)
          # `if`/`unless` are keywords, so the parameters are read via binding.
          if_condition = binding.local_variable_get(:if)
          unless_condition = binding.local_variable_get(:unless)
          validate_throttle!(limit: limit, period: period, by: by, only: only, except: except,
                             if_condition: if_condition, unless_condition: unless_condition)

          rule = {
            limit: limit,
            period: period.to_i,
            by: by || DEFAULT_DISCRIMINATOR,
            only: only && Array(only).map(&:to_s),
            except: except && Array(except).map(&:to_s),
            if: if_condition,
            unless: unless_condition,
            name: (name || "rule#{throttleable_rules.size}").to_s
          }
          self.throttleable_rules = throttleable_rules + [rule]
        end

        private

        def validate_throttle!(limit:, period:, by:, only:, except:, if_condition:, unless_condition:)
          prefix = "ConcernsOnRails::Controllers::Throttleable"
          raise ArgumentError, "#{prefix}: :limit must be a positive integer" unless positive_integer?(limit)
          raise ArgumentError, "#{prefix}: :period must be a positive duration" unless period.to_i.positive?
          raise ArgumentError, "#{prefix}: :by must be callable" unless callable_or_nil?(by)
          raise ArgumentError, "#{prefix}: pass either :only or :except, not both" if only && except

          validate_throttle_condition!(prefix, :if, if_condition)
          validate_throttle_condition!(prefix, :unless, unless_condition)
        end

        def validate_throttle_condition!(prefix, option, value)
          return if value.nil? || value.is_a?(Symbol) || value.respond_to?(:call)

          raise ArgumentError, "#{prefix}: :#{option} must be a Symbol or callable"
        end

        def positive_integer?(value)
          value.is_a?(Integer) && value.positive?
        end

        def callable_or_nil?(value)
          value.nil? || value.respond_to?(:call)
        end
      end

      # Public so subclasses can override. Applies each in-scope rule; the first
      # rule that exceeds its limit emits its headers, instruments the event and
      # halts the request with a 429. When every rule passes, the headers
      # describe the tightest one (fewest remaining).
      def enforce_throttles
        applied = []
        self.class.throttleable_rules.each do |rule|
          next unless throttle_rule_applies?(rule)

          result = register_throttle_hit(rule)
          applied << [rule, result]
          next unless result[:count] > rule[:limit]

          emit_throttle_headers(rule, result)
          on_rate_limited(rule, result)
          return throttled_response(rule, result)
        end
        emit_tightest_throttle_headers(applied)
        nil
      end

      # Public override point + instrumentation seam, run once per throttled
      # request before the 429 body is rendered. Default: emit
      # "rate_limited.concerns_on_rails" with the rule name, discriminator,
      # count/limit/period, reset_at/retry_after and controller/action — the
      # hook for alerting on abusive clients or logging. Call super to keep the
      # event when overriding.
      def on_rate_limited(rule, result)
        ActiveSupport::Notifications.instrument(
          "rate_limited.concerns_on_rails",
          controller: throttle_controller_name, action: throttle_action_name,
          rule: rule[:name], discriminator: result[:discriminator],
          count: result[:count], limit: rule[:limit], period: rule[:period],
          reset_at: result[:reset_at], retry_after: result[:retry_after]
        )
      end

      # Public override point for the 429 body.
      def throttled_response(_rule, result)
        return unless respond_to?(:response) && response

        message = "Rate limit exceeded. Retry in #{result[:retry_after]}s."
        ConcernsOnRails::Support::ErrorEnvelope.render(
          self, message: message, status: :too_many_requests, code: "rate_limited"
        )
      end

      private

      def throttle_rule_applies?(rule)
        throttle_action_in_scope?(rule) && throttle_conditions_pass?(rule)
      end

      def throttle_action_in_scope?(rule)
        action = throttle_action_name
        return rule[:only].include?(action) if rule[:only]
        return !rule[:except].include?(action) if rule[:except]

        true
      end

      # if: must be truthy and unless: falsy; a Symbol names a controller
      # method, a callable is instance_exec'd (so `request`/`current_user` work).
      def throttle_conditions_pass?(rule)
        return false if rule[:if] && !throttle_evaluate_condition(rule[:if])
        return false if rule[:unless] && throttle_evaluate_condition(rule[:unless])

        true
      end

      def throttle_evaluate_condition(condition)
        condition.is_a?(Symbol) ? send(condition) : instance_exec(&condition)
      end

      def register_throttle_hit(rule)
        store = throttle_store!
        now = Time.now.to_i
        window = now / rule[:period]
        reset_at = (window + 1) * rule[:period]
        discriminator = throttle_discriminator(rule)
        key = "throttleable:#{rule[:name]}:#{discriminator}:#{window}"

        # Atomic increment-with-expiry. Some stores return nil on the first
        # increment of a missing key — seed it to 1 in that case.
        count = store.increment(key, 1, expires_in: rule[:period])
        count ||= seed_throttle_key(store, key, rule[:period])

        { count: count.to_i, reset_at: reset_at, retry_after: [reset_at - now, 0].max, discriminator: discriminator }
      end

      # Several rules, one set of headers: the client should see the budget
      # that will run out first, not whichever rule happened to be declared last.
      def emit_tightest_throttle_headers(applied)
        return if applied.empty?

        rule, result = applied.min_by { |candidate, outcome| candidate[:limit] - outcome[:count] }
        emit_throttle_headers(rule, result)
      end

      # Seed with unless_exist so two concurrent first hits can't both write 1
      # and under-count the window; when this seed loses that race, increment
      # the winner's counter instead.
      def seed_throttle_key(store, key, period)
        return 1 unless store.respond_to?(:write)

        if store.write(key, 1, expires_in: period, unless_exist: true)
          1
        else
          store.increment(key, 1, expires_in: period) || 1
        end
      end

      def throttle_discriminator(rule)
        value = instance_exec(&rule[:by])
        if value.blank?
          # A nil/blank discriminator (e.g. `-> { current_user&.id }` for an
          # anonymous request) would collapse every client into ONE shared
          # bucket — fail loudly instead of throttling the whole site.
          raise ArgumentError,
                "ConcernsOnRails::Controllers::Throttleable: rule '#{rule[:name]}' discriminator " \
                "resolved blank; fall back explicitly, e.g. `by: -> { current_user&.id || request.remote_ip }`"
        end
        value
      end

      def emit_throttle_headers(rule, result)
        return unless respond_to?(:response) && response

        remaining = [rule[:limit] - result[:count], 0].max
        response.set_header("X-RateLimit-Limit", rule[:limit].to_s)
        response.set_header("X-RateLimit-Remaining", remaining.to_s)
        response.set_header("X-RateLimit-Reset", result[:reset_at].to_s)
        response.set_header("Retry-After", result[:retry_after].to_s) if result[:count] > rule[:limit]
      end

      def throttle_store!
        store = self.class.throttleable_store || ConcernsOnRails.config.resolved_cache_store
        return store if store

        raise ArgumentError,
              "ConcernsOnRails::Controllers::Throttleable: no store configured. " \
              "Set `self.throttleable_store = Rails.cache` on the controller, or the gem-wide " \
              "fallback: ConcernsOnRails.setup { |c| c.cache_store = -> { Rails.cache } } " \
              "(must support atomic #increment)."
      end

      def throttle_action_name
        respond_to?(:action_name) ? action_name.to_s : nil
      end

      def throttle_controller_name
        self.class.respond_to?(:controller_path) ? self.class.controller_path : self.class.name
      end
    end
  end
end
