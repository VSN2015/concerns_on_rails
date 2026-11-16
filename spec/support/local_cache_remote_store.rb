require "active_support/cache"
require "active_support/cache/strategy/local_cache"

# A memcached/redis-like store (TTL honoured server-side, `unless_exist` = add) wearing Rails'
# request-local cache, as Rails.cache is inside a request. `remote` is the shared server;
# each request wraps itself in `with_local_cache` (the LocalCache middleware). Works on 6.0-8.1.
class LocalCacheRemoteStore < ActiveSupport::Cache::Store
  prepend ActiveSupport::Cache::Strategy::LocalCache

  attr_reader :remote

  def initialize(*)
    super
    @remote = {}
  end

  def self.supports_cache_versioning? = true

  private

  def remote_payload(key)
    payload, expires_at = @remote[key]
    return nil if payload.nil? || (expires_at && Time.now.to_f >= expires_at)

    payload
  end

  def remote_put(key, payload, unless_exist, expires_in) # rubocop:disable Naming/PredicateMethod
    return false if unless_exist && remote_payload(key)

    @remote[key] = [payload, expires_in && (Time.now.to_f + expires_in.to_f)]
    true
  end

  # LocalCache sits on read_serialized_entry/write_serialized_entry (7.1+) or on read_entry/write_entry
  # (6.0-7.0). Route the entry methods through the serialized pair so either layering is exercised.
  def read_entry(key, **)
    payload = read_serialized_entry(key, **)
    return nil unless payload

    respond_to?(:deserialize_entry, true) ? deserialize_entry(payload) : Marshal.load(payload) # rubocop:disable Security/MarshalLoad
  end

  def write_entry(key, entry, **)
    payload = respond_to?(:serialize_entry, true) ? serialize_entry(entry, **) : Marshal.dump(entry)
    write_serialized_entry(key, payload, **)
  end

  def read_serialized_entry(key, **) = remote_payload(key)

  def write_serialized_entry(key, payload, unless_exist: false, expires_in: nil, **)
    remote_put(key, payload, unless_exist, expires_in)
  end

  def delete_entry(key, **) = !@remote.delete(key).nil? # rubocop:disable Naming/PredicateMethod
end
