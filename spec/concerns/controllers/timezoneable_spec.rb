require "spec_helper"

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
end
