require "spec_helper"

# Audit 2026-10-10 DATA-6 + DATA-8: Encryptable's blind index (before_create /
# before_update) and Auditable's capture (before_save) ran at a fixed point in
# the callback chain, so a model's own before_* callback declared after the
# macros — the usual layout — ran later. The row then stored one value's
# ciphertext beside another value's digest (find_by_<field> missed it), and
# the audit trail left a callback's change out or recorded a value that was
# never stored. Both now derive at the write boundary
# (Support::WriteBoundary), after every before_* callback, blind index first.
describe "Encryptable and Auditable derive from the values actually written" do
  WB_ENCRYPTION_KEY = "write-boundary-spec-key-write-boundary-spec".freeze

  before do
    ConcernsOnRails.encryption.key = WB_ENCRYPTION_KEY
    ConcernsOnRails.encryption.on_missing_key = :raise
    ConcernsOnRails.encryption.raise_on_decrypt_error = true

    ActiveRecord::Schema.define do
      create_table :wb_orders, force: true do |t|
        t.string :name
        t.string :status
        t.integer :price, default: 0
        t.integer :total, default: 0
        t.text :email
        t.string :email_bidx
        t.string :code
        t.text :audit_log
      end
      add_index :wb_orders, :code, unique: true
    end
  end

  after(:each) do
    ConcernsOnRails.encryption.key = nil
    ActiveRecord::Base.connection.drop_table(:wb_orders, if_exists: true)
    ActiveRecord::Base.connection.drop_table(:wb_locked_orders, if_exists: true)
  end

  def order_model(*concerns, table: "wb_orders", &declaration)
    Class.new(TestModel) do
      self.table_name = table
      concerns.each { |concern| include concern }
      class_eval(&declaration)
    end
  end

  let(:encryptable) { ConcernsOnRails::Models::Encryptable }
  let(:auditable) { ConcernsOnRails::Models::Auditable }

  describe "Encryptable's blind index" do
    it "fingerprints the value a later before_update rewrote" do
      klass = order_model(encryptable) do
        encryptable :email, blind_index: true
        before_update { self.email = email.downcase if email }
      end
      record = klass.create!(email: "a@b.com")

      record.update!(email: "Z@B.com")

      expect(klass.find_by_email("z@b.com")).to eq(record)
      expect(klass.find_by_email("a@b.com")).to be_nil
    end

    it "fingerprints the value a later before_create rewrote" do
      klass = order_model(encryptable) do
        encryptable :email, blind_index: true
        before_create { self.email = email.downcase if email }
      end

      record = klass.create!(email: "Z@B.com")

      expect(klass.find_by_email("z@b.com")).to eq(record)
    end

    it "keeps the digest of a field nothing changed" do
      klass = order_model(encryptable) { encryptable :email, blind_index: true }
      record = klass.create!(email: "a@b.com", name: "x")

      record.update!(name: "y")

      expect(klass.find_by_email("a@b.com")).to eq(record)
    end
  end

  describe "Auditable's capture" do
    it "records a tracked field only a later callback changed" do
      klass = order_model(auditable) do
        auditable_by :total
        before_save { self.total = price.to_i * 10 }
      end
      record = klass.create!(price: 0)

      record.update!(price: 10)

      expect(record.reload.total).to eq(100)
      expect(record.last_change_for(:total)).to include("from" => 0, "to" => 100)
    end

    it "records the value a later before_save stored, not the one assigned" do
      klass = order_model(auditable) do
        auditable_by :total
        before_save { self.total = 100 if total.to_i < 100 }
      end
      record = klass.create!(total: 200)

      record.update!(total: 5)

      expect(record.reload.total).to eq(100)
      expect(record.last_change_for(:total)).to include("from" => 200, "to" => 100)
    end

    it "records the value a later before_update or before_create stored" do
      klass = order_model(auditable) do
        auditable_by :status
        before_create { self.status = status.upcase }
        before_update { self.status = status.upcase }
      end
      record = klass.create!(status: "a")
      expect(record.reload.last_change_for(:status)).to include("from" => nil, "to" => "A")

      record.update!(status: "b")

      expect(record.reload.status).to eq("B")
      expect(record.last_change_for(:status)).to include("from" => "A", "to" => "B")
    end

    it "writes no entry when a callback reverts the tracked change" do
      klass = order_model(auditable) do
        auditable_by :status
        before_save { restore_attributes([:status]) if status == "locked" }
      end
      record = klass.create!(status: "open")

      record.update!(status: "locked")

      expect(record.reload.audit_trail.map { |entry| entry["to"] }).to eq(["open"])
    end
  end

  # An audited blind-index column records the digest actually written,
  # whichever concern was included (and declared) first.
  [true, false].each do |auditable_first|
    it "audits the refreshed blind index (#{auditable_first ? 'Auditable' : 'Encryptable'} first)" do
      concerns = auditable_first ? [auditable, encryptable] : [encryptable, auditable]
      klass = order_model(*concerns) do
        if auditable_first
          auditable_by :email_bidx
          encryptable :email, blind_index: true
        else
          encryptable :email, blind_index: true
          auditable_by :email_bidx
        end
        before_update { self.email = email.downcase if email }
      end
      record = klass.create!(email: "a@b.com")
      expect(record.reload.last_change_for(:email_bidx)).to include("from" => nil, "to" => record.email_bidx)

      record.update!(email: "Z@B.com")
      stored = klass.find(record.id)

      expect(stored.email_bidx).to eq(klass.email_fingerprint("z@b.com"))
      expect(stored.last_change_for(:email_bidx)).to include("to" => stored.email_bidx)
      expect(stored.audit_trail.size).to eq(2)
    end
  end

  describe "what the move keeps" do
    it "never duplicates an entry when the write itself fails and the save is retried" do
      klass = order_model(auditable) { auditable_by :total }
      klass.create!(code: "taken")
      record = klass.create!(total: 1)

      record.assign_attributes(total: 2, code: "taken")
      expect { record.save! }.to raise_error(ActiveRecord::RecordNotUnique)
      record.code = "free"
      record.save!

      expect(record.reload.audit_trail.map { |entry| entry["to"] }).to eq([1, 2])
    end

    it "never writes an unchanged trail, so a stale copy cannot drop a concurrent entry" do
      klass = order_model(auditable) { auditable_by :total }
      record = klass.create!(total: 1)
      stale = klass.find(record.id)

      record.update!(total: 2)
      stale.update!(name: "untracked")

      expect(klass.find(record.id).audit_trail.map { |entry| entry["to"] }).to eq([1, 2])
    end

    it "still trims to max_entries" do
      klass = order_model(auditable) do
        auditable_by :total, max_entries: 2
        before_save { self.total = total.to_i * 10 }
      end
      record = klass.create!(total: 1)
      record.update!(total: 2)
      record.update!(total: 3)

      expect(record.reload.audit_trail.map { |entry| entry["to"] }).to eq([20, 30])
    end

    it "works with optimistic locking" do
      ActiveRecord::Schema.define do
        create_table :wb_locked_orders, force: true do |t|
          t.integer :total
          t.text :email
          t.string :email_bidx
          t.text :audit_log
          t.integer :lock_version, default: 0, null: false
        end
      end
      klass = order_model(encryptable, auditable, table: "wb_locked_orders") do
        encryptable :email, blind_index: true
        auditable_by :total
        before_update { self.email = email.downcase if email }
      end
      record = klass.create!(total: 1, email: "a@b.com")

      record.update!(total: 2, email: "Z@B.com")

      stored = klass.find(record.id)
      expect(stored.lock_version).to eq(1)
      expect(record.lock_version).to eq(1)
      expect(klass.find_by_email("z@b.com")).to eq(stored)
      expect(stored.audit_trail.map { |entry| entry["to"] }).to eq([1, 2])
    end
  end
end
