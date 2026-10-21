require "spec_helper"

# Audit 2026-10-10 DATA-2: EncryptedType had no `changed_in_place?`, and
# ActiveModel::Type::Value's is always false, so an in-place edit of a
# decrypted String (`record.notes << " world"`, `gsub!`, `squish!`) was never
# dirty: `save!` returned true, wrote nothing, and `reload` brought back the
# old value — while a plain string column in the same save persisted its edit.
describe "Encryptable: an in-place mutation of a decrypted String" do
  before do
    ConcernsOnRails.encryption.key = "concerns-on-rails-in-place-key"
    ConcernsOnRails.encryption.on_missing_key = :raise
    ConcernsOnRails.encryption.raise_on_decrypt_error = true

    ActiveRecord::Schema.define do
      create_table :enc_in_place_records, force: true do |t|
        t.text :notes
        t.text :born_on
        t.string :name
      end
    end
  end

  after(:each) do
    ConcernsOnRails.encryption.key = nil
    ActiveRecord::Base.connection.drop_table(:enc_in_place_records, if_exists: true)
  end

  let(:klass) do
    Class.new(TestModel) do
      self.table_name = "enc_in_place_records"
      include ConcernsOnRails::Models::Encryptable

      encryptable :notes
      encryptable :born_on, type: :date
    end
  end

  it "is persisted, as it is for a plain string column" do
    record = klass.create!(notes: "hello", name: "x").reload
    record.notes << " world"
    record.name << "y"

    expect(record.notes_changed?).to be(true)
    record.save!

    expect(record.reload.name).to eq("xy")
    expect(record.notes).to eq("hello world")
    expect(record.notes_encrypted?).to be(true)
  end

  it "is persisted for gsub! and squish! too" do
    record = klass.create!(notes: "  a   b  ").reload
    record.notes.squish!
    record.save!
    expect(record.reload.notes).to eq("a b")

    record.notes.gsub!("a", "z")
    record.save!
    expect(record.reload.notes).to eq("z b")
  end

  it "reports the change through changes / changes_to_save" do
    record = klass.create!(notes: "hello").reload
    record.notes << "!"

    expect(record.changes_to_save).to eq("notes" => ["hello", "hello!"])
  end

  it "does not re-encrypt an unchanged field that was only read" do
    record = klass.create!(notes: "hello", born_on: Date.new(1990, 1, 1)).reload
    stored = record.notes_ciphertext
    record.notes
    record.born_on

    expect(record.changed?).to be(false)
    expect(record.save!).to be(true)
    expect(record.reload.notes_ciphertext).to eq(stored)
  end

  it "persists an in-place edit of an empty-String value" do
    record = klass.create!(notes: "").reload
    record.notes << "filled"
    record.save!

    expect(record.reload.notes).to eq("filled")
  end
end
