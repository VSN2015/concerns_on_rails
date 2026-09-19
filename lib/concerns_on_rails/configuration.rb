module ConcernsOnRails
  # Gem-wide configuration, set once from an initializer:
  #
  #   ConcernsOnRails.setup do |config|
  #     config.cache_store = -> { Rails.cache }
  #   end
  #
  # `cache_store` is the fallback store consulted by Controllers::Throttleable
  # and Controllers::Idempotentable when the controller class hasn't set its
  # own (`self.throttleable_store = ...` / `self.idempotency_store = ...`
  # still win). A store object or a zero-arg callable — prefer a Proc so
  # `Rails.cache` is read lazily, after the framework has booted. The store
  # contract is unchanged: atomic #increment for throttling, #read /
  # #write(expires_in:, unless_exist:) / #delete for idempotency. There is
  # still no in-process default on purpose — a non-atomic store silently
  # under-counts, so the host must opt in explicitly (just once, here).
  #
  # `audit_actor` is the fallback actor for Models::Auditable: a zero-arg
  # callable (a Proc is instance_exec'd on the record at save time, any other
  # callable is #call'd), whose value is stamped as "by" on every audit entry
  # of every model that passes no `actor:` of its own (`auditable_by ...,
  # actor: -> { ... }` still wins; an explicit `actor: nil`/`actor: false`
  # opts a model out). Typically `-> { Current.user&.id }`; nil or false
  # means no gem-wide actor.
  class Configuration
    attr_accessor :cache_store
    attr_reader :audit_actor

    # false is accepted as a synonym for nil ("no gem-wide actor"). A lambda
    # is arity-strict, so one that demands arguments is rejected here rather
    # than raising from inside before_save on every audited save.
    def audit_actor=(value)
      unless value.nil? || value == false || value.respond_to?(:call)
        raise ArgumentError, "ConcernsOnRails.config.audit_actor must be callable (respond to #call), nil or false"
      end
      unless audit_actor_callable_without_args?(value)
        raise ArgumentError,
              "ConcernsOnRails.config.audit_actor lambda must take no arguments (it is instance_exec'd on the record)"
      end

      @audit_actor = value
    end

    # The fallback store with any callable resolved (per lookup, so a Proc
    # reading Rails.cache follows a swapped-out cache in tests). nil when the
    # host never configured one.
    def resolved_cache_store
      cache_store.respond_to?(:call) ? cache_store.call : cache_store
    end

    private

    # Only lambdas enforce arity: 0 (no parameters) and -1 (*args or optional
    # parameters only) can still be called with none. Non-lambda Procs and
    # other callables are left alone.
    def audit_actor_callable_without_args?(value)
      return true unless value.is_a?(Proc) && value.lambda?

      value.arity.zero? || value.arity == -1
    end
  end
end
