require "active_support/concern"
require "digest/md5"
require "time"

module ConcernsOnRails
  module Controllers
    # HTTP conditional GET + declarative Cache-Control ("fresh_when/stale?-lite"
    # for JSON APIs). Two layers:
    #
    #   1. A declarative `Cache-Control`/`Vary` POLICY per action (the macro).
    #   2. Per-action validators (ETag / Last-Modified) with an automatic
    #      `304 Not Modified` short-circuit (the `stale_resource?` helper).
    #
    #   class Api::ArticlesController < ApplicationController
    #     include ConcernsOnRails::Controllers::Cacheable
    #
    #     http_cache_actions :index, :show, max_age: 5.minutes,
    #                        visibility: :public, vary: "Accept"
    #
    #     def show
    #       @article = Article.find(params[:id])
    #       return unless stale_resource?(@article)   # 304 + halt when client copy is fresh
    #       render json: @article
    #     end
    #   end
    #
    # The method names are deliberately distinct from Rails'
    # `ActionController::ConditionalGet` (`fresh_when` / `stale?` / `expires_in`)
    # so including this concern in a real controller never shadows them.
    #
    # Conditional-GET correctness (the value over a hand-rolled version):
    #   * ETag is a WEAK validator `W/"<md5>"` derived from the resource's cache
    #     key — appropriate for serialized representations (semantic, not
    #     byte-for-byte, equivalence). `If-None-Match` is matched with weak
    #     comparison, honours `*`, and accepts a comma-separated list.
    #   * `Last-Modified` is an IMF-fixdate via `Time#httpdate` (NOT ISO 8601 —
    #     the classic bug). `If-Modified-Since` is compared at whole-second
    #     granularity (HTTP dates carry no sub-second part).
    #   * When BOTH `If-None-Match` and `If-Modified-Since` are sent, the ETag
    #     wins and the date is ignored (RFC 7232 §3.3).
    #   * The 304 is only sent for safe requests (GET/HEAD) and still carries the
    #     validators AND the policy headers (Cache-Control rides the 304, like
    #     Deprecatable's headers ride the 410).
    #
    # Notes:
    #   * `no_store: true` overrides everything (emits the lone `no-store`).
    #   * `Vary` is appended to any existing `Vary` header, de-duplicated.
    #   * No positional actions = catch-all; the LAST matching rule wins (the
    #     Deprecatable convention — caching policy is an override).
    #   * Works on bare objects (every `request`/`response` touch is guarded), so
    #     it is testable without the full Rails stack.
    #   * For write-side preconditions (`If-Match` / `If-Unmodified-Since` → 412)
    #     reach for Rails' own conditional-GET helpers; this concern covers the
    #     read path.
    module Cacheable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Controllers::Cacheable".freeze
      VALID_VISIBILITY = %i[public private].freeze
      SAFE_METHODS = %w[GET HEAD].freeze

      included do
        class_attribute :cacheable_rules, instance_accessor: false, default: []
        after_action :apply_http_cache_headers
      end

      module ClassMethods
        # Declare a Cache-Control/Vary policy for the given actions (none =
        # catch-all). Repeatable; rules accumulate (reassigned, never mutated, so
        # subclasses inherit) and the LAST one matching the action wins.
        def http_cache_actions(*actions, visibility: :private, max_age: nil, must_revalidate: false,
                               no_store: false, stale_while_revalidate: nil, vary: nil)
          actions = actions.flatten.map(&:to_s)
          visibility = visibility.to_sym
          validate_http_cache!(visibility: visibility, max_age: max_age, no_store: no_store,
                               must_revalidate: must_revalidate, stale_while_revalidate: stale_while_revalidate)

          rule = {
            actions: actions, visibility: visibility,
            max_age: http_cache_seconds(max_age),
            must_revalidate: must_revalidate ? true : false,
            no_store: no_store ? true : false,
            stale_while_revalidate: http_cache_seconds(stale_while_revalidate),
            vary: http_cache_vary(vary)
          }
          self.cacheable_rules = cacheable_rules + [rule]
        end

        private

        def validate_http_cache!(visibility:, max_age:, no_store:, must_revalidate:, stale_while_revalidate:)
          unless VALID_VISIBILITY.include?(visibility)
            raise ArgumentError, "#{LABEL}: :visibility must be one of #{VALID_VISIBILITY.join(', ')}"
          end
          raise ArgumentError, "#{LABEL}: :max_age must be a positive Integer/Duration or nil" unless http_cache_duration_ok?(max_age)
          unless http_cache_duration_ok?(stale_while_revalidate)
            raise ArgumentError, "#{LABEL}: :stale_while_revalidate must be a positive Integer/Duration or nil"
          end
          raise ArgumentError, "#{LABEL}: :no_store must be true or false" unless [true, false].include?(no_store)
          return if [true, false].include?(must_revalidate)

          raise ArgumentError, "#{LABEL}: :must_revalidate must be true or false"
        end

        def http_cache_duration_ok?(value)
          value.nil? || ((value.is_a?(Integer) || value.is_a?(ActiveSupport::Duration)) && value.to_i.positive?)
        end

        def http_cache_seconds(value)
          value&.to_i
        end

        # Normalize + validate :vary into an Array of header names (or nil).
        def http_cache_vary(value)
          case value
          when nil then nil
          when String then http_cache_vary_list([value])
          when Array then http_cache_vary_list(value)
          else raise ArgumentError, "#{LABEL}: :vary must be a String or Array of Strings"
          end
        end

        def http_cache_vary_list(values)
          list = values.map { |v| v.to_s.strip }
          if list.empty? || list.any?(&:empty?)
            raise ArgumentError, "#{LABEL}: :vary must be a non-blank String or Array of non-blank Strings"
          end

          list
        end
      end

      # after_action entry point. Public so host apps can `skip_after_action` it
      # or override it. Emits the matching action's Cache-Control + Vary.
      def apply_http_cache_headers
        rule = http_cache_rule_for_action
        return unless rule
        return unless respond_to?(:response) && response

        value = http_cache_control_value(rule)
        response.set_header("Cache-Control", value) if value
        response.set_header("Vary", http_cache_merge_vary(rule[:vary])) if rule[:vary]
        nil
      end

      # Set ETag/Last-Modified validators for the resource, then — for a safe
      # request whose precondition matches — send 304 and return false. Returns
      # true when the client must be sent a fresh body. Mirrors Rails `stale?`.
      def stale_resource?(resource = nil, etag: nil, last_modified: nil)
        validators = set_cache_validators(resource, etag: etag, last_modified: last_modified)
        return true unless http_cache_safe_request?
        return true unless request_matches_cache?(etag: validators[:etag], last_modified: validators[:last_modified])

        http_cache_send_not_modified
        false
      end

      # Set the ETag/Last-Modified response headers (no short-circuit). Returns
      # the computed { etag:, last_modified: } pair.
      def set_cache_validators(resource = nil, etag: nil, last_modified: nil)
        etag ||= cache_etag_for(resource) unless resource.nil?
        last_modified ||= cache_last_modified_for(resource) unless resource.nil?
        http_cache_write_validators(etag, last_modified)
        { etag: etag, last_modified: last_modified }
      end

      # Side-effect-free: does the request's precondition match these validators?
      def request_matches_cache?(etag: nil, last_modified: nil)
        if_none_match = http_cache_request_header("If-None-Match")
        if_modified_since = http_cache_request_header("If-Modified-Since")

        # If-None-Match takes precedence when present (RFC 7232 §3.3).
        if if_none_match
          etag && http_cache_etag_matches?(if_none_match, etag)
        elsif if_modified_since
          last_modified ? http_cache_not_modified_since?(if_modified_since, last_modified) : false
        else
          false
        end
      end

      # Override points for deriving validators from a resource.
      def cache_etag_for(resource)
        http_cache_weak_etag(http_cache_key_for(resource))
      end

      def cache_last_modified_for(resource)
        http_cache_timestamp_for(resource)
      end

      private

      def http_cache_write_validators(etag, last_modified)
        return unless respond_to?(:response) && response

        response.set_header("ETag", etag) if etag
        response.set_header("Last-Modified", last_modified.httpdate) if last_modified
      end

      def http_cache_rule_for_action
        action = http_cache_action_name
        return nil unless action

        self.class.cacheable_rules.reverse_each.find do |rule|
          rule[:actions].empty? || rule[:actions].include?(action)
        end
      end

      def http_cache_control_value(rule)
        return "no-store" if rule[:no_store]

        parts = [rule[:visibility].to_s]
        parts << "max-age=#{rule[:max_age]}" if rule[:max_age]
        parts << "must-revalidate" if rule[:must_revalidate]
        parts << "stale-while-revalidate=#{rule[:stale_while_revalidate]}" if rule[:stale_while_revalidate]
        parts.join(", ")
      end

      def http_cache_merge_vary(vary_list)
        values = []
        existing = response.headers["Vary"]
        values.concat(existing.split(",").map(&:strip)) unless existing.to_s.empty?
        values.concat(vary_list)
        values.uniq.join(", ")
      end

      def http_cache_send_not_modified
        response.status = 304 if respond_to?(:response) && response

        if respond_to?(:head)
          head :not_modified
        else
          render(status: :not_modified)
        end
      end

      def http_cache_safe_request?
        return true unless respond_to?(:request) && request

        if request.respond_to?(:get?) && request.respond_to?(:head?)
          request.get? || request.head?
        elsif request.respond_to?(:request_method)
          SAFE_METHODS.include?(request.request_method.to_s.upcase)
        else
          true
        end
      end

      def http_cache_request_header(name)
        return nil unless respond_to?(:request) && request.respond_to?(:headers) && request.headers

        request.headers[name]
      end

      def http_cache_etag_matches?(header, etag)
        candidates = header.to_s.split(",").map(&:strip)
        return true if candidates.include?("*")

        target = http_cache_normalize_etag(etag)
        candidates.any? { |candidate| http_cache_normalize_etag(candidate) == target }
      end

      # Weak comparison: ignore the "W/" prefix (RFC 7232 §2.3.2).
      def http_cache_normalize_etag(value)
        value.to_s.strip.sub(%r{\AW/}, "")
      end

      def http_cache_not_modified_since?(header, last_modified)
        since = http_cache_parse_http_date(header)
        return false unless since

        last_modified.to_i <= since.to_i
      end

      def http_cache_parse_http_date(value)
        Time.httpdate(value.to_s)
      rescue ArgumentError
        nil
      end

      def http_cache_weak_etag(key)
        %(W/"#{Digest::MD5.hexdigest(key.to_s)}")
      end

      # cache_key_with_version (Rails 5.2+) → cache_key → a manual key; a
      # relation/array folds its members' keys (+ size) so a changed collection
      # changes the ETag.
      def http_cache_key_for(resource)
        if resource.respond_to?(:cache_key_with_version)
          resource.cache_key_with_version
        elsif resource.respond_to?(:cache_key)
          resource.cache_key
        elsif resource.is_a?(String)
          resource
        elsif resource.respond_to?(:to_a)
          members = resource.to_a
          "#{members.size}-#{members.map { |member| http_cache_key_for(member) }.join('/')}"
        else
          resource.to_s
        end
      end

      def http_cache_timestamp_for(resource)
        if resource.respond_to?(:updated_at)
          resource.updated_at
        elsif resource.respond_to?(:maximum)
          resource.maximum(:updated_at)
        elsif !resource.is_a?(String) && resource.respond_to?(:map)
          resource.map { |member| member.respond_to?(:updated_at) ? member.updated_at : nil }.compact.max
        end
      end

      def http_cache_action_name
        respond_to?(:action_name) ? action_name.to_s : nil
      end
    end
  end
end
