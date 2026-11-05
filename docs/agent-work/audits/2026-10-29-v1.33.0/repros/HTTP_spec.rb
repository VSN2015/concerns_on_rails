require "spec_helper"
require "support/integration_harness"
require "json"

# HTTP slice audit, concerns_on_rails v1.33.0. Each example asserts the CORRECT
# behaviour; a failure demonstrates the bug.
describe "HTTP slice audit (v1.33.0)" do
  describe "HTTP-1 Authorizable status: :not_found concealment" do
    it "HTTP-1 renders the same body as ErrorHandleable's missing-record 404 with the default message" do
      concealed = IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Respondable
        include ConcernsOnRails::Controllers::Authorizable
        authorize_by(status: :not_found) { false } # no message: -> default "Forbidden"
        define_method(:show) { render json: { ok: true } }
      end
      missing = IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Respondable
        include ConcernsOnRails::Controllers::ErrorHandleable
        define_method(:show) { raise ActiveRecord::RecordNotFound, "Couldn't find Doc with 'id'=42" }
      end

      a = IntegrationHarness.dispatch(concealed, :show)
      b = IntegrationHarness.dispatch(missing, :show)
      expect(a.status).to eq(404)
      expect(a.body).to eq(b.body) # actual: message "Forbidden" vs "Resource not found"
    end
  end

  describe "HTTP-2 Authorizable require_role with an Array of roles" do
    it "HTTP-2 admits an actor whose role is in an Array passed to require_role" do
      klass = IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Authorizable
        require_role %i[admin editor]
        define_method(:current_user) { Struct.new(:role).new("admin") }
        private :current_user
        define_method(:show) { render json: { ok: true } }
      end
      expect(IntegrationHarness.dispatch(klass, :show).status).to eq(200) # actual: 403
    end
  end

  describe "HTTP-3 Timezoneable Vary on the Time-Zone header source" do
    it "HTTP-3 advertises Vary: Time-Zone when the request header chose the zone (default response_header:)" do
      klass = IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Timezoneable
        timezoneable available: ["UTC", "Tokyo"], default: "UTC"
        define_method(:show) { render json: { zone: Time.zone.name } }
      end
      result = IntegrationHarness.dispatch(klass, :show, headers: { "Time-Zone" => "Asia/Tokyo" })
      expect(JSON.parse(result.body)["zone"]).to eq("Tokyo")
      expect(result.header("Vary").to_s).to include("Time-Zone") # actual: no Vary
    end
  end

  describe "HTTP-4 ErrorHandleable RecordNotDestroyed message" do
    before do
      ActiveRecord::Migration.suppress_messages do
        ActiveRecord::Schema.define { create_table(:http_audit_invoices, force: true) { |t| t.string :name } }
      end
      stub_const("HttpAuditInvoice", Class.new(TestModel) do
        self.table_name = "http_audit_invoices"
        before_destroy { throw :abort }
      end)
    end

    after { ActiveRecord::Base.connection.drop_table(:http_audit_invoices, if_exists: true) }

    it "HTTP-4 does not leak the model class name / id in the 422 body" do
      klass = IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::ErrorHandleable
        define_method(:destroy) { HttpAuditInvoice.create!(name: "x").destroy! }
      end
      result = IntegrationHarness.dispatch(klass, :destroy, method: "DELETE")
      expect(result.status).to eq(422)
      expect(result.body).not_to include("HttpAuditInvoice") # actual: "Failed to destroy HttpAuditInvoice with id=1"
    end
  end
end
