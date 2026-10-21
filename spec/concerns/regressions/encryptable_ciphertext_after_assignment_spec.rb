require "spec_helper"

# Audit 2026-10-10 DATA-1: `<field>_ciphertext` returned
# read_attribute_before_type_cast whenever the field was not changed. An
# assignment that leaves the value unchanged (an edit form re-submitting the
# same SSN, an assign-then-revert, CounterCacheable restoring an old value to
# judge `if:`) still wraps the attribute in a user-assigned one whose raw
# value is the PLAINTEXT — so the reader documented for "no plaintext at rest"
# handed back the SSN, `_encrypted?` turned false, `_key_id` raised, and
# `reencrypt!` guarded its UPDATE on the plaintext, matched nothing and
# silently skipped the row. The stored value is now read from the attribute
# that came from the database.
describe "Encryptable: the value at rest after an assignment that leaves the field unchanged" do
  let(:key) { "concerns-on-rails-ciphertext-assignment-key" }

  before do
    ConcernsOnRails.encryption.key = key
    ConcernsOnRails.encryption.on_missing_key = :raise
    ConcernsOnRails.encryption.raise_on_decrypt_error = true

    ActiveRecord::Schema.define do
      create_table :enc_assign_posts, force: true do |t|
        t.integer :items_count, default: 0
      end
      create_table :enc_assign_items, force: true do |t|
        t.text :ssn
        t.string :name
        t.boolean :approved, default: false
        t.integer :enc_assign_post_id
        t.datetime :anonymized_at
      end
    end
  end

  after(:each) do
    ConcernsOnRails.encryption.key = nil
    ConcernsOnRails.encryption.key_id = 0
    ConcernsOnRails.encryption.previous_keys = {}
    %i[enc_assign_posts enc_assign_items].each { |table| ActiveRecord::Base.connection.drop_table(table, if_exists: true) }
  end

  def model(&declaration)
    klass = Class.new(TestModel) do
      self.table_name = "enc_assign_items"
      include ConcernsOnRails::Models::Encryptable
    end
    klass.class_eval(&declaration)
    klass
  end

  let(:klass) { model { encryptable :ssn } }

  it "never hands back plaintext after an edit form re-submits the unchanged value" do
    record = klass.create!(ssn: "111-11-1111").reload
    record.assign_attributes(ssn: "111-11-1111")

    expect(record.ssn_changed?).to be(false)
    expect(record.ssn_ciphertext).not_to include("111-11-1111")
    expect(record.ssn_encrypted?).to be(true)
    expect(record.ssn_key_id).to eq(0)
  end

  it "never hands back plaintext after an assignment is reverted" do
    record = klass.create!(ssn: "1").reload
    stored = record.ssn_ciphertext
    record.ssn = "2"
    record.ssn = "1"

    expect(record.changed?).to be(false)
    expect(record.ssn_ciphertext).to eq(stored)
    expect(record.ssn_encrypted?).to be(true)
  end

  it "still returns nil while the field carries a real unsaved change" do
    record = klass.create!(ssn: "1").reload
    record.ssn = "2"

    expect(record.ssn_ciphertext).to be_nil
    expect(klass.new(ssn: "3").ssn_ciphertext).to be_nil
  end

  it "reencrypt! still rotates a row whose field was re-assigned its own value" do
    record = klass.create!(ssn: "111-11-1111").reload
    ConcernsOnRails.encryption.key_id = 1
    ConcernsOnRails.encryption.previous_keys = { 0 => key }
    record.assign_attributes(ssn: "111-11-1111")

    expect(record.reencrypt!).to be(true)
    expect(record.reload.ssn_key_id).to eq(1)
    expect(record.ssn).to eq("111-11-1111")
  end

  it "leaves no plaintext behind after a conditional CounterCacheable rule judged the old state" do
    stub_const("EncAssignPost", Class.new(TestModel) { self.table_name = "enc_assign_posts" })
    stub_const("EncAssignItem", Class.new(TestModel) do
      self.table_name = "enc_assign_items"
      include ConcernsOnRails::Models::Encryptable
      include ConcernsOnRails::Models::CounterCacheable

      encryptable :ssn
      belongs_to :enc_assign_post, optional: true
      counter_cacheable_by :enc_assign_post, count: :items_count, if: -> { approved? }
    end)
    post = EncAssignPost.create!
    record = EncAssignItem.find(EncAssignItem.create!(ssn: "111-11-1111", enc_assign_post_id: post.id).id)
    record.update!(ssn: "222-22-2222", approved: true)

    expect(record.ssn_ciphertext).not_to include("222-22-2222")
    expect(record.ssn_encrypted?).to be(true)
    expect(post.reload.items_count).to eq(1)
  end

  it "keeps reading the stored envelope after update_columns" do
    record = klass.create!(ssn: "111-11-1111")
    record.update_columns(ssn: "444-55-6666")

    expect(record.ssn_ciphertext).not_to include("444-55-6666")
    expect(record.ssn_encrypted?).to be(true)
    expect(record.reload.ssn).to eq("444-55-6666")
  end

  it "lets Anonymizable erase an encrypted field re-assigned its own value without decrypting it" do
    erasable = model do
      include ConcernsOnRails::Models::Anonymizable

      encryptable :ssn
      anonymizable :ssn, with: :redact
    end
    record = erasable.create!(ssn: "111-11-1111").reload
    record.assign_attributes(ssn: "111-11-1111")

    expect(record.anonymize!).to be(true)
    expect(record.ssn).to eq("[REDACTED]")
    expect(record.ssn_encrypted?).to be(true)
  end
end
