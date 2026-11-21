require "spec_helper"
require "active_support/cache"

# idempotency_deep_sort turns a Hash into sorted [key, value] pairs, so a Hash and an Array of
# pairs (or {} and []) produce the SAME fingerprint: a different payload under one key is
# replayed instead of answered 422 idempotency_key_reuse.
describe ConcernsOnRails::Controllers::Idempotentable do
  IdemFingerprintReq = Struct.new(:headers)

  let(:klass) do
    store = ActiveSupport::Cache::MemoryStore.new
    Class.new(FakeController) do
      def self.around_action(*); end
      include ConcernsOnRails::Controllers::Idempotentable

      self.idempotency_store = store
      idempotent_actions :create
    end
  end

  def run(params)
    c = klass.new(params: params)
    r = IdemFingerprintReq.new({ "Idempotency-Key" => "k" })
    c.define_singleton_method(:request) { r }
    c.define_singleton_method(:action_name) { "create" }
    ran = false
    c.enforce_idempotency do
      ran = true
      c.response.status = 201
      c.response.body = "ok"
    end
    [ran, c]
  end

  it "rejects a Hash payload reused as an Array-of-pairs payload" do
    run({ "items" => { "sku" => "A1" } })
    ran, second = run({ "items" => [%w[sku A1]] })
    expect(ran).to be(false)
    expect(second.rendered[:json][:error][:code]).to eq("idempotency_key_reuse")
  end

  it "rejects {} reused as []" do
    run({ "meta" => {} })
    _, second = run({ "meta" => [] })
    expect(second.rendered[:json][:error][:code]).to eq("idempotency_key_reuse")
  end

  it "answers a key with invalid UTF-8 bytes without raising" do
    c = klass.new(params: { "a" => 1 })
    r = IdemFingerprintReq.new({ "Idempotency-Key" => "k\xFF\xFEz".dup.force_encoding("UTF-8") })
    c.define_singleton_method(:request) { r }
    c.define_singleton_method(:action_name) { "create" }
    expect { c.enforce_idempotency { c.response.status = 201 } }.not_to raise_error
  end

  it "still treats identical payloads (any key order, arrays included) as the same request" do
    run({ "b" => [1, { "y" => 1, "x" => 2 }], "a" => {} })
    ran, = run({ "a" => {}, "b" => [1, { "x" => 2, "y" => 1 }] })
    expect(ran).to be(false)
  end
end
