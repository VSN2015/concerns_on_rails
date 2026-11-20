require "spec_helper"
require "support/integration_harness"

# Cacheable writes no_store as a raw Cache-Control header. Rails' merge_and_normalize_cache_control!
# deletes no-store/no-cache from the raw header whenever response.cache_control (the hash every
# Rails helper writes: expires_in, fresh_when(public:), http_cache_forever) is non-empty, so the
# documented "no_store overrides everything" is silently dropped.
RSpec::Matchers.define_negated_matcher :not_match, :match

describe ConcernsOnRails::Controllers::Cacheable do
  it "keeps no-store when a filter/action also used Rails' expires_in" do
    controller = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Cacheable

      http_cache_actions :token, no_store: true
      before_action { expires_in 10.minutes } # e.g. a base-controller default

      def token = render(json: { token: "secret" })
    end
    result = IntegrationHarness.dispatch(controller, :token)
    # Rails 6.0 normalizes a lone raw no-store to "private, no-store"; what matters is that
    # no positive freshness survives next to it.
    expect(result.header("Cache-Control")).to include("no-store").and(not_match(/max-age|public/))
  end
end

describe ConcernsOnRails::Controllers::Cacheable, "no_store after an action-level Rails directive" do
  it "keeps no-store when the action itself calls expires_in / http_cache_forever" do
    controller = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Cacheable

      http_cache_actions :token, no_store: true

      def token
        expires_in 10.minutes, public: true
        render(json: { token: "secret" })
      end
    end
    result = IntegrationHarness.dispatch(controller, :token)
    expect(result.header("Cache-Control")).to include("no-store").and(not_match(/max-age|public/))
  end
end
