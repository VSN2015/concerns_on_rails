require "spec_helper"
require "support/integration_harness"
require "json"

# Audit 2026-10-29, HTTP-4. The RecordNotDestroyed handler forwarded Rails' raw
# "Failed to destroy <Model> with id=<id>", leaking the model class name and
# primary key to the client -- the very thing the module comment promises never
# reaches a response and the RecordNotFound handler hides.
describe "ErrorHandleable RecordNotDestroyed message" do
  before do
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Schema.define { create_table(:not_destroyed_invoices, force: true) { |t| t.string :name } }
    end
    stub_const("Admin", Module.new)
    stub_const("Admin::NotDestroyedInvoice", Class.new(TestModel) do
      self.table_name = "not_destroyed_invoices"
      before_destroy { throw :abort }
    end)
    stub_const("Admin::ExplainedInvoice", Class.new(TestModel) do
      self.table_name = "not_destroyed_invoices"
      before_destroy do
        errors.add(:base, "Cannot delete an invoice with open payments")
        throw :abort
      end
    end)
  end

  after { ActiveRecord::Base.connection.drop_table(:not_destroyed_invoices, if_exists: true) }

  def dispatch_destroy(model, respondable: false)
    klass = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Respondable if respondable
      include ConcernsOnRails::Controllers::ErrorHandleable

      define_method(:destroy) { model.create!(name: "x").destroy! }
    end
    IntegrationHarness.dispatch(klass, :destroy, method: "DELETE")
  end

  it "renders a generic 422 without the model class name or the id" do
    result = dispatch_destroy(Admin::NotDestroyedInvoice)
    error = JSON.parse(result.body)["error"]

    expect(result.status).to eq(422)
    expect(error).to include("message" => "Resource could not be deleted", "code" => "record_not_destroyed")
    expect(result.body).not_to include("NotDestroyedInvoice")
    expect(result.body).not_to match(/id=\d/)
    expect(error).not_to have_key("details")
  end

  it "does the same through Respondable's render_error" do
    result = dispatch_destroy(Admin::NotDestroyedInvoice, respondable: true)

    expect(result.status).to eq(422)
    expect(JSON.parse(result.body)["error"]["message"]).to eq("Resource could not be deleted")
    expect(result.body).not_to include("NotDestroyedInvoice")
  end

  it "keeps the record's errors.full_messages as details when the veto added any" do
    result = dispatch_destroy(Admin::ExplainedInvoice)
    error = JSON.parse(result.body)["error"]

    expect(error["message"]).to eq("Resource could not be deleted")
    expect(error["details"]).to eq(["Cannot delete an invoice with open payments"])
    expect(result.body).not_to include("ExplainedInvoice")
  end
end
