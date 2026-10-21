require "spec_helper"
require "support/integration_harness"
require "json"

# Audit 2026-10-09, HTTP-7. switch_time_zone skipped Time.use_zone when the
# resolved zone already equalled Time.zone -- with nothing configured, a
# default equal to the app's zone, or a client naming the current zone. Then
# nothing put Time.zone back, so a `Time.zone = ...` inside the action (the
# per-user idiom the concern replaces, or a gem doing it) leaked to the next
# request served by that thread, and became the :current fallback for other
# users. Whether the zone leaked depended on what the client sent.
describe "Timezoneable restores the ambient Time.zone" do
  around { |example| Time.use_zone("UTC") { example.run } }

  def build(&block)
    IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Timezoneable

      timezoneable default: "UTC"
      class_eval(&block) if block
    end
  end

  let(:reassigning) do
    build do
      def show
        Time.zone = "Tokyo"
        render json: { zone: Time.zone.name }
      end
    end
  end

  it "restores Time.zone after an action when the request resolves to the zone already current" do
    result = IntegrationHarness.dispatch(reassigning, :show)

    expect(JSON.parse(result.body)["zone"]).to eq("Tokyo")
    expect(Time.zone.name).to eq("UTC")
  end

  it "restores it when the client names the current zone itself" do
    IntegrationHarness.dispatch(reassigning, :show, headers: { "Time-Zone" => "UTC" })

    expect(Time.zone.name).to eq("UTC")
  end

  it "restores it when nothing is configured at all" do
    bare = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Timezoneable

      def show
        Time.zone = "Tokyo"
        head :ok
      end
    end

    IntegrationHarness.dispatch(bare, :show)

    expect(Time.zone.name).to eq("UTC")
  end

  it "restores it when the request resolves to a different zone, as before" do
    IntegrationHarness.dispatch(reassigning, :show, headers: { "Time-Zone" => "London" })

    expect(Time.zone.name).to eq("UTC")
  end

  it "runs the action under the resolved zone" do
    reader = build do
      def show
        render json: { zone: Time.zone.name }
      end
    end

    expect(JSON.parse(IntegrationHarness.dispatch(reader, :show).body)["zone"]).to eq("UTC")
    expect(JSON.parse(IntegrationHarness.dispatch(reader, :show, headers: { "Time-Zone" => "London" }).body)["zone"])
      .to eq("London")
  end

  context "when the action raises into a rescue_from handler" do
    let(:failing) do
      build do
        rescue_from(ArgumentError) { render json: { zone: Time.zone.name }, status: :unprocessable_entity }

        def show
          Time.zone = "Tokyo"
          raise ArgumentError, "boom"
        end
      end
    end

    it "renders the handler under the request's zone and then restores the ambient one" do
      result = IntegrationHarness.dispatch(failing, :show)

      expect(result.status).to eq(422)
      expect(JSON.parse(result.body)["zone"]).to eq("UTC")
      expect(Time.zone.name).to eq("UTC")
    end

    it "does the same for a request that resolved to a different zone" do
      result = IntegrationHarness.dispatch(failing, :show, headers: { "Time-Zone" => "London" })

      expect(JSON.parse(result.body)["zone"]).to eq("London")
      expect(Time.zone.name).to eq("UTC")
    end
  end
end
