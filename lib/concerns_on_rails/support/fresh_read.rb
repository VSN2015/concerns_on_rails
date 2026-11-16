module ConcernsOnRails
  module Support
    # Reads a store key from the store itself, never from Rails' request-local cache.
    # With ActiveSupport::Cache::Strategy::LocalCache active (the LocalCache middleware
    # wraps every request over Rails.cache on Redis/Memcache) a claim this request wrote
    # with `unless_exist:` can sit in that cache; reading it back after its TTL expired
    # remotely evicts the entry via `delete_entry`, which deletes the REMOTE key — a newer
    # request's record. A temporary local store makes the read miss locally and hit the remote.
    module FreshRead
      module_function

      def read(store, key)
        return store.read(key) unless store.respond_to?(:with_local_cache)

        store.with_local_cache { store.read(key) }
      end
    end
  end
end
