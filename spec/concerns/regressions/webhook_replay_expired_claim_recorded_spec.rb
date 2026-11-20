require "spec_helper"
require "openssl"
require "tmpdir"
require "active_support/cache"
require "active_support/cache/file_store"

# A delivery whose replay claim write loses but whose read-back is nil proceeds WITHOUT a claim,
# so commit_webhook_replay_claim never records it: a duplicate within replay_ttl is accepted.
# Deterministic on Rails' FileStore: an expired entry's file still exists, so `unless_exist` loses,
# and the read then evicts it and answers nil.
describe ConcernsOnRails::Controllers::WebhookVerifiable do
  WebhookReplayReq = Struct.new(:headers, :raw_post)
  body = '{"id":1}'
  sig = OpenSSL::HMAC.hexdigest("SHA256", "s", body)

  it "records a processed delivery even when its claim had to displace an expired entry" do
    Dir.mktmpdir do |dir|
      store = ActiveSupport::Cache::FileStore.new(dir)
      klass = Class.new(FakeController) do
        def self.before_action(*); end
        def self.after_action(*); end
        include ConcernsOnRails::Controllers::WebhookVerifiable
        verify_webhook :receive, secret: "s", scheme: :hex, header: "X-Sig", replay: store
      end
      build = lambda do
        c = klass.new
        r = WebhookReplayReq.new({ "X-Sig" => sig }, body)
        c.define_singleton_method(:request) { r }
        c.define_singleton_method(:action_name) { "receive" }
        c
      end

      t0 = Time.utc(2026, 1, 1, 12)
      travel_to(t0) { build.call.verify_webhook_signature! } # worker crashed: claim never released/committed

      travel_to(t0 + 61) do                                    # provider retry after the 60 s claim lapsed
        retry_delivery = build.call
        retry_delivery.verify_webhook_signature!
        expect(retry_delivery.webhook_verified?).to be(true)
        retry_delivery.response.status = 200
        retry_delivery.send(:commit_webhook_replay_claim)     # processed: must now be recorded for replay_ttl
      end

      travel_to(t0 + 62) do
        duplicate = build.call
        duplicate.verify_webhook_signature!
        expect(duplicate.rendered && duplicate.rendered[:json][:error][:code]).to eq("webhook_replayed")
      end
    end
  end
end
