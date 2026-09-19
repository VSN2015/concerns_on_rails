require "spec_helper"
require "support/integration_harness"

# ActionController declares #cookies PRIVATE, so `respond_to?(:cookies)` is
# false on a real ActionController::Base. Both of Timezoneable's cookie paths
# were guarded on the public form, which silently disabled them in every real
# Rails app while the FakeController harness — whose `cookies` is a public
# Hash — reported them working. Only a real dispatch can catch that.
RSpec.describe "Timezoneable cookies through real ActionController dispatch" do
  def controller_class(**options)
    IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Timezoneable

      timezoneable(**options)

      define_method(:show) do
        render plain: "#{Time.zone.name}|#{time_zone_source}"
      end
    end
  end

  it "writes the chosen zone to the cookie so the picker sticks" do
    klass = controller_class(cookie: :time_zone, persist: true)
    result = IntegrationHarness.dispatch_with_cookies(klass, :show, query: "time_zone=London")

    expect(result.body).to eq("London|param")
    expect(result.header("Set-Cookie").to_s).to include("time_zone=")
    expect(result.header("Set-Cookie").to_s).to include("London")
  end

  it "reads the zone back from the cookie on the next request" do
    klass = controller_class(cookie: :time_zone, persist: true)
    result = IntegrationHarness.dispatch_with_cookies(klass, :show, cookie: "time_zone=Europe%2FLondon")

    expect(result.body).to eq("Europe/London|cookie")
  end

  it "ignores an unknown zone in the cookie rather than raising" do
    klass = controller_class(cookie: :time_zone)
    result = IntegrationHarness.dispatch_with_cookies(klass, :show, cookie: "time_zone=Mars")

    expect(result.status).to eq(200)
    expect(result.body).to end_with("|current")
  end
end
