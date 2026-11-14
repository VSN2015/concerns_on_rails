require "spec_helper"

# STATE-3 (audit v1.35.2): anonymize! on an already-anonymized record re-ran
# every strategy (a :hash pseudonym became SHA256(SHA256(x))) and both hooks.
describe "Anonymizable#anonymize! on an already-anonymized record" do
  before do
    ActiveRecord::Schema.define do
      create_table :s3_users, force: true do |t|
        t.string :email
        t.datetime :anonymized_at
      end
    end
  end

  after { ActiveRecord::Base.connection.drop_table(:s3_users, if_exists: true) }

  def build_model(**opts)
    Class.new(TestModel) do
      self.table_name = "s3_users"
      include ConcernsOnRails::Anonymizable

      anonymizable :email, with: :hash, **opts
      attr_accessor :fired

      def after_anonymize
        self.fired = (fired || 0) + 1
      end
    end
  end

  it "is a no-op (no re-hash, no hooks), like anonymize_all! which skips stamped rows" do
    model = build_model
    user = model.create!(email: "jane@example.com")
    user.anonymize!
    pseudonym = user.email
    stamp = user.anonymized_at
    expect(model.where(id: user.id).anonymize_all!).to eq(0)
    expect(user.anonymize!).to be(true)
    expect(user.email).to eq(pseudonym)
    expect(user.anonymized_at).to eq(stamp)
    expect(user.fired).to eq(1)
  end

  it "is a no-op for a fresh instance of an anonymized row" do
    model = build_model
    id = model.create!(email: "jane@example.com").tap(&:anonymize!).id
    pseudonym = model.find(id).email
    copy = model.find(id)
    expect(copy.anonymize!).to be(true)
    expect(model.find(id).email).to eq(pseudonym)
    expect(copy.fired).to be_nil
  end

  it "still runs when the stamp is reassigned (unsaved change)" do
    model = build_model
    user = model.create!(email: "jane@example.com").tap(&:anonymize!)
    user.anonymized_at = 1.day.ago
    user.anonymize!
    expect(user.fired).to eq(2)
  end

  it "keeps running every time with stamp: false (nothing to observe)" do
    model = build_model(stamp: false)
    user = model.create!(email: "jane@example.com")
    user.anonymize!
    user.anonymize!
    expect(user.fired).to eq(2)
  end
end
