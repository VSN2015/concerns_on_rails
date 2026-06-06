require "spec_helper"

describe ConcernsOnRails::Controllers::Throttleable do
  # Minimal atomic increment-with-expiry store — the contract Throttleable needs.
  # Stands in for Rails.cache / Redis so the suite stays dependency-free.
  class FakeThrottleStore
    def initialize
      @counts = Hash.new(0)
    end

    def increment(key, amount = 1, _options = {})
      @counts[key] += amount
    end

    def write(key, value, _options = {})
      @counts[key] = value
    end

    def read(key)
      @counts[key]
    end
  end

  FakeThrottleRequest = Struct.new(:remote_ip, :headers) unless defined?(FakeThrottleRequest)

  let(:base_class) do
    Class.new(FakeController) do
      def self.before_action(*); end
    end
  end

  let(:store) { FakeThrottleStore.new }

  # Build one controller instance from the given declaration.
  def controller(store:, action: "index", remote_ip: "1.2.3.4", params: {}, &declaration)
    klass = throttled_class(store, &declaration)
    instance(klass, action: action, remote_ip: remote_ip, params: params)
  end

  def throttled_class(store, &declaration)
    Class.new(base_class) do
      include ConcernsOnRails::Controllers::Throttleable

      self.throttleable_store = store

      class_eval(&declaration) if declaration
    end
  end

  def instance(klass, action: "index", remote_ip: "1.2.3.4", params: {})
    c = klass.new(params: params)
    req = FakeThrottleRequest.new(remote_ip, {})
    c.define_singleton_method(:request) { req }
    c.define_singleton_method(:action_name) { action }
    c
  end

  describe "#enforce_throttles" do
    it "allows requests under the limit and counts down X-RateLimit-Remaining" do
      c = controller(store: store) { throttle_by limit: 3, period: 60 }
      c.enforce_throttles

      expect(c.rendered).to be_nil
      expect(c.response.headers["X-RateLimit-Limit"]).to eq("3")
      expect(c.response.headers["X-RateLimit-Remaining"]).to eq("2")
      expect(c.response.headers["X-RateLimit-Reset"]).to match(/\A\d+\z/)
    end

    it "blocks with 429 once the limit is exceeded" do
      klass = throttled_class(store) { throttle_by limit: 2, period: 60 }

      travel_to Time.utc(2026, 1, 1, 12, 0, 0) do
        first  = instance(klass, remote_ip: "9.9.9.9")
        second = instance(klass, remote_ip: "9.9.9.9")
        third  = instance(klass, remote_ip: "9.9.9.9")
        [first, second, third].each(&:enforce_throttles)

        expect(first.rendered).to be_nil
        expect(second.rendered).to be_nil
        expect(third.rendered[:status]).to eq(:too_many_requests)
        expect(third.rendered[:json][:error][:code]).to eq("rate_limited")
        expect(third.response.headers["X-RateLimit-Remaining"]).to eq("0")
        expect(third.response.headers["Retry-After"].to_i).to be > 0
      end
    end

    it "partitions counters by a custom discriminator" do
      klass = throttled_class(store) { throttle_by limit: 1, period: 60, by: -> { params[:user_id] } }

      travel_to Time.utc(2026, 1, 1, 12, 0, 0) do
        alice1 = instance(klass, params: { user_id: "alice" })
        alice2 = instance(klass, params: { user_id: "alice" })
        bob1   = instance(klass, params: { user_id: "bob" })
        [alice1, alice2, bob1].each(&:enforce_throttles)

        expect(alice1.rendered).to be_nil
        expect(alice2.rendered[:status]).to eq(:too_many_requests)
        expect(bob1.rendered).to be_nil
      end
    end

    it "does not count requests for out-of-scope actions (only:)" do
      c = controller(store: store, action: "index") { throttle_by limit: 1, period: 60, only: :create }
      c.enforce_throttles

      expect(c.rendered).to be_nil
      expect(c.response.headers["X-RateLimit-Limit"]).to be_nil
    end

    it "raises when a rule fires with no store configured" do
      klass = Class.new(base_class) do
        include ConcernsOnRails::Controllers::Throttleable

        throttle_by limit: 1, period: 60
      end
      c = instance(klass)

      expect { c.enforce_throttles }.to raise_error(ArgumentError, /no store configured/)
    end
  end

  describe "argument validation" do
    def declare(&block)
      Class.new(base_class) do
        include ConcernsOnRails::Controllers::Throttleable

        class_eval(&block)
      end
    end

    it "rejects a non-positive limit" do
      expect { declare { throttle_by limit: 0, period: 60 } }.to raise_error(ArgumentError, /:limit/)
    end

    it "rejects a non-positive period" do
      expect { declare { throttle_by limit: 5, period: 0 } }.to raise_error(ArgumentError, /:period/)
    end

    it "rejects a non-callable :by" do
      expect { declare { throttle_by limit: 5, period: 60, by: "ip" } }.to raise_error(ArgumentError, /:by must be callable/)
    end

    it "rejects passing both :only and :except" do
      expect do
        declare { throttle_by limit: 5, period: 60, only: :a, except: :b }
      end.to raise_error(ArgumentError, /:only or :except/)
    end
  end
end
