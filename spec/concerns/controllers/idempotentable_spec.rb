require "spec_helper"

describe ConcernsOnRails::Controllers::Idempotentable do
  # Minimal read/write(unless_exist:)/delete store — the contract Idempotentable
  # needs. Stands in for Rails.cache so the suite stays dependency-free.
  class FakeIdempotencyStore
    attr_reader :data, :writes

    def initialize
      @data = {}
      @writes = []
    end

    # Returns falsey when unless_exist hits an existing key, truthy otherwise —
    # the same contract Rails.cache#write exposes to callers.
    def write(key, value, options = {})
      return if options[:unless_exist] && @data.key?(key)

      @writes << [key, value, options]
      @data[key] = value
    end

    def read(key)
      @data[key]
    end

    def delete(key)
      @data.delete(key)
    end
  end

  IdemFakeRequest = Struct.new(:headers) unless defined?(IdemFakeRequest)

  let(:base_class) do
    Class.new(FakeController) do
      def self.around_action(*); end
    end
  end

  let(:store) { FakeIdempotencyStore.new }

  def idempotent_class(store, &declaration)
    Class.new(base_class) do
      include ConcernsOnRails::Controllers::Idempotentable

      self.idempotency_store = store

      class_eval(&declaration) if declaration
    end
  end

  def instance(klass, action: "create", key: nil, params: {}, header: "Idempotency-Key")
    c = klass.new(params: params)
    req = IdemFakeRequest.new(key.nil? ? {} : { header => key })
    c.define_singleton_method(:request) { req }
    c.define_singleton_method(:action_name) { action }
    c
  end

  # Drive the around hook with a counting action block; returns how many times
  # the "action" ran.
  def perform(controller, status: 201, body: '{"id":1}', content_type: "application/json")
    calls = 0
    controller.enforce_idempotency do
      calls += 1
      controller.response.status = status
      controller.response.body = body
      controller.response.content_type = content_type
    end
    calls
  end

  describe "#enforce_idempotency" do
    it "runs the action untouched when no key is sent and required is false" do
      c = instance(idempotent_class(store) { idempotent_actions :create })

      expect(perform(c)).to eq(1)
      expect(c.rendered).to be_nil
      expect(c.response.headers).not_to have_key("X-Idempotency-Key")
      expect(store.data).to be_empty
    end

    it "does not consult the store when no key engages (no store configured, no raise)" do
      klass = Class.new(base_class) do
        include ConcernsOnRails::Controllers::Idempotentable

        idempotent_actions :create
      end

      expect(perform(instance(klass))).to eq(1)
    end

    it "renders 400 idempotency_key_missing when required and the header is absent" do
      c = instance(idempotent_class(store) { idempotent_actions :create, required: true })

      expect(perform(c)).to eq(0)
      expect(c.rendered[:status]).to eq(:bad_request)
      expect(c.rendered[:json][:error][:code]).to eq("idempotency_key_missing")
    end

    it "renders 400 idempotency_key_invalid for a blank key" do
      c = instance(idempotent_class(store) { idempotent_actions :create }, key: "   ")

      expect(perform(c)).to eq(0)
      expect(c.rendered[:status]).to eq(:bad_request)
      expect(c.rendered[:json][:error][:code]).to eq("idempotency_key_invalid")
    end

    it "renders 400 idempotency_key_invalid for a key longer than 255 characters" do
      c = instance(idempotent_class(store) { idempotent_actions :create }, key: "x" * 256)

      expect(perform(c)).to eq(0)
      expect(c.rendered[:json][:error][:code]).to eq("idempotency_key_invalid")
    end

    it "renders 400 idempotency_key_invalid for keys containing control characters (header-injection guard)" do
      ["k\r\nSet-Cookie: x=1", "k\nv", "k\x00v", "k\tv"].each do |bad|
        c = instance(idempotent_class(store) { idempotent_actions :create }, key: bad)

        expect(perform(c)).to eq(0), "expected rejection for #{bad.inspect}"
        expect(c.rendered[:json][:error][:code]).to eq("idempotency_key_invalid")
        expect(c.response.headers).not_to have_key("X-Idempotency-Key")
      end
      expect(store.data).to be_empty
    end

    it "executes the first request, stores the response and marks it as not replayed" do
      c = instance(idempotent_class(store) { idempotent_actions :create }, key: "abc-123")

      expect(perform(c)).to eq(1)
      expect(c.rendered).to be_nil
      expect(c.idempotency_key).to eq("abc-123")
      expect(c.response.headers["X-Idempotency-Key"]).to eq("abc-123")
      expect(c.response.headers["X-Idempotency-Replayed"]).to eq("false")
      expect(store.data.values.first).to include("state" => "done", "status" => 201,
                                                 "body" => '{"id":1}', "content_type" => "application/json")
    end

    it "writes the claim with lock_ttl and the done record with ttl" do
      klass = idempotent_class(store) { idempotent_actions :create, ttl: 3600, lock_ttl: 30 }
      perform(instance(klass, key: "k1"))

      expect(store.writes[0][1]["state"]).to eq("in_flight")
      expect(store.writes[0][2][:expires_in]).to eq(30)
      expect(store.writes[1][1]["state"]).to eq("done")
      expect(store.writes[1][2][:expires_in]).to eq(3600)
    end

    it "replays the cached response without re-running the action" do
      klass = idempotent_class(store) { idempotent_actions :create }
      expect(perform(instance(klass, key: "abc"))).to eq(1)

      c = instance(klass, key: "abc")
      expect(perform(c, status: 500, body: "should-not-run")).to eq(0)
      expect(c.rendered[:status]).to eq(201)
      expect(c.rendered[:body]).to eq('{"id":1}')
      expect(c.rendered[:content_type]).to eq("application/json")
      expect(c.response.headers["X-Idempotency-Replayed"]).to eq("true")
    end

    it "renders 409 with Retry-After for a concurrent duplicate while in flight" do
      klass = idempotent_class(store) { idempotent_actions :create, lock_ttl: 45 }
      outer = instance(klass, key: "dup")
      inner = instance(klass, key: "dup")

      inner_calls = nil
      outer.enforce_idempotency do
        inner_calls = perform(inner)
        outer.response.status = 201
        outer.response.body = "ok"
      end

      expect(inner_calls).to eq(0)
      expect(inner.rendered[:status]).to eq(:conflict)
      expect(inner.rendered[:json][:error][:code]).to eq("idempotency_conflict")
      expect(inner.response.headers["Retry-After"]).to eq("45")
    end

    it "renders 422 idempotency_key_reuse when a done key is reused with a different payload" do
      klass = idempotent_class(store) { idempotent_actions :create }
      perform(instance(klass, key: "pay-1", params: { amount: 100 }))

      c = instance(klass, key: "pay-1", params: { amount: 999 })
      expect(perform(c)).to eq(0)
      expect(c.rendered[:status]).to eq(:unprocessable_entity)
      expect(c.rendered[:json][:error][:code]).to eq("idempotency_key_reuse")
    end

    it "renders 422 against an in-flight record with a different payload" do
      klass = idempotent_class(store) { idempotent_actions :create }
      outer = instance(klass, key: "dup", params: { amount: 100 })
      inner = instance(klass, key: "dup", params: { amount: 999 })

      inner_calls = nil
      outer.enforce_idempotency do
        inner_calls = perform(inner)
        outer.response.status = 201
      end

      expect(inner_calls).to eq(0)
      expect(inner.rendered[:json][:error][:code]).to eq("idempotency_key_reuse")
    end

    it "does not cache 5xx responses and releases the claim so the client can retry" do
      klass = idempotent_class(store) { idempotent_actions :create }
      expect(perform(instance(klass, key: "err"), status: 503, body: "boom")).to eq(1)
      expect(store.data).to be_empty

      c = instance(klass, key: "err")
      expect(perform(c)).to eq(1)
      expect(c.rendered).to be_nil
    end

    it "releases the claim and re-raises when the action raises" do
      klass = idempotent_class(store) { idempotent_actions :create }

      expect { instance(klass, key: "boom").enforce_idempotency { raise "kaput" } }.to raise_error("kaput")
      expect(store.data).to be_empty
      expect(perform(instance(klass, key: "boom"))).to eq(1)
    end

    it "scopes records by action so the same key works independently per endpoint" do
      klass = idempotent_class(store) { idempotent_actions :create, :update }
      perform(instance(klass, key: "shared", action: "create"))

      c = instance(klass, key: "shared", action: "update")
      expect(perform(c)).to eq(1)
      expect(c.rendered).to be_nil
    end

    it "honors a custom header name" do
      klass = idempotent_class(store) { idempotent_actions :create, header: "X-Client-Token" }
      c = instance(klass, key: "k", header: "X-Client-Token")

      expect(perform(c)).to eq(1)
      expect(c.response.headers["X-Idempotency-Key"]).to eq("k")
    end

    it "ignores actions that are not declared" do
      c = instance(idempotent_class(store) { idempotent_actions :create }, key: "k", action: "update")

      expect(perform(c)).to eq(1)
      expect(c.response.headers).not_to have_key("X-Idempotency-Key")
      expect(store.data).to be_empty
    end

    it "supports multiple idempotent_actions calls with independent options" do
      klass = idempotent_class(store) do
        idempotent_actions :create, lock_ttl: 10
        idempotent_actions :update, lock_ttl: 99
      end
      perform(instance(klass, key: "a", action: "update"))

      expect(store.writes[0][2][:expires_in]).to eq(99)
    end

    it "raises when a key is presented with no store configured" do
      klass = Class.new(base_class) do
        include ConcernsOnRails::Controllers::Idempotentable

        idempotent_actions :create
      end

      expect { perform(instance(klass, key: "k")) }.to raise_error(ArgumentError, /no store configured/)
    end

    it "delegates error rendering to render_error when available" do
      klass = idempotent_class(store) do
        idempotent_actions :create, required: true

        def render_error(message:, status: :unprocessable_entity, code: nil, errors: nil)
          @rendered = { delegated: true, status: status, code: code, message: message, errors: errors }
        end
      end

      c = instance(klass)
      expect(perform(c)).to eq(0)
      expect(c.rendered[:delegated]).to be(true)
      expect(c.rendered[:status]).to eq(:bad_request)
      expect(c.rendered[:code]).to eq("idempotency_key_missing")
    end
  end

  describe "#idempotency_fingerprint" do
    it "is insensitive to param insertion order" do
      klass = idempotent_class(store) { idempotent_actions :create }
      perform(instance(klass, key: "k", params: { a: 1, b: { x: 2, y: 3 } }))

      c = instance(klass, key: "k", params: { b: { y: 3, x: 2 }, a: 1 })
      expect(perform(c)).to eq(0)
      expect(c.rendered[:status]).to eq(201) # replayed, not 422
    end

    it "ignores controller/action/format params" do
      klass = idempotent_class(store) { idempotent_actions :create }
      perform(instance(klass, key: "k", params: { amount: 1, controller: "a", format: "json" }))

      c = instance(klass, key: "k", params: { amount: 1, controller: "b" })
      expect(perform(c)).to eq(0)
      expect(c.rendered[:status]).to eq(201)
    end

    it "does not raise when params contain non-finite floats" do
      c = instance(idempotent_class(store) { idempotent_actions :create }, key: "nan", params: { score: Float::NAN })

      expect { perform(c) }.not_to raise_error
      expect(c.rendered).to be_nil
    end

    it "can be overridden to disable payload-mismatch detection" do
      klass = idempotent_class(store) do
        idempotent_actions :create

        def idempotency_fingerprint
          "constant"
        end
      end
      perform(instance(klass, key: "k", params: { amount: 1 }))

      c = instance(klass, key: "k", params: { amount: 999 })
      expect(perform(c)).to eq(0)
      expect(c.rendered[:status]).to eq(201)
    end
  end

  describe "argument validation" do
    def declare(&block)
      Class.new(base_class) do
        include ConcernsOnRails::Controllers::Idempotentable

        class_eval(&block)
      end
    end

    it "rejects an empty action list" do
      expect { declare { idempotent_actions } }.to raise_error(ArgumentError, /at least one action/)
    end

    it "rejects a non-positive ttl" do
      expect { declare { idempotent_actions :create, ttl: 0 } }.to raise_error(ArgumentError, /:ttl/)
    end

    it "rejects a non-positive lock_ttl" do
      expect { declare { idempotent_actions :create, lock_ttl: 0 } }.to raise_error(ArgumentError, /:lock_ttl/)
    end

    it "rejects a blank header" do
      expect { declare { idempotent_actions :create, header: " " } }.to raise_error(ArgumentError, /:header/)
    end

    it "rejects a non-boolean required" do
      expect { declare { idempotent_actions :create, required: "yes" } }.to raise_error(ArgumentError, /:required/)
    end
  end
end
