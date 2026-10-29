require "spec_helper"
require "support/integration_harness"
require "json"

# Audit 2026-10-29, HTTP-3. `Vary: Time-Zone` was appended only inside the
# optional X-Time-Zone response-header path (`response_header:`, default off),
# so with the default `timezoneable available:, default:` the body followed the
# client's Time-Zone request header while the response carried no Vary, and a
# CDN would serve the Tokyo rendering to a UTC client. Vary now follows the
# header SOURCE, through its own `vary:` option (default true), exactly like
# Localizable's `response_headers:`.
describe "Timezoneable Vary on the Time-Zone request header" do
  def zone_controller(**options)
    IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Timezoneable

      timezoneable(available: %w[UTC Tokyo], default: "UTC", **options)
      define_method(:show) { render json: { zone: Time.zone.name } }
    end
  end

  def vary_of(result)
    result.header("Vary").to_s.split(",").map(&:strip)
  end

  it "advertises Vary: Time-Zone by default (response_header: off) and still renders in the header's zone" do
    result = IntegrationHarness.dispatch(zone_controller, :show, headers: { "Time-Zone" => "Asia/Tokyo" })

    expect(JSON.parse(result.body)["zone"]).to eq("Tokyo")
    expect(vary_of(result)).to include("Time-Zone")
    expect(result.header("X-Time-Zone")).to be_nil
  end

  it "advertises it when the request carries no Time-Zone header at all (the response still varies on it)" do
    expect(vary_of(IntegrationHarness.dispatch(zone_controller, :show))).to include("Time-Zone")
  end

  it "advertises it once with response_header: on as well" do
    result = IntegrationHarness.dispatch(zone_controller(response_header: true), :show,
                                         headers: { "Time-Zone" => "Asia/Tokyo" })

    expect(vary_of(result).count { |dimension| dimension.casecmp?("Time-Zone") }).to eq(1)
    expect(result.header("X-Time-Zone")).to eq("Tokyo")
  end

  it "keeps Rails' own Vary: Accept alongside it", min_rails: "6.1" do
    result = IntegrationHarness.dispatch(zone_controller, :show,
                                         headers: { "Accept" => "application/json", "Time-Zone" => "Asia/Tokyo" })

    expect(vary_of(result)).to include("Accept", "Time-Zone")
  end

  it "opts out with vary: false" do
    result = IntegrationHarness.dispatch(zone_controller(vary: false), :show, headers: { "Time-Zone" => "Asia/Tokyo" })

    expect(vary_of(result)).not_to include("Time-Zone")
  end

  it "advertises Vary: Cookie (not Time-Zone) when only the cookie source is on" do
    result = IntegrationHarness.dispatch(zone_controller(header: false, cookie: true), :show,
                                         headers: { "Time-Zone" => "Asia/Tokyo", "Cookie" => "time_zone=Tokyo" })

    expect(JSON.parse(result.body)["zone"]).to eq("Tokyo")
    expect(vary_of(result)).to include("Cookie")
    expect(vary_of(result)).not_to include("Time-Zone")
  end

  it "advertises both dimensions with header and cookie sources on, and neither with vary: false" do
    both = IntegrationHarness.dispatch(zone_controller(cookie: true), :show)
    expect(vary_of(both)).to include("Time-Zone", "Cookie")

    off = IntegrationHarness.dispatch(zone_controller(cookie: true, vary: false), :show)
    expect(vary_of(off)).not_to include("Time-Zone")
    expect(vary_of(off)).not_to include("Cookie")
  end

  it "writes no Vary when neither the header nor the cookie source is on (param only)" do
    result = IntegrationHarness.dispatch(zone_controller(header: false), :show, query: "time_zone=Tokyo")

    expect(JSON.parse(result.body)["zone"]).to eq("Tokyo")
    expect(vary_of(result)).not_to include("Time-Zone")
    expect(vary_of(result)).not_to include("Cookie")
  end

  it "keeps vary: false from suppressing the X-Time-Zone response header" do
    result = IntegrationHarness.dispatch(zone_controller(vary: false, response_header: true), :show,
                                         headers: { "Time-Zone" => "Asia/Tokyo" })

    expect(result.header("X-Time-Zone")).to eq("Tokyo")
    expect(vary_of(result)).not_to include("Time-Zone")
  end

  it "leaves a Vary: * response alone and appends to an existing Vary" do
    star = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Timezoneable

      timezoneable default: "UTC"
      define_method(:show) { render json: {} }
      # prepend: it must run BEFORE switch_time_zone (an around_action registered
      # at include time) for the Vary: * guard to be exercised at all.
      prepend_before_action { response.set_header("Vary", "*") }
    end
    expect(IntegrationHarness.dispatch(star, :show).header("Vary")).to eq("*")

    # A Vary written by an earlier before_action: the dimension is appended, not clobbered.
    other = IntegrationHarness.build_controller do
      prepend_before_action { response.set_header("Vary", "Origin") }
      include ConcernsOnRails::Controllers::Timezoneable

      timezoneable default: "UTC"
      define_method(:show) { render json: {} }
    end
    expect(vary_of(IntegrationHarness.dispatch(other, :show))).to include("Origin", "Time-Zone")
  end

  it "still carries Vary: Time-Zone on a rescue_from-rendered error" do
    klass = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Timezoneable
      include ConcernsOnRails::Controllers::ErrorHandleable

      timezoneable default: "UTC"
      define_method(:show) { raise ActiveRecord::RecordNotFound }
    end
    result = IntegrationHarness.dispatch(klass, :show, headers: { "Time-Zone" => "Asia/Tokyo" })

    expect(result.status).to eq(404)
    expect(vary_of(result)).to include("Time-Zone")
  end

  it "de-duplicates next to Localizable: Accept-Language and Time-Zone, each once" do
    klass = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Localizable
      include ConcernsOnRails::Controllers::Timezoneable

      localizable available: %i[en fr], default: :en
      timezoneable default: "UTC"
      define_method(:show) { render json: {} }
    end
    result = IntegrationHarness.dispatch(klass, :show, headers: { "Accept-Language" => "fr", "Time-Zone" => "Asia/Tokyo" })
    dimensions = vary_of(result).map(&:downcase)

    expect(dimensions.count("accept-language")).to eq(1)
    expect(dimensions.count("time-zone")).to eq(1)
  end
end
