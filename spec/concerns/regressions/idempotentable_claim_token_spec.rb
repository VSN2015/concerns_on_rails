require "spec_helper"

describe "Idempotentable claim token" do
  class HttpAuditIdemStore
    attr_reader :data

    def initialize
      @data = {}
    end

    def write(key, value, options = {}) # rubocop:disable Naming/PredicateMethod
      return false if options[:unless_exist] && @data.key?(key)

      @data[key] = value
      true
    end

    def read(key)
      @data[key]
    end

    def delete(key)
      @data.delete(key)
    end
  end

  HttpAuditReq = Struct.new(:headers) unless defined?(HttpAuditReq)

  describe "release and DONE write" do
    let(:store) { HttpAuditIdemStore.new }
    let(:klass) do
      s = store
      Class.new(FakeController) do
        def self.around_action(*); end
        include ConcernsOnRails::Controllers::Idempotentable

        self.idempotency_store = s
        idempotent_actions :create
      end
    end

    def build(key: "k-1", params: { amount: 10 })
      c = klass.new(params: params)
      req = HttpAuditReq.new({ "Idempotency-Key" => key })
      c.define_singleton_method(:request) { req }
      c.define_singleton_method(:action_name) { "create" }
      c
    end

    it "a slow request that fails after its claim expired does not delete a newer request's DONE record" do
      runs = 0
      a = build
      a.enforce_idempotency do
        runs += 1
        # A outlives lock_ttl: its claim expires and the client's retry B wins a fresh one and completes.
        store.data.clear
        b = build
        b.enforce_idempotency do
          runs += 1
          b.response.status = 201
          b.response.body = '{"id":2}'
        end
        a.response.status = 500
      end
      expect(runs).to eq(2)

      c = build
      c.enforce_idempotency do
        runs += 1
        c.response.status = 201
      end
      # B's completed result must be replayed; the charge must not run a THIRD time.
      expect(runs).to eq(2)
    end

    it "a slow request that raises after its claim expired does not delete a newer DONE record" do
      runs = 0
      a = build
      expect do
        a.enforce_idempotency do
          runs += 1
          store.data.clear
          b = build
          b.enforce_idempotency do
            runs += 1
            b.response.status = 201
          end
          raise "boom"
        end
      end.to raise_error("boom")

      c = build
      c.enforce_idempotency { runs += 1 }
      expect(runs).to eq(2)
    end

    it "a slow request that succeeds after its claim was taken over does not overwrite the newer DONE record" do
      a = build
      a.enforce_idempotency do
        a.response.status = 200
        a.response.body = "from-a"
        store.data.clear
        b = build
        b.enforce_idempotency do
          b.response.status = 201
          b.response.body = "from-b"
        end
      end

      expect(store.data.values.map { |r| r["body"] }).to eq(["from-b"])
    end

    it "a request whose claim simply expired still writes its DONE record" do
      a = build
      a.enforce_idempotency do
        store.data.clear
        a.response.status = 201
        a.response.body = "from-a"
      end

      expect(store.data.values.map { |r| [r["state"], r["body"]] }).to eq([%w[done from-a]])
    end

    it "a request finishing while a retry is in flight writes its DONE; the retry then failing deletes nothing" do
      runs = 0
      b = build
      retry_request = Fiber.new do
        b.enforce_idempotency do
          runs += 1
          Fiber.yield # B is in flight while A completes
          b.response.status = 500
        end
      end
      a = build
      a.enforce_idempotency do
        runs += 1
        store.data.clear # A's claim expired
        retry_request.resume
        a.response.status = 201
        a.response.body = "from-a"
      end
      retry_request.resume # B fails

      c = build
      c.enforce_idempotency { runs += 1 }
      expect(runs).to eq(2)
      expect(store.data.values.map { |r| [r["state"], r["body"]] }).to eq([%w[done from-a]])
    end
  end
end
