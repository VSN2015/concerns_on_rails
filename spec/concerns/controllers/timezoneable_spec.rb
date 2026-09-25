require "spec_helper"
require "support/integration_harness"

describe ConcernsOnRails::Controllers::Timezoneable do
  # A minimal stand-in for ActionDispatch::Request (only #headers is used).
  TZFakeRequest = Struct.new(:headers) unless defined?(TZFakeRequest)

  around do |example|
    saved = Time.zone
    Time.zone = "UTC"
    example.run
  ensure
    Time.zone = saved
  end

  # Build a controller (FakeController has no callback machinery, so stub
  # around_action) with the given timezoneable declaration; optionally attach a
  # fake request carrying a Time-Zone header and/or a cookies hash.
  def controller(time_zone_header: nil, cookies: nil, params: {}, &declaration)
    request = time_zone_header && TZFakeRequest.new({ "Time-Zone" => time_zone_header })
    klass = Class.new(FakeController) do
      def self.around_action(*); end
      include ConcernsOnRails::Controllers::Timezoneable

      class_eval(&declaration) if declaration
      define_method(:request) { request }
    end
    c = klass.new(params: params)
    c.define_singleton_method(:cookies) { cookies } if cookies
    c
  end

  describe "#resolved_time_zone" do
    it "picks an allowed zone from params" do
      c = controller(params: { time_zone: "Eastern Time (US & Canada)" }) do
        timezoneable available: ["UTC", "Eastern Time (US & Canada)"], default: "UTC"
      end
      expect(c.resolved_time_zone.name).to eq("Eastern Time (US & Canada)")
    end

    it "falls back to the default when the param is not allowed" do
      c = controller(params: { time_zone: "Mars" }) do
        timezoneable available: ["UTC", "Eastern Time (US & Canada)"], default: "UTC"
      end
      expect(c.resolved_time_zone.name).to eq("UTC")
    end

    it "reads the Time-Zone header when no param is present" do
      c = controller(time_zone_header: "London") do
        timezoneable available: %w[UTC London], default: "UTC"
      end
      expect(c.resolved_time_zone.name).to eq("London")
    end

    it "ignores the header when header: false" do
      c = controller(time_zone_header: "London") do
        timezoneable available: %w[UTC London], default: "UTC", header: false
      end
      expect(c.resolved_time_zone.name).to eq("UTC")
    end

    it "honors a custom param name" do
      c = controller(params: { tz: "London" }) do
        timezoneable available: %w[UTC London], default: "UTC", param: :tz
      end
      expect(c.resolved_time_zone.name).to eq("London")
    end

    it "reads a cookie when cookie: is enabled" do
      c = controller(cookies: { time_zone: "London" }) do
        timezoneable available: %w[UTC London], default: "UTC", header: false, cookie: true
      end
      expect(c.resolved_time_zone.name).to eq("London")
    end

    it "falls back to the current Time.zone when nothing resolves" do
      c = controller { timezoneable available: %w[UTC London] }
      expect(c.resolved_time_zone.name).to eq("UTC")
    end
  end

  describe "#switch_time_zone" do
    it "runs the block under the resolved zone and restores afterwards" do
      c = controller(params: { time_zone: "London" }) do
        timezoneable available: %w[UTC London], default: "UTC"
      end

      inside = c.switch_time_zone { Time.zone.name }
      expect(inside).to eq("London")
      expect(Time.zone.name).to eq("UTC") # restored
    end
  end

  describe "configuration validation" do
    it "raises on an unknown available zone" do
      expect do
        controller { timezoneable available: %w[UTC Pluto] }
      end.to raise_error(ArgumentError, /unknown time zone/)
    end

    it "raises on an unknown default zone" do
      expect do
        controller { timezoneable default: "Pluto" }
      end.to raise_error(ArgumentError, /unknown time zone/)
    end
  end

  describe "persist:, response_header: and #time_zone_source" do
    it "persists a zone chosen via params into the cookie — and only a param-sourced zone" do
      jar = {}
      c = controller(params: { time_zone: "London" }, cookies: jar) { timezoneable cookie: :time_zone, persist: true }
      c.switch_time_zone { :ran }
      expect(jar[:time_zone]).to include(value: "London")
      # Resolved to an absolute time HERE, not left as a Duration for the jar:
      # only Rails 5.2+ coerces one, and the gemspec supports 5.0.
      expect(jar[:time_zone][:expires]).to be_within(5.seconds).of(1.year.from_now)
      # …and the declared options survive it, so the next request re-resolves.
      expect(c.class.timezoneable_options[:persist][:expires]).to eq(1.year)

      from_header = {}
      controller(time_zone_header: "London", cookies: from_header) { timezoneable cookie: :time_zone, persist: true }
        .switch_time_zone { :ran }
      expect(from_header).to be_empty

      from_cookie = { time_zone: "London" }
      controller(cookies: from_cookie) { timezoneable cookie: :time_zone, persist: true }.switch_time_zone { :ran }
      expect(from_cookie[:time_zone]).to eq("London") # not rewritten
    end

    it "takes cookie options through persist: and requires cookie:" do
      jar = {}
      c = controller(params: { tz: "London" }, cookies: jar) do
        timezoneable param: :tz, cookie: :zone, persist: { expires: 30.days, same_site: :lax, secure: true }
      end
      c.switch_time_zone { :ran }
      expect(jar[:zone]).to include(value: "London", same_site: :lax, secure: true)
      expect(jar[:zone][:expires]).to be_within(5.seconds).of(30.days.from_now)

      expect { controller { timezoneable persist: true } }
        .to raise_error(ArgumentError, /persist: requires cookie:/)
    end

    it "emits the resolved zone in a response header on request, appending Vary when the header source is on" do
      c = controller(params: { time_zone: "London" }) { timezoneable response_header: true }
      c.switch_time_zone { :ran }
      expect(c.response.headers["X-Time-Zone"]).to eq("London")
      expect(c.response.headers["Vary"]).to eq("Time-Zone")

      c = controller(params: { time_zone: "London" }) { timezoneable response_header: "X-Tz", header: false }
      c.response.set_header("Vary", "Accept")
      c.switch_time_zone { :ran }
      expect(c.response.headers["X-Tz"]).to eq("London")
      expect(c.response.headers["Vary"]).to eq("Accept") # header source off → nothing to vary on

      c = controller(time_zone_header: "London") { timezoneable response_header: true }
      c.response.set_header("Vary", "Accept, time-zone")
      c.switch_time_zone { :ran }
      expect(c.response.headers["Vary"]).to eq("Accept, time-zone") # already present, case-insensitively

      c = controller(params: { time_zone: "London" }) { timezoneable }
      c.switch_time_zone { :ran }
      expect(c.response.headers).not_to have_key("X-Time-Zone") # off by default
    end

    it "leaves a Vary: * response alone — it already outranks every named dimension" do
      c = controller(time_zone_header: "London") { timezoneable response_header: true }
      c.response.set_header("Vary", "*")
      c.switch_time_zone { :ran }
      expect(c.response.headers["Vary"]).to eq("*")
    end

    # min_rails 6.1: Rails only learned to set its own `Vary: Accept` during
    # render in 6.1 (ActionController::Rendering#_set_vary_header). Support::VaryHeader
    # deliberately mirrors that — it seeds Accept only when
    # `request.should_apply_vary_header?` exists and says so — so on 6.0 there
    # is no Accept to preserve and nothing to assert.
    it "keeps Rails' own Vary: Accept on a real content-negotiated response", min_rails: "6.1" do
      # Rails adds Vary: Accept during render, but only while the header is
      # still blank (ActionController::Rendering#_set_vary_header), so writing
      # ours before the action would silently drop that cache dimension and a
      # shared cache could serve a JSON body to an HTML request. Only a real
      # dispatch can catch it.
      klass = IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Timezoneable

        timezoneable default: "UTC", response_header: true

        def show
          render json: { ok: true }
        end
      end

      result = IntegrationHarness.dispatch(klass, :show,
                                           headers: { "Accept" => "application/json", "Time-Zone" => "London" })
      expect(result.header("Vary").to_s.split(",").map(&:strip)).to include("Accept", "Time-Zone")
      expect(result.header("X-Time-Zone")).to eq("London")
    end

    # rescue_from handlers run after the around_action has unwound, so a
    # handler rendering a timestamp (or a 4xx body built from Time.zone.now)
    # used the app's zone while X-Time-Zone announced the client's.
    describe "responses rendered by rescue_from" do
      let(:klass) do
        IntegrationHarness.build_controller do
          include ConcernsOnRails::Controllers::Timezoneable

          timezoneable available: %w[UTC London Tokyo], default: "UTC", response_header: true

          rescue_from(ArgumentError) { |_e| render json: { zone: Time.zone.name }, status: :unprocessable_entity }
          rescue_from(IndexError) { |_e| raise "handler exploded" }

          def fail_arg
            raise ArgumentError, "boom"
          end

          def fail_handler
            raise IndexError, "boom"
          end

          def show
            render json: { zone: Time.zone.name }
          end
        end
      end

      it "renders under the resolved zone, and restores the ambient zone afterwards" do
        result = IntegrationHarness.dispatch(klass, :fail_arg, headers: { "Time-Zone" => "Tokyo" })

        expect(result.status).to eq(422)
        expect(JSON.parse(result.body)).to eq("zone" => "Tokyo")
        expect(result.header("X-Time-Zone")).to eq("Tokyo")
        expect(Time.zone.name).to eq("UTC")
      end

      it "restores the ambient zone even when the handler itself raises" do
        expect do
          IntegrationHarness.dispatch(klass, :fail_handler, query: "time_zone=London")
        end.to raise_error(RuntimeError, "handler exploded")
        expect(Time.zone.name).to eq("UTC")
      end

      it "never leaks the zone into the next request on the thread" do
        IntegrationHarness.dispatch(klass, :fail_arg, headers: { "Time-Zone" => "Tokyo" })
        result = IntegrationHarness.dispatch(klass, :show)

        expect(JSON.parse(result.body)).to eq("zone" => "UTC")
      end
    end

    it "reports which source won through time_zone_source" do
      expect(controller(params: { time_zone: "London" }) { timezoneable }.time_zone_source).to eq(:param)
      expect(controller(time_zone_header: "London") { timezoneable }.time_zone_source).to eq(:header)
      expect(controller(cookies: { time_zone: "London" }) { timezoneable cookie: true }.time_zone_source).to eq(:cookie)
      expect(controller { timezoneable default: "London" }.time_zone_source).to eq(:default)
      expect(controller { timezoneable }.time_zone_source).to eq(:current)
      expect(controller(params: { time_zone: "Mars" }) { timezoneable }.time_zone_source).to eq(:current)
    end
  end
end
