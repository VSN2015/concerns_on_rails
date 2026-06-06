require "active_support/concern"

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
    #   end
    #
    # Fixed-window counter: the key embeds a floored time bucket
    # (`epoch / period`) so each window starts clean and `X-RateLimit-Reset` is
    # exact. The store MUST support atomic increment-with-expiry (`Rails.cache`
    # with `#increment`, or Redis); a non-atomic store under-counts under
    # concurrency. There is no in-process default store on purpose — configure
    # one explicitly or the first throttled request raises ArgumentError.
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
        # `except:` scope it to a subset of actions (mutually exclusive). `name:`
        # disambiguates the counter key when several rules share a discriminator.
        def throttle_by(limit:, period:, by: nil, only: nil, except: nil, name: nil)
          validate_throttle!(limit: limit, period: period, by: by, only: only, except: except)

          rule = {
            limit: limit,
            period: period.to_i,
            by: by || DEFAULT_DISCRIMINATOR,
            only: only && Array(only).map(&:to_s),
            except: except && Array(except).map(&:to_s),
            name: (name || "rule#{throttleable_rules.size}").to_s
          }
          self.throttleable_rules = throttleable_rules + [rule]
        end

        private

        def validate_throttle!(limit:, period:, by:, only:, except:)
          prefix = "ConcernsOnRails::Controllers::Throttleable"
          raise ArgumentError, "#{prefix}: :limit must be a positive integer" unless positive_integer?(limit)
          raise ArgumentError, "#{prefix}: :period must be a positive duration" unless period.to_i.positive?
          raise ArgumentError, "#{prefix}: :by must be callable" unless callable_or_nil?(by)
          raise ArgumentError, "#{prefix}: pass either :only or :except, not both" if only && except
        end

        def positive_integer?(value)
          value.is_a?(Integer) && value.positive?
        end

        def callable_or_nil?(value)
          value.nil? || value.respond_to?(:call)
        end
      end

      # Public so subclasses can override. Applies each in-scope rule; the first
      # rule that exceeds its limit halts the request with a 429.
      def enforce_throttles
        self.class.throttleable_rules.each do |rule|
          next unless throttle_rule_applies?(rule)

          result = register_throttle_hit(rule)
          emit_throttle_headers(rule, result)

          return throttled_response(rule, result) if result[:count] > rule[:limit]
        end
        nil
      end

      # Public override point for the 429 body.
      def throttled_response(_rule, result)
        return unless respond_to?(:response) && response

        message = "Rate limit exceeded. Retry in #{result[:retry_after]}s."
        return render_error(message: message, status: :too_many_requests, code: "rate_limited") if respond_to?(:render_error)

        render json: { success: false, error: { message: message, code: "rate_limited" } }, status: :too_many_requests
      end

      private

      def throttle_rule_applies?(rule)
        action = throttle_action_name
        return rule[:only].include?(action) if rule[:only]
        return !rule[:except].include?(action) if rule[:except]

        true
      end

      def register_throttle_hit(rule)
        store = throttle_store!
        now = Time.now.to_i
        window = now / rule[:period]
        reset_at = (window + 1) * rule[:period]
        key = "throttleable:#{rule[:name]}:#{throttle_discriminator(rule)}:#{window}"

        # Atomic increment-with-expiry. Some stores return nil on the first
        # increment of a missing key — seed it to 1 in that case.
        count = store.increment(key, 1, expires_in: rule[:period])
        count ||= seed_throttle_key(store, key, rule[:period])

        { count: count.to_i, reset_at: reset_at, retry_after: [reset_at - now, 0].max }
      end

      def seed_throttle_key(store, key, period)
        store.write(key, 1, expires_in: period) if store.respond_to?(:write)
        1
      end

      def throttle_discriminator(rule)
        instance_exec(&rule[:by])
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
        store = self.class.throttleable_store
        return store if store

        raise ArgumentError,
              "ConcernsOnRails::Controllers::Throttleable: no store configured. " \
              "Set `self.throttleable_store = Rails.cache` (must support atomic #increment)."
      end

      def throttle_action_name
        respond_to?(:action_name) ? action_name.to_s : nil
      end
    end
  end
end
