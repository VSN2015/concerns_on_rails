require "spec_helper"
require "openssl"
require "support/integration_harness"
require "support/local_cache_remote_store"

# Same LocalCache hole as Idempotentable's: the ownership read of the replay claim came from the
# request-local cache, so an expired claim was evicted by deleting the REMOTE key a second delivery held.
# Rails 6.0/6.1 never cache an `unless_exist` write locally, so this passes there with or without
# the fix; it guards Rails 7.0+.
describe ConcernsOnRails::Controllers::WebhookVerifiable do
  it "a delivery failing after its claim expired does not delete the claim a second delivery won" do
    store = LocalCacheRemoteStore.new
    stub_const("ConcernsOnRails::Controllers::WebhookVerifiable::REPLAY_CLAIM_TTL", 0.2)
    controller = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::WebhookVerifiable

      verify_webhook :receive, secret: "whsec_test", scheme: :hex, header: "X-Sig", replay: store

      define_method(:receive) do
        sleep 0.3 # our 0.2 s claim lapses; a second delivery (its own request) wins a fresh one
        Thread.new { store.with_local_cache { store.write(store.remote.keys.first, "second", unless_exist: true, expires_in: 60) } }.join
        head :internal_server_error
      end
    end
    sig = OpenSSL::HMAC.hexdigest("SHA256", "whsec_test", "id=1")
    result = store.with_local_cache do
      IntegrationHarness.dispatch(controller, :receive, method: "POST", params: { id: "1" }, headers: { "X-Sig" => sig })
    end

    expect(result.status).to eq(500)
    expect(store.read(store.remote.keys.first)).to eq("second")
  end
end
