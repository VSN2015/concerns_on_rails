require "spec_helper"

describe ConcernsOnRails::Support::HookedWrite do
  before do
    ActiveRecord::Schema.define do
      create_table :hooked_items, force: true do |t|
        t.string :state
        t.string :note
      end
    end

    stub_const("HookedItem", Class.new(TestModel) do
      self.table_name = "hooked_items"

      attr_reader :log

      cattr_accessor :after_action

      private

      def before_write
        (@log ||= []) << :before
        self.class.where(id: id).update_all(note: "before-hook")
      end

      def after_write
        (@log ||= []) << :after
        action = self.class.after_action
        raise ActiveRecord::Rollback if action == :rollback
        raise "boom" if action == :raise
      end
    end)
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  def run(item, **options, &write)
    described_class.run(item, before: :before_write, after: :after_write, **options, &write)
  end

  let(:item) { HookedItem.create!(state: "old") }

  # Rails 6.0: rolling back the savepoint makes `rolledback!` restore the
  # record's transaction state from when it was CREATED inside the caller's
  # outer transaction — id nil, new_record? true — so the next save INSERTed
  # a duplicate row.
  describe "a record created earlier in the caller's transaction" do
    it "stays persisted after a falsey write, so the next save updates the same row" do
      ActiveRecord::Base.transaction do
        fresh = HookedItem.create!(state: "old")
        expect(run(fresh) { false }).to be(false)

        expect(fresh).to be_persisted
        expect(fresh.id).not_to be_nil
        fresh.note = "edited"
        fresh.save!
      end

      expect(HookedItem.count).to eq(1)
      expect(HookedItem.first.note).to eq("edited")
    end

    it "stays persisted after an after-hook Rollback veto" do
      HookedItem.after_action = :rollback
      ActiveRecord::Base.transaction do
        fresh = HookedItem.create!(state: "old")
        expect(run(fresh) { fresh.update(state: "new") }).to be(false)

        expect(fresh).to be_persisted
        fresh.update!(note: "edited")
      end

      expect(HookedItem.pluck(:state, :note)).to eq([%w[old edited]])
    end
  end

  it "runs before, write, after (private hooks included) and returns true" do
    expect(run(item) { item.update(state: "new") }).to be(true)
    expect(item.log).to eq(%i[before after])
    expect(item.reload.state).to eq("new")
  end

  it "returns false, skips the after hook and rolls the before hook back when the write is falsey" do
    expect(run(item) { false }).to be(false)
    expect(item.log).to eq(%i[before])
    expect(item.reload.note).to be_nil
  end

  it "returns false and rolls everything back when the after hook raises ActiveRecord::Rollback" do
    HookedItem.after_action = :rollback

    expect(run(item) { item.update_column(:state, "new") }).to be(false)
    expect(item.state).to eq("old")
    expect(item.reload.state).to eq("old")
    expect(item.note).to be_nil
  end

  it "honors the Rollback inside a caller's transaction without touching the caller's writes" do
    HookedItem.after_action = :rollback
    other = HookedItem.create!(state: "x")

    result = nil
    ActiveRecord::Base.transaction do
      other.update!(state: "y")
      result = run(item) { item.update(state: "new") }
    end

    expect(result).to be(false)
    expect(other.reload.state).to eq("y")
    expect(item.reload.state).to eq("old")
  end

  it "propagates an exception, rolls back, and restores the in-memory value" do
    HookedItem.after_action = :raise

    expect { run(item) { item.update_column(:state, "new") } }.to raise_error("boom")
    expect(item.state).to eq("old")
    expect(item.changed?).to be(false)
    expect(item.reload.state).to eq("old")
  end

  it "restores an attribute that was already dirty as dirty against its database value" do
    HookedItem.after_action = :rollback
    item.state = "unsaved"

    run(item) { item.update_column(:state, "new") }

    expect(item.state).to eq("unsaved")
    expect(item.state_in_database).to eq("old")
    expect(item.state_changed?).to be(true)
  end

  # Only the verb's own column used to be put back: anything else the write
  # changed in memory (a before_save callback's column, a hook's assignment)
  # stayed behind — marked saved, since `update` applied the changes — so the
  # record reported state the database never held.
  it "restores every attribute the write changed, and the last save's changes" do
    HookedItem.after_action = :rollback
    record = HookedItem.find(item.id)

    expect(run(record) { record.update(state: "new", note: "side effect") }).to be(false)

    expect(record.attributes.slice("state", "note")).to eq("state" => "old", "note" => nil)
    expect(record.changed?).to be(false)
    expect(record.saved_changes).to be_empty
  end

  it "keeps an unrelated unsaved edit dirty across the abort" do
    HookedItem.after_action = :rollback
    item.note = "draft note"

    run(item) { item.update(state: "new") }

    expect(item.note).to eq("draft note")
    expect(item.changed).to eq(%w[note])
    expect(item.reload.note).to be_nil
  end

  # Encryptable + Storable + Auditable on the model whose Publishable write is
  # vetoed: Auditable's before_save appends to the trail during the aborted
  # `update`. (Rails' own savepoint rollback reads the record's attributes —
  # so the snapshot's never-decrypt guarantee is pinned by the update_columns
  # examples below, not here.)
  describe "a vetoed publish on a model with Encryptable, Storable and Auditable" do
    before do
      ConcernsOnRails.encryption.key = "hooked-write-combined-key"
      ActiveRecord::Schema.define do
        create_table :layered_items, force: true do |t|
          t.string :title
          t.text :ssn
          t.text :settings
          t.text :audit_log
          t.datetime :published_at
        end
      end
      stub_const("LayeredItem", Class.new(TestModel) do
        self.table_name = "layered_items"
        include ConcernsOnRails::Models::Encryptable
        include ConcernsOnRails::Models::Storable
        include ConcernsOnRails::Models::Auditable
        include ConcernsOnRails::Models::Publishable

        encryptable :ssn
        storable_by :settings, theme: { type: :string, default: "light" }
        auditable_by :published_at, :title, into: :audit_log
        publishable_by :published_at

        cattr_accessor :veto

        def after_publish
          raise ActiveRecord::Rollback if self.class.veto
        end
      end)
    end

    after { ConcernsOnRails.encryption.key = nil }

    it "puts every layer back, and a later save persists no phantom entry" do
      id = LayeredItem.create!(title: "a", ssn: "123-45-6789").id
      record = LayeredItem.find(id)
      trail = record.read_attribute_before_type_cast(:audit_log)
      record.theme = "dark" # an unsaved Storable edit
      LayeredItem.veto = true

      expect(record.publish!).to be(false)

      expect(record.published_at).to be_nil
      expect(record.read_attribute_before_type_cast(:audit_log)).to eq(trail)
      expect(record.theme).to eq("dark")
      expect(record.changed).to eq(%w[settings])

      LayeredItem.veto = false
      record.save!
      fresh = LayeredItem.find(id)
      expect(fresh.audit_trail.map { |entry| entry["field"] }).to eq(%w[title])
      expect(fresh.theme).to eq("dark")
      expect(fresh.ssn).to eq("123-45-6789")
    end
  end

  # The snapshot used to read every attribute through its type, which
  # decrypts an Encryptable field — so a row whose ciphertext no longer
  # decrypts (rotated-away key) could not be written at all, not even erased
  # by Anonymizable. The snapshot must never abort the write.
  describe "an Encryptable field that cannot be decrypted" do
    before do
      ConcernsOnRails.encryption.key = "hooked-write-original-key"
      ConcernsOnRails.encryption.raise_on_decrypt_error = true
      ActiveRecord::Schema.define do
        create_table :sealed_items, force: true do |t|
          t.text :ssn
          t.string :note
        end
      end
      stub_const("SealedItem", Class.new(TestModel) do
        self.table_name = "sealed_items"
        include ConcernsOnRails::Models::Encryptable

        encryptable :ssn

        cattr_accessor :veto

        def after_write
          raise ActiveRecord::Rollback if self.class.veto
        end
      end)
    end

    after do
      ConcernsOnRails.encryption.key = nil
      ConcernsOnRails.encryption.raise_on_decrypt_error = true
    end

    def undecryptable_record
      id = SealedItem.create!(ssn: "123-45-6789").id
      ConcernsOnRails.encryption.key = "a-rotated-away-key"
      SealedItem.find(id)
    end

    # Erasure must not load old PII into memory just to snapshot it: an
    # attribute nobody has read yet is snapshotted raw, never decrypted.
    def unread_record
      SealedItem.find(SealedItem.create!(ssn: "123-45-6789").id)
    end

    it "never decrypts an unread field on a successful write" do
      record = unread_record
      expect(ConcernsOnRails::Support::Encryptor).not_to receive(:decrypt)

      result = described_class.run(record, after: :after_write) do
        record.update_columns(ssn: nil, note: "erased")
      end

      expect(result).to be(true)
    end

    it "never decrypts an unread field on a vetoed write, and restores it raw" do
      record = unread_record
      raw = record.read_attribute_before_type_cast(:ssn)
      SealedItem.veto = true
      expect(ConcernsOnRails::Support::Encryptor).not_to receive(:decrypt)

      result = described_class.run(record, after: :after_write) do
        record.update_columns(ssn: nil, note: "erased")
      end

      expect(result).to be(false)
      expect(record.read_attribute_before_type_cast(:ssn)).to eq(raw)
      expect(record.changed).not_to include("ssn")
    end

    it "still restores an already-read field to its in-memory value" do
      record = unread_record
      expect(record.ssn).to eq("123-45-6789")
      SealedItem.veto = true

      described_class.run(record, after: :after_write) do
        record.update_columns(ssn: nil, note: "erased")
      end

      expect(record.ssn).to eq("123-45-6789")
      expect(record.changed).not_to include("ssn")
      expect(SealedItem.find(record.id).ssn).to eq("123-45-6789")
    end

    it "does not raise when the write succeeds" do
      record = undecryptable_record

      result = described_class.run(record, after: :after_write) do
        record.update_columns(ssn: nil, note: "erased")
      end

      expect(result).to be(true)
      expect(SealedItem.find(record.id).read_attribute_before_type_cast(:ssn)).to be_nil
    end

    it "does not raise on an aborted write and leaves the raw value exactly as loaded" do
      record = undecryptable_record
      raw = record.read_attribute_before_type_cast(:ssn)
      SealedItem.veto = true

      result = described_class.run(record, after: :after_write) do
        record.update_columns(ssn: nil, note: "erased")
      end

      expect(result).to be(false)
      expect(record.read_attribute_before_type_cast(:ssn)).to eq(raw)
      expect(record.changed).not_to include("ssn")
      expect(SealedItem.find(record.id).read_attribute_before_type_cast(:ssn)).to eq(raw)
      expect { record.ssn }.to raise_error(ConcernsOnRails::Encryption::DecryptionError)
    end
  end

  it "skips a hook passed as nil" do
    expect(described_class.run(item) { item.update(state: "new") }).to be(true)
    expect(item.log).to be_nil
  end
end
