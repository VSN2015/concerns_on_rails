require "spec_helper"
require "support/integration_harness"
require "open3"
require "rbconfig"
require "digest"

# Idempotentable lives in the standalone `idempotentable` gem (its own suite
# covers the behaviour); this pins the concerns_on_rails side: the alias, the
# ConcernsOnRails.setup fallback store, and Respondable integration.
describe ConcernsOnRails::Controllers::Idempotentable do
  around do |example|
    saved = Idempotentable.store
    example.run
  ensure
    Idempotentable.store = saved
  end

  after { ConcernsOnRails.config.cache_store = nil }

  let(:store) { ActiveSupport::Cache::MemoryStore.new }

  let(:base_class) do
    Class.new(FakeController) do
      def self.around_action(*); end
    end
  end

  def fake_controller
    klass = Class.new(base_class) { include ConcernsOnRails::Controllers::Idempotentable }
    klass.new(params: {})
  end

  it "is the standalone gem's module" do
    expect(ConcernsOnRails::Controllers::Idempotentable).to equal(Idempotentable)
  end

  it "registers one around_action when included under both names" do
    controller = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Idempotentable
      include Idempotentable
    end
    expect(controller._process_action_callbacks.count { |cb| cb.filter == :enforce_idempotency }).to eq(1)
  end

  it "uses ConcernsOnRails.setup cache_store as the fallback store" do
    Idempotentable.store = -> { ConcernsOnRails.config.resolved_cache_store }
    controller = fake_controller
    mine = store
    ConcernsOnRails.setup { |c| c.cache_store = -> { mine } }
    expect(controller.send(:idempotency_store!)).to be(mine)
  end

  it "re-reads the setup Proc on every request" do
    Idempotentable.store = -> { ConcernsOnRails.config.resolved_cache_store }
    ConcernsOnRails.setup { |c| c.cache_store = -> { Object.new } }
    controller = fake_controller
    expect(controller.send(:idempotency_store!)).not_to be(controller.send(:idempotency_store!))
  end

  it "raises the no-store ArgumentError when setup holds nothing" do
    Idempotentable.store = -> { ConcernsOnRails.config.resolved_cache_store }
    ConcernsOnRails.config.cache_store = nil
    expect { fake_controller.send(:idempotency_store!) }.to raise_error(ArgumentError, /no store configured/)
  end

  it "lets an explicit Idempotentable.store win over ConcernsOnRails.setup" do
    other = Object.new
    Idempotentable.store = other
    ConcernsOnRails.setup { |c| c.cache_store = -> { Object.new } }
    expect(fake_controller.send(:idempotency_store!)).to be(other)
  end

  it "does not overwrite a store assigned before the bridge loads", :subprocess do
    code = 'require "action_controller"; require "idempotentable"; Idempotentable.store = :mine; ' \
           'require "concerns_on_rails/controllers/idempotentable"; print Idempotentable.store'
    output, status = Open3.capture2(RbConfig.ruby, "-I", File.expand_path("../../../lib", __dir__), "-e", code)
    expect(status).to be_success, output
    expect(output).to eq("mine")
  end

  it "prefixes validation errors with 'Idempotentable:' through the alias" do
    expect do
      Class.new(base_class) do
        include ConcernsOnRails::Controllers::Idempotentable

        idempotent_actions
      end
    end.to raise_error(ArgumentError, /\AIdempotentable: pass at least one action/)
  end

  describe "with Respondable (real ActionController dispatch)" do
    def build(memory)
      IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Respondable
        include ConcernsOnRails::Controllers::Idempotentable

        self.idempotency_store = memory
        respondable_by error_format: :problem_details
        idempotent_actions :create

        define_method(:idempotency_fingerprint) { "fp" }
        define_method(:create) { render_error(message: "nope", status: 422, code: "declined") }
      end
    end

    def post(controller)
      IntegrationHarness.dispatch(controller, :create, method: "POST", headers: { "Idempotency-Key" => "k1" })
    end

    it "replays an RFC 9457 problem document from Respondable with the exact Content-Type" do
      controller = build(store)
      first = post(controller)
      replay = post(controller)
      expect(first.header("Content-Type")).to eq("application/problem+json")
      expect(replay.header("X-Idempotency-Replayed")).to eq("true")
      expect(replay.header("Content-Type")).to eq("application/problem+json")
      expect(replay.body).to eq(first.body)
    end

    it "renders its 409 through a Respondable render_error" do
      controller = build(store)
      cache_key = "idempotentable:integration_harness#create:#{Digest::SHA256.hexdigest('k1')}"
      store.write(cache_key, { "state" => "in_flight", "token" => "x", "claimed_at" => Time.now.to_i,
                               "fingerprint" => "fp" })
      response = post(controller)
      expect(response.status).to eq(409)
      expect(response.body).to include("idempotency_conflict")
    end
  end
end
