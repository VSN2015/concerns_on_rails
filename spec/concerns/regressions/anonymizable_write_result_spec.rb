require "spec_helper"

# Audit 2026-10-29 (STATE-9): the HookedWrite block in anonymize_record!
# returned true whatever anonymizable_write! answered, so a row deleted (or,
# under optimistic locking, unwritable) between load and UPDATE was still
# counted by anonymize_all! ("records actually erased"), fired after_anonymize,
# and made anonymize! reach `reload` and raise RecordNotFound instead of
# answering false. The write's own result now decides.
describe "Anonymizable when the UPDATE reaches no row" do
  before do
    ActiveRecord::Schema.define do
      create_table :awr_users, force: true do |t|
        t.string :email
        t.datetime :anonymized_at
      end
      create_table :awr_locked, force: true do |t|
        t.string :email
        t.datetime :anonymized_at
        t.integer :lock_version, default: 0, null: false
      end
    end
  end

  after do
    %i[awr_users awr_locked].each { |t| ActiveRecord::Base.connection.drop_table(t, if_exists: true) }
  end

  # `gone` lists the ids whose row the before hook deletes, as a concurrent
  # delete between load and UPDATE would.
  def build_model(table)
    Class.new(TestModel) do
      self.table_name = table
      include ConcernsOnRails::Anonymizable

      anonymizable :email, with: :email

      class << self
        attr_writer :gone

        def gone
          @gone ||= []
        end
      end

      attr_accessor :fired

      def before_anonymize
        self.class.unscoped.where(id: id).delete_all if self.class.gone.include?(id)
      end

      def after_anonymize
        (self.fired ||= []) << :after_anonymize
      end
    end
  end

  shared_examples "an erasure that reached no row" do
    it "anonymize_all! does not count the row" do
      model.gone = [model.create!(email: "a@x.io").id]

      expect(model.anonymize_all!).to eq(0)
    end

    it "anonymize_all! counts only the rows it erased" do
      doomed = model.create!(email: "gone@x.io")
      survivor = model.create!(email: "kept@x.io")
      model.gone = [doomed.id]

      expect(model.anonymize_all!).to eq(1)
      expect(model.unscoped.find(survivor.id).email).not_to eq("kept@x.io")
      expect(model.unscoped.find(survivor.id).anonymized_at).not_to be_nil
    end

    it "anonymize! returns false (no RecordNotFound), fires no after hook and keeps the instance's values" do
      user = model.create!(email: "a@x.io")
      model.gone = [user.id]

      expect(user.anonymize!).to be(false)
      expect(user.fired).to be_nil
      expect(user.email).to eq("a@x.io")
      expect(user.anonymized_at).to be_nil
    end

    it "still erases a row that is there: true, hook fired, counted once" do
      user = model.create!(email: "a@x.io")

      expect(user.anonymize!).to be(true)
      expect(user.fired).to eq([:after_anonymize])
      expect(user.reload.anonymized_at).not_to be_nil
      expect(user.email).not_to eq("a@x.io")

      other = model.create!(email: "b@x.io")
      expect(model.anonymize_all!).to eq(1)
      expect(other.reload.anonymized_at).not_to be_nil
    end
  end

  context "with plain update_columns" do
    let(:model) { build_model("awr_users") }

    it_behaves_like "an erasure that reached no row"
  end

  context "with optimistic locking (update_all keyed on the primary key)" do
    let(:model) { build_model("awr_locked") }

    it_behaves_like "an erasure that reached no row"

    it "bumps lock_version on a row that is there" do
      user = model.create!(email: "a@x.io")

      expect(user.anonymize!).to be(true)
      expect(user.reload.lock_version).to eq(1)
    end
  end
end
