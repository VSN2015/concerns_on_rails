require "active_support/concern"
require "digest"
require "json"

module ConcernsOnRails
  module Controllers
    # Stripe-style `Idempotency-Key` support for mutating endpoints, with a
    # store-agnostic, injectable backend. The first request with a key executes
    # the action and caches the rendered response; a retry with the same key
    # replays the cached response instead of re-running the action; a concurrent
    # duplicate while the first is still in flight is halted with 409.
    #
    #   class PaymentsController < ApplicationController
    #     include ConcernsOnRails::Controllers::Idempotentable
    #
    #     self.idempotency_store = Rails.cache    # must support #read / #write(expires_in:, unless_exist:) / #delete
    #
    #     idempotent_actions :create, ttl: 24.hours, required: true
    #   end
    #
    # Lifecycle per key (scoped to controller#action, so the same client key on
    # different endpoints never collides):
    #   * claim won  -> action runs; 2xx-4xx responses are cached for `ttl:`;
    #                   5xx responses and raised exceptions release the claim so
    #                   the client can retry.
    #   * done       -> the cached status/body/content type is replayed with
    #                   `X-Idempotency-Replayed: true`.
    #   * in flight  -> 409 with code "idempotency_conflict" and `Retry-After`.
    #   * same key, different request payload -> 422 "idempotency_key_reuse"
    #     (override `idempotency_fingerprint` to customize payload matching).
    #
    # The claim is taken atomically via `write(..., unless_exist: true)`
    # (memcached `add` / Redis `SET NX` through Rails.cache); a store without
    # that atomicity is best-effort under concurrency. There is no in-process
    # default store on purpose — configure one explicitly or the first keyed
    # request raises ArgumentError. Note that responses rendered by
    # `rescue_from` handlers bypass the around filter's success path and are
    # never cached. When combining with Throttleable, include Throttleable
    # first so rate limiting halts before a claim is written.
    module Idempotentable
      extend ActiveSupport::Concern

      DEFAULT_HEADER = "Idempotency-Key".freeze
      MAX_KEY_LENGTH = 255
      IGNORED_FINGERPRINT_KEYS = %w[controller action format].freeze

      included do
        class_attribute :idempotency_rules, instance_accessor: false, default: []
        class_attribute :idempotency_store, instance_accessor: false, default: nil
        around_action :enforce_idempotency
      end

      module ClassMethods
        # Declare idempotent actions. `ttl:` is the cached-response lifetime,
        # `lock_ttl:` the in-flight claim lifetime (kept short so a crashed
        # worker cannot wedge a key), `header:` the request header to read, and
        # `required:` whether a missing key is a 400. Each call appends a rule;
        # the first rule listing the current action wins.
        def idempotent_actions(*actions, ttl: 86_400, lock_ttl: 60, header: DEFAULT_HEADER, required: false)
          actions = actions.flatten.map(&:to_s)
          validate_idempotent!(actions, ttl: ttl, lock_ttl: lock_ttl, header: header, required: required)

          rule = { actions: actions, ttl: ttl.to_i, lock_ttl: lock_ttl.to_i, header: header.to_s, required: required }
          self.idempotency_rules = idempotency_rules + [rule]
        end

        private

        def validate_idempotent!(actions, ttl:, lock_ttl:, header:, required:)
          prefix = "ConcernsOnRails::Controllers::Idempotentable"
          raise ArgumentError, "#{prefix}: pass at least one action" if actions.empty?
          raise ArgumentError, "#{prefix}: :ttl must be a positive duration" unless ttl.to_i.positive?
          raise ArgumentError, "#{prefix}: :lock_ttl must be a positive duration" unless lock_ttl.to_i.positive?
          raise ArgumentError, "#{prefix}: :header must be a non-blank String" if header.to_s.strip.empty?
          raise ArgumentError, "#{prefix}: :required must be true or false" unless [true, false].include?(required)
        end
      end

      # around_action entry point. Public so subclasses can override and specs
      # can drive it directly with a block standing in for the action.
      def enforce_idempotency(&)
        rule = idempotency_rule_for_action
        return yield unless rule

        raw = read_idempotency_header(rule)
        return idempotency_handle_missing_key(rule, &) if raw.nil?

        key = raw.to_s.strip
        unless valid_idempotency_key?(key)
          return idempotency_error_response(message: "#{rule[:header]} is invalid (expected 1-#{MAX_KEY_LENGTH} characters).",
                                            status: :bad_request, code: "idempotency_key_invalid")
        end

        @idempotency_key = key
        run_with_idempotency(rule, key, &)
      end

      # The raw key sent for the matched rule (nil when absent). Handy for logging.
      def idempotency_key
        @idempotency_key
      end

      # Digest of the request payload, used to reject reusing one key for a
      # different request. Public override point — e.g. for raw-body APIs:
      #   def idempotency_fingerprint = Digest::SHA256.hexdigest(request.raw_post)
      def idempotency_fingerprint
        raw = params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
        filtered = raw.reject { |k, _| IGNORED_FINGERPRINT_KEYS.include?(k.to_s) }
        Digest::SHA256.hexdigest(JSON.generate(idempotency_deep_sort(filtered)))
      end

      # Public override point for how a cached response is replayed.
      def replay_idempotent_response(record)
        return unless respond_to?(:response) && response

        emit_idempotency_replayed_header(true)
        options = { body: record["body"], status: record["status"] }
        options[:content_type] = record["content_type"] if record["content_type"]
        render(options)
      end

      # Single funnel for all error outcomes. Uses Respondable's render_error
      # when available, otherwise the same inline envelope as Throttleable.
      def idempotency_error_response(message:, status:, code:)
        return unless respond_to?(:response) && response

        return render_error(message: message, status: status, code: code) if respond_to?(:render_error)

        render json: { success: false, error: { message: message, code: code } }, status: status
      end

      private

      def idempotency_rule_for_action
        action = respond_to?(:action_name) ? action_name.to_s : nil
        return nil unless action

        self.class.idempotency_rules.find { |rule| rule[:actions].include?(action) }
      end

      def idempotency_handle_missing_key(rule, &)
        return yield unless rule[:required]

        idempotency_error_response(message: "#{rule[:header]} header is required for this action.",
                                   status: :bad_request, code: "idempotency_key_missing")
      end

      def valid_idempotency_key?(key)
        !key.empty? && key.length <= MAX_KEY_LENGTH
      end

      def run_with_idempotency(rule, key, &)
        store = idempotency_store!
        cache_key = idempotency_cache_key(key)
        fingerprint = idempotency_fingerprint
        emit_idempotency_key_header(key)

        claim = { "state" => "in_flight", "fingerprint" => fingerprint, "claimed_at" => Time.now.to_i }
        if store.write(cache_key, claim, expires_in: rule[:lock_ttl], unless_exist: true)
          idempotency_execute_and_store(store, cache_key, rule, fingerprint, &)
        else
          idempotency_resolve_existing(store, cache_key, rule, fingerprint)
        end
      end

      def idempotency_execute_and_store(store, cache_key, rule, fingerprint)
        emit_idempotency_replayed_header(false)
        completed = false
        begin
          yield
          completed = true
        ensure
          # Covers raise and throw alike, so a retry can re-execute.
          store.delete(cache_key) unless completed
        end

        status = idempotency_response_status
        return store.delete(cache_key) if status >= 500

        record = { "state" => "done", "status" => status, "body" => idempotency_response_body,
                   "content_type" => idempotency_response_content_type, "fingerprint" => fingerprint }
        store.write(cache_key, record, expires_in: rule[:ttl])
      end

      def idempotency_resolve_existing(store, cache_key, rule, fingerprint)
        record = store.read(cache_key)

        if record && record["fingerprint"] != fingerprint
          return idempotency_error_response(message: "#{rule[:header]} was already used with a different request payload.",
                                            status: :unprocessable_entity, code: "idempotency_key_reuse")
        end

        return replay_idempotent_response(record) if record && record["state"] == "done"

        # In flight — or the claim expired between our failed write and this
        # read (rare); answering 409 is the conservative, retry-safe choice.
        idempotency_conflict_response(rule)
      end

      def idempotency_conflict_response(rule)
        response.set_header("Retry-After", rule[:lock_ttl].to_s) if respond_to?(:response) && response
        idempotency_error_response(message: "A request with this #{rule[:header]} is already in progress.",
                                   status: :conflict, code: "idempotency_conflict")
      end

      def read_idempotency_header(rule)
        return nil unless respond_to?(:request) && request.respond_to?(:headers) && request.headers

        request.headers[rule[:header]]
      end

      def idempotency_cache_key(key)
        # The user key is hashed so any validated key is safe in any backend
        # (memcached limits key length and bans whitespace/control characters).
        "idempotentable:#{idempotency_scope}:#{Digest::SHA256.hexdigest(key)}"
      end

      def idempotency_scope
        controller = respond_to?(:controller_path) ? controller_path : self.class.name || "anonymous"
        action = respond_to?(:action_name) ? action_name.to_s : ""
        "#{controller}##{action}"
      end

      def idempotency_store!
        store = self.class.idempotency_store
        return store if store

        raise ArgumentError,
              "ConcernsOnRails::Controllers::Idempotentable: no store configured. " \
              "Set `self.idempotency_store = Rails.cache` " \
              "(must support #read, #write(expires_in:, unless_exist:) and #delete)."
      end

      def idempotency_response_status
        return 200 unless respond_to?(:response) && response.respond_to?(:status)

        response.status.to_i
      end

      def idempotency_response_body
        return nil unless respond_to?(:response) && response.respond_to?(:body)

        response.body
      end

      def idempotency_response_content_type
        return nil unless respond_to?(:response) && response

        # media_type (real Rails) excludes the charset; the harness only has content_type.
        if response.respond_to?(:media_type) && response.media_type
          response.media_type
        elsif response.respond_to?(:content_type)
          response.content_type
        end
      end

      def emit_idempotency_key_header(key)
        response.set_header("X-Idempotency-Key", key) if respond_to?(:response) && response
      end

      def emit_idempotency_replayed_header(replayed)
        response.set_header("X-Idempotency-Replayed", replayed.to_s) if respond_to?(:response) && response
      end

      # Deterministic JSON regardless of param insertion order: hashes become
      # sorted [key, value] pairs, arrays keep their (significant) order, and
      # non-JSON-primitive leaves are stringified so nothing can raise.
      def idempotency_deep_sort(value)
        case value
        when Hash then value.map { |k, v| [k.to_s, idempotency_deep_sort(v)] }.sort_by(&:first)
        when Array then value.map { |v| idempotency_deep_sort(v) }
        when nil, true, false, Integer, Float, String then value
        else value.to_s
        end
      end
    end
  end
end
