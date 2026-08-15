require "spec_helper"

RSpec.describe "ConcernsOnRails.setup / Configuration" do
  after { ConcernsOnRails.config.cache_store = nil }

  it "yields and returns the memoized configuration" do
    returned = ConcernsOnRails.setup { |c| c.cache_store = :store }
    expect(returned).to be(ConcernsOnRails.config)
    expect(ConcernsOnRails.config.cache_store).to be(:store)
  end

  it "resolves a callable cache_store per lookup (boot-order safe)" do
    calls = 0
    ConcernsOnRails.setup do |c|
      c.cache_store = lambda do
        calls += 1
        :resolved
      end
    end
    2.times { expect(ConcernsOnRails.config.resolved_cache_store).to be(:resolved) }
    expect(calls).to eq(2)
  end

  it "resolves to nil when nothing is configured" do
    expect(ConcernsOnRails.config.resolved_cache_store).to be_nil
  end

  describe "store fallback wiring" do
    let(:base_class) do
      Class.new(FakeController) do
        def self.before_action(*); end
        def self.around_action(*); end
      end
    end

    # Minimal atomic increment-with-expiry contract (Throttleable's needs).
    let(:store) do
      Class.new do
        def initialize
          @counts = Hash.new(0)
        end

        def increment(key, amount = 1, _options = {})
          @counts[key] += amount
        end
      end.new
    end

    def throttled_instance(klass)
      controller = klass.new(params: {})
      request = Struct.new(:remote_ip, :headers).new("9.9.9.9", {})
      controller.define_singleton_method(:request) { request }
      controller.define_singleton_method(:action_name) { "index" }
      controller
    end

    it "Throttleable falls back to the gem-wide store when the class sets none" do
      ConcernsOnRails.setup { |c| c.cache_store = -> { store } }
      klass = Class.new(base_class) do
        include ConcernsOnRails::Controllers::Throttleable

        throttle_by limit: 1, period: 60
      end

      expect(throttled_instance(klass).enforce_throttles).to be_nil # first hit: allowed
      second = throttled_instance(klass)
      second.enforce_throttles
      expect(second.rendered[:status]).to eq(:too_many_requests)
    end

    it "a class-level store still wins over the fallback" do
      ConcernsOnRails.setup { |c| c.cache_store = -> { :fallback } }
      klass = Class.new(base_class) do
        include ConcernsOnRails::Controllers::Idempotentable

        self.idempotency_store = :explicit
      end
      expect(klass.new(params: {}).send(:idempotency_store!)).to be(:explicit)
    end

    it "Idempotentable falls back to the gem-wide store, and raises with the setup hint when unset" do
      klass = Class.new(base_class) do
        include ConcernsOnRails::Controllers::Idempotentable
      end
      controller = klass.new(params: {})
      expect { controller.send(:idempotency_store!) }
        .to raise_error(ArgumentError, /ConcernsOnRails\.setup/)

      ConcernsOnRails.setup { |c| c.cache_store = -> { store } }
      expect(controller.send(:idempotency_store!)).to be(store)
    end
  end
end
