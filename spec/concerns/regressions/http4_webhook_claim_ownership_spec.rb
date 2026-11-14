# frozen_string_literal: true

require "spec_helper"
require "openssl"
require "support/integration_harness"

# Audit 2026-11-13, HTTP-4: release_webhook_replay_claim deleted the key unconditionally, so a slow
# first request that failed AFTER its 60 s claim expired deleted the claim a second request had since won.
describe ConcernsOnRails::Controllers::WebhookVerifiable do
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

  it "does not delete a claim another request holds when the first request fails" do
    replay_store = store
    controller = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::WebhookVerifiable

      verify_webhook :receive, secret: "whsec_test", scheme: :hex, header: "X-Sig", replay: replay_store

      define_method(:receive) do
        # our claim expired mid-action and a second delivery won a fresh one
        replay_store.data.each_key { |k| replay_store.data[k] = "someone-else" }
        head :internal_server_error
      end
    end
    sig = OpenSSL::HMAC.hexdigest("SHA256", "whsec_test", "id=1")
    result = IntegrationHarness.dispatch(controller, :receive, method: "POST", params: { id: "1" }, headers: { "X-Sig" => sig })

    expect(result.status).to eq(500)
    expect(store.data.values).to eq(["someone-else"])
  end
end
