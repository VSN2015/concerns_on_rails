require "spec_helper"
require "support/integration_harness"
require "json"

# Audit 2026-11-13, HTTP-1: handle_record_not_saved rendered error.message verbatim,
# leaking the model class, id and gem module path (the RecordNotDestroyed leak, left open here).
describe "HTTP-1 ErrorHandleable RecordNotSaved message" do
  before do
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Schema.define do
        create_table(:http_audit_posts, force: true) { |t| t.datetime :deleted_at }
        create_table(:http_audit_secret_notes, force: true) do |t|
          t.integer :http_audit_post_id
          t.datetime :deleted_at
        end
      end
    end
    stub_const("Admin", Module.new)
    stub_const("Admin::HttpAuditSecretNote", Class.new(ActiveRecord::Base) do
      self.table_name = "http_audit_secret_notes"
      include ConcernsOnRails::SoftDeletable

      soft_deletable_by :deleted_at
      belongs_to :http_audit_post, class_name: "HttpAuditPost"
      def after_soft_delete
        raise ActiveRecord::Rollback
      end
    end)
    stub_const("HttpAuditPost", Class.new(ActiveRecord::Base) do
      self.table_name = "http_audit_posts"
      include ConcernsOnRails::SoftDeletable

      has_many :notes, class_name: "Admin::HttpAuditSecretNote", foreign_key: :http_audit_post_id
      soft_deletable_by :deleted_at, cascade: :notes
    end)
  end

  after do
    %i[http_audit_posts http_audit_secret_notes].each { |t| ActiveRecord::Base.connection.drop_table(t, if_exists: true) }
  end

  it "does not leak the model class name / id in the record_not_saved 422" do
    klass = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::ErrorHandleable

      define_method(:destroy) do
        post = HttpAuditPost.create!
        Admin::HttpAuditSecretNote.create!(http_audit_post_id: post.id)
        post.soft_delete!
        head :no_content
      end
    end
    result = IntegrationHarness.dispatch(klass, :destroy, method: "DELETE")

    expect(result.status).to eq(422)
    expect(JSON.parse(result.body)["error"]["code"]).to eq("record_not_saved")
    expect(result.body).not_to include("HttpAuditSecretNote")
    expect(result.body).not_to match(/id: \d/)
    expect(result.body).not_to include("ConcernsOnRails::")
  end
end
