require "spec_helper"
require "support/local_cache_remote_store"

# Over Rails.cache with the LocalCache middleware, a claim this request wrote sits in its
# request-local cache. Reading it back after it expired remotely used to evict it with
# delete_entry, deleting the REMOTE key — a retry's DONE record. The ownership read bypasses it.
describe ConcernsOnRails::Controllers::Idempotentable do
  IdemLocalCacheReq = Struct.new(:headers) unless defined?(IdemLocalCacheReq)

  let(:store) { LocalCacheRemoteStore.new }
  let(:klass) do
    s = store
    Class.new(FakeController) do
      def self.around_action(*); end
      include ConcernsOnRails::Controllers::Idempotentable

      self.idempotency_store = s
      idempotent_actions :create, lock_ttl: 1
    end
  end

  def build
    c = klass.new(params: { amount: 10 })
    req = IdemLocalCacheReq.new({ "Idempotency-Key" => "k" })
    c.define_singleton_method(:request) { req }
    c.define_singleton_method(:action_name) { "create" }
    c
  end

  # One request: its own thread, so its own request-local cache.
  def request_in_thread(&block)
    controller = build
    Thread.new { store.with_local_cache { block.call(controller) } }.join
  end

  it "a slow request failing after its claim expired keeps a retry's DONE record" do
    runs = 0
    request_in_thread do |a|
      a.enforce_idempotency do
        runs += 1
        sleep 1.1
        request_in_thread do |b|
          b.enforce_idempotency do
            runs += 1
            b.response.status = 201
            b.response.body = "from-b"
          end
        end
        a.response.status = 500
      end
    end
    request_in_thread { |c| c.enforce_idempotency { runs += 1 } }

    expect(runs).to eq(2)
  end
end
