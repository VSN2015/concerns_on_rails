# frozen_string_literal: true

require "spec_helper"
require "openssl"
require "support/integration_harness"

# Audit 2026-11-13, HTTP-3: the replay claim was promoted to replay_ttl for ANY status below 500, so
# a provider retrying a 404/422 ("not synced yet") got 409 webhook_replayed for the whole window and
# the event was lost. Only a 2xx/3xx means the delivery was processed.
describe ConcernsOnRails::Controllers::WebhookVerifiable do
  let(:secret) { "whsec_test" }
  let(:store) do
    Class.new do
      attr_reader :data

      def initialize
        @data = {}
      end

      def write(key, value, options = {})
        return nil if options[:unless_exist] && @data.key?(key)

        @data[key] = value
        true
      end

      def read(key)
        @data[key]
      end

      def delete(key)
        @data.delete(key)
      end
    end.new
  end
  let(:controller) do
    replay_store = store
    wh_secret = secret
    IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::WebhookVerifiable

      verify_webhook :receive, secret: wh_secret, scheme: :hex, header: "X-Sig", replay: replay_store

      def receive
        status = request.headers["X-Status"]
        render json: { ok: status.nil? }, status: (status || 200).to_i
      end
    end
  end

  def deliver(status = nil)
    sig = OpenSSL::HMAC.hexdigest("SHA256", secret, "id=1")
    headers = { "X-Sig" => sig }
    headers["X-Status"] = status.to_s if status
    IntegrationHarness.dispatch(controller, :receive, method: "POST", params: { id: "1" }, headers: headers)
  end

  [404, 422, 429].each do |status|
    it "releases the claim after a #{status}, so the provider's retry is processed" do
      expect(deliver(status).status).to eq(status)
      expect(store.data).to be_empty

      expect(deliver.status).to eq(200)
      expect(deliver.status).to eq(409)
    end
  end

  it "still promotes the claim after a 3xx" do
    expect(deliver(302).status).to eq(302)
    expect(store.data.size).to eq(1)
    expect(deliver.status).to eq(409)
  end
end
