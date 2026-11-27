require "idempotentable"
require "concerns_on_rails/core"

module ConcernsOnRails
  module Controllers
    # Idempotentable lives in the standalone `idempotentable` gem (a runtime
    # dependency — it was developed here and extracted). This alias keeps the
    # concerns_on_rails include path working unchanged:
    #
    #   include ConcernsOnRails::Controllers::Idempotentable
    #
    # is the same module as `include Idempotentable`. Docs: the gem's README;
    # note validation errors carry the gem's "Idempotentable:" prefix.
    Idempotentable = ::Idempotentable
  end
end

# Make ConcernsOnRails.setup { |c| c.cache_store = ... } the fallback store
# (resolved per request); an app that assigned Idempotentable.store first
# keeps its own.
Idempotentable.store ||= -> { ConcernsOnRails.config.resolved_cache_store }
