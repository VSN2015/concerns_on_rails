require "spec_helper"

# Audit 2026-10-10 DATA-12: the data concerns addressed their own row with a
# hand-built `where(primary_key => id)`. Under a composite primary key
# (Rails 7.1+) that is `where(["shop_id", "id"] => [2, 1])`, which raises
# ArgumentError — key rotation, erasure under optimistic locking and the
# row-lock helpers (Stateable `lock: true`, Activatable `toggle_active!`)
# were impossible on such a model. Support::PrimaryKey pairs the columns up.
describe "Composite primary keys in the data concerns' own row lookups" do
  before do
    ConcernsOnRails.encryption.key = "concerns-on-rails-cpk-key"
    ConcernsOnRails.encryption.on_missing_key = :raise
    ConcernsOnRails.encryption.raise_on_decrypt_error = true
  end

  after(:each) do
    ConcernsOnRails.encryption.key = nil
    ConcernsOnRails.encryption.key_id = 0
    ConcernsOnRails.encryption.previous_keys = {}
  end

  describe ConcernsOnRails::Support::PrimaryKey do
    it "builds a single-column condition for a simple key" do
      klass = Class.new(TestModel) { self.table_name = "cpk_simple_rows" }
      allow(klass).to receive(:primary_key).and_return("id")

      expect(described_class.condition(klass, 7)).to eq("id" => 7)
      expect(described_class.columns(klass)).to eq(["id"])
    end

    it "pairs every column with its value for a composite key" do
      klass = Class.new(TestModel) { self.table_name = "cpk_rows" }
      allow(klass).to receive(:primary_key).and_return(%w[shop_id id])

      expect(described_class.condition(klass, [2, 1])).to eq("shop_id" => 2, "id" => 1)
      expect(described_class.columns(klass)).to eq(%w[shop_id id])
    end
  end

  context "on a table keyed by [shop_id, id]", min_rails: "7.1" do
    before do
      ActiveRecord::Schema.define do
        create_table :cpk_accounts, primary_key: %i[shop_id id], force: true do |t|
          t.integer :shop_id
          t.integer :id
          t.text :ssn
          t.string :name
          t.integer :lock_version
          t.datetime :anonymized_at
        end
      end
    end

    after(:each) do
      ActiveRecord::Base.connection.drop_table(:cpk_accounts, if_exists: true)
    end

    def model(&declaration)
      klass = Class.new(TestModel) { self.table_name = "cpk_accounts" }
      klass.class_eval(&declaration) if declaration
      klass
    end

    it "Encryptable#reencrypt! rotates exactly its own row" do
      klass = model do
        include ConcernsOnRails::Models::Encryptable

        encryptable :ssn
      end
      klass.create!(id: [1, 1], ssn: "a")
      klass.create!(id: [2, 1], ssn: "b")
      ConcernsOnRails.encryption.key_id = 1
      ConcernsOnRails.encryption.previous_keys = { 0 => "concerns-on-rails-cpk-key" }

      expect(klass.find([2, 1]).reencrypt!).to be(true)
      expect(klass.find([2, 1]).ssn_key_id).to eq(1)
      expect(klass.find([2, 1]).ssn).to eq("b")
      expect(klass.find([1, 1]).ssn_key_id).to eq(0)
    end

    it "Encryptable.reencrypt_all! sweeps every row" do
      klass = model do
        include ConcernsOnRails::Models::Encryptable

        encryptable :ssn
      end
      klass.create!(id: [1, 1], ssn: "a")
      klass.create!(id: [2, 1], ssn: "b")
      ConcernsOnRails.encryption.key_id = 1
      ConcernsOnRails.encryption.previous_keys = { 0 => "concerns-on-rails-cpk-key" }

      expect(klass.reencrypt_all!).to eq(2)
      expect(klass.needs_reencryption).to be_empty
    end

    it "Anonymizable#anonymize! (the optimistic-locking path) erases exactly its own row" do
      klass = model do
        include ConcernsOnRails::Models::Anonymizable

        anonymizable :name, with: :redact
      end
      klass.create!(id: [1, 1], name: "a")
      klass.create!(id: [2, 1], name: "b")
      record = klass.find([2, 1])

      expect(record.anonymize!).to be(true)
      expect(record.lock_version).to eq(1)
      expect(klass.find([2, 1]).name).to eq("[REDACTED]")
      expect(klass.find([1, 1]).name).to eq("a")
    end

    it "Support::Locking.with_row_lock reads exactly its own row" do
      klass = model
      klass.create!(id: [1, 1], name: "a")
      record = klass.create!(id: [2, 1], name: "b")

      expect(ConcernsOnRails::Support::Locking.with_row_lock(record, :name) { |row| row }).to eq("name" => "b")
      expect(ConcernsOnRails::Support::Locking.with_row_lock(record, :name, :lock_version) { |row| row })
        .to eq("name" => "b", "lock_version" => 0)
    end
  end
end
