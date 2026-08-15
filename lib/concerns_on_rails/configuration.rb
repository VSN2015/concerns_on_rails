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
  class Configuration
    attr_accessor :cache_store

    # The fallback store with any callable resolved (per lookup, so a Proc
    # reading Rails.cache follows a swapped-out cache in tests). nil when the
    # host never configured one.
    def resolved_cache_store
      cache_store.respond_to?(:call) ? cache_store.call : cache_store
    end
  end
end
