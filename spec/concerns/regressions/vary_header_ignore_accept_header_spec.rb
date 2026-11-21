require "spec_helper"
require "support/integration_harness"

# Rails 8.1's _set_vary_header appends request.vary_headers, which honours
# `config.action_dispatch.ignore_accept_header` (only X-Requested-With then).
# VaryHeader seeds what Rails itself would have, so no spurious `Accept`.
RSpec.describe ConcernsOnRails::Support::VaryHeader, "ignore_accept_header" do
  around do |example|
    saved = ActionDispatch::Request.ignore_accept_header
    ActionDispatch::Request.ignore_accept_header = true
    example.run
  ensure
    ActionDispatch::Request.ignore_accept_header = saved
  end

  def vary_of(klass)
    result = IntegrationHarness.dispatch(klass, :show,
                                         headers: { "Accept" => "application/json", "Accept-Language" => "fr" })
    result.header("Vary").to_s.split(",").map(&:strip)
  end

  it "seeds the dimensions Rails itself would add, not a spurious Accept", min_rails: "6.1" do
    klass = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Localizable

      localizable available: %i[en fr], default: :en

      def show
        render json: { ok: true }
      end
    end
    rails_own = IntegrationHarness.build_controller do
      def show
        render json: { ok: true }
      end
    end

    vary = vary_of(klass)
    expect(vary).to include("Accept-Language")
    expect(vary).not_to include("Accept")
    expect(vary - ["Accept-Language"]).to eq(vary_of(rails_own))
  end
end
