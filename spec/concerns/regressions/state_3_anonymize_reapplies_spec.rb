require "spec_helper"

# STATE-3 (audit v1.35.2) was resolved as "by design": anonymize! always re-applies every
# rule, so it must erase again on an already-stamped record. A saved-state no-op would leave
# PII behind in these three cases.
describe "Anonymizable#anonymize! on an already-anonymized record" do
  before do
    ActiveRecord::Schema.define do
      create_table :s3_users, force: true do |t|
        t.string :email
        t.string :phone
        t.datetime :anonymized_at
      end
    end
  end

  after { ActiveRecord::Base.connection.drop_table(:s3_users, if_exists: true) }

  let(:model) do
    Class.new(TestModel) do
      self.table_name = "s3_users"
      include ConcernsOnRails::Anonymizable

      anonymizable :email, with: :redact
    end
  end

  it "erases PII assigned (unsaved) after the first anonymization" do
    user = model.create!(email: "jane@example.com")
    user.anonymize!
    user.email = "real@example.com"
    expect(user.anonymize!).to be(true)
    user.save!
    expect(model.find(user.id).email).not_to eq("real@example.com")
  end

  it "erases PII written back to the row after the first anonymization" do
    user = model.create!(email: "jane@example.com")
    user.anonymize!
    user.update!(email: "real@example.com")
    user.anonymize!
    expect(model.find(user.id).email).not_to eq("real@example.com")
  end

  it "applies a rule added later to a stamped record" do
    user = model.create!(email: "jane@example.com", phone: "555-1234")
    user.anonymize!
    model.anonymizable :phone, with: :nullify
    model.find(user.id).anonymize!
    expect(model.find(user.id).phone).to be_nil
  end
end
