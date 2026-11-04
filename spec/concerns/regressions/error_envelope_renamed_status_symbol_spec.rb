require "spec_helper"
require "support/integration_harness"
require "json"

# Audit 2026-10-29, HTTP-5. On Rails 7.1-8.0 with Rack >= 3.1 (no Rails 8.1
# rewrite of the renamed symbols), `render json:, status: :unprocessable_entity`
# goes through Rack::Utils.status_code, which logs "Status code
# :unprocessable_entity is deprecated" on EVERY 422. Only Respondable's
# problem-details branch normalized the symbol (problem_status_code); the
# envelope branch and ErrorEnvelope's inline branch passed it through.
describe "Error envelope status symbols" do
  let(:envelope) { ConcernsOnRails::Support::ErrorEnvelope }

  # What `render` was handed must be something the running Rack lists without
  # a deprecation: an Integer, or a symbol that is a key of SYMBOL_TO_STATUS_CODE.
  def rack_clean?(status)
    status.is_a?(Integer) || Rack::Utils::SYMBOL_TO_STATUS_CODE.key?(status)
  end

  describe ".renderable_status" do
    it "renames the Rack 3.1+ renamed symbols and leaves every other status alone" do
      # A Rack 3.1+-shaped table, so the example reads the same on every Rack line.
      stub_const("Rack::Utils::SYMBOL_TO_STATUS_CODE",
                 { bad_request: 400, not_found: 404, conflict: 409, unprocessable_content: 422,
                   content_too_large: 413, uri_too_long: 414 }.freeze)

      expect(envelope.renderable_status(:unprocessable_entity)).to eq(:unprocessable_content)
      expect(envelope.renderable_status(:payload_too_large)).to eq(:content_too_large)
      expect(envelope.renderable_status(:request_entity_too_large)).to eq(:content_too_large)
      expect(envelope.renderable_status(:request_uri_too_long)).to eq(:uri_too_long)
      [:bad_request, :conflict, :not_found, 422, "422", :unprocessable_content].each do |status|
        expect(envelope.renderable_status(status)).to eq(status)
      end
    end

    it "keeps the old symbol while the running Rack still lists it (Rack < 3.1 would raise on the new name)" do
      stub_const("Rack::Utils::SYMBOL_TO_STATUS_CODE", { unprocessable_entity: 422, bad_request: 400 }.freeze)

      expect(envelope.renderable_status(:unprocessable_entity)).to eq(:unprocessable_entity)
    end
  end

  describe "the status handed to render (FakeController)" do
    let(:fake) do
      Class.new(FakeController) { include ConcernsOnRails::Controllers::Respondable }
    end

    it "is Rack-clean from Respondable#render_error's envelope branch, default and explicit" do
      c = fake.new
      c.render_error(message: "nope")
      expect(rack_clean?(c.rendered[:status])).to be(true)

      c.render_error(message: "nope", status: :unprocessable_entity)
      expect(rack_clean?(c.rendered[:status])).to be(true)
      c.render_error(message: "nope", status: :payload_too_large)
      expect(rack_clean?(c.rendered[:status])).to be(true)
    end

    it "is Rack-clean from ErrorEnvelope's inline branch (no render_error on the controller)" do
      c = FakeController.new
      envelope.render(c, message: "nope", status: :unprocessable_entity, code: "x")

      expect(rack_clean?(c.rendered[:status])).to be(true)
      expect(c.rendered[:json]).to eq(success: false, error: { message: "nope", code: "x" })
    end

    it "leaves statuses that were never renamed exactly as given" do
      c = fake.new
      c.render_error(message: "nope", status: :bad_request)
      expect(c.rendered[:status]).to eq(:bad_request)
      c.render_error(message: "nope", status: 409)
      expect(c.rendered[:status]).to eq(409)
    end
  end

  it "answers 422 and hands render a Rack-clean status on every error path (envelope, inline, ErrorHandleable, Authorizable)" do
    statuses = []
    allow_any_instance_of(ActionController::Base).to receive(:render).and_wrap_original do |original, *args, **kwargs|
      statuses << kwargs[:status]
      original.call(*args, **kwargs)
    end

    envelope_klass = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Respondable
      include ConcernsOnRails::Controllers::ErrorHandleable

      define_method(:token) { raise ActionController::InvalidAuthenticityToken }
      define_method(:invalid) { render_invalid(ActiveModel::Errors.new(Object.new)) }
    end
    inline_klass = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::ErrorHandleable

      define_method(:token) { raise ActionController::InvalidAuthenticityToken }
      define_method(:missing) { raise ActiveRecord::RecordNotFound }
    end
    denied_klass = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Authorizable

      authorize_by(status: :unprocessable_entity) { false }
      define_method(:show) { render json: {} }
    end

    results = [
      IntegrationHarness.dispatch(envelope_klass, :token),
      IntegrationHarness.dispatch(envelope_klass, :invalid),
      IntegrationHarness.dispatch(inline_klass, :token),
      IntegrationHarness.dispatch(denied_klass, :show)
    ]

    expect(results.map(&:status)).to eq([422, 422, 422, 422])
    expect(statuses.size).to eq(4)
    expect(statuses.map { |status| rack_clean?(status) }).to all(be(true))
    expect(IntegrationHarness.dispatch(inline_klass, :missing).status).to eq(404)
  end
end
