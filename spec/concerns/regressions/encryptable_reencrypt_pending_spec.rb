require "spec_helper"

# Audit v1.36.2 A-1 / A-3.
describe "Encryptable reencrypt! and blank ciphertext" do
  let(:old_key) { "concerns-on-rails-encryptable-test-key" }
  let(:new_key) { "concerns-on-rails-encryptable-rotated-key" }

  before do
    ConcernsOnRails.encryption.key = old_key
    ConcernsOnRails.encryption.key_id = 0
    ConcernsOnRails.encryption.previous_keys = {}
    ActiveRecord::Schema.define do
      create_table :reenc_pendings, force: true do |t|
        t.text :ssn
        t.text :ssn_bidx
        t.text :email
        t.string :name
        t.string :notes, null: false, default: "" # MySQL: TEXT takes no default
      end
    end
  end

  after do
    ConcernsOnRails.encryption.key = nil
    ConcernsOnRails.encryption.key_id = 0
    ConcernsOnRails.encryption.previous_keys = {}
    ActiveRecord::Base.connection.drop_table(:reenc_pendings)
  end

  let(:klass) do
    Class.new(TestModel) do
      self.table_name = "reenc_pendings"
      include ConcernsOnRails::Models::Encryptable

      encryptable :ssn, blind_index: { column: :ssn_bidx }
      encryptable :email, :notes
    end
  end

  def rotate!
    ConcernsOnRails.configure_encryption do |c|
      c.key = new_key
      c.key_id = 1
      c.previous_keys = { 0 => old_key }
    end
  end

  it "keeps pending edits (skipped field and unrelated attributes) after rotating another field" do
    record = klass.find(klass.create!(ssn: "111-11-1111", email: "a@example.com").id)
    rotate!
    record.email = "edited@example.com"
    record.name = "renamed"

    expect(record.reencrypt!).to be(true)
    expect(record.email).to eq("edited@example.com")
    expect(record.name).to eq("renamed")
    expect(record.changed).to contain_exactly("email", "name")
    expect(record.ssn_key_id).to eq(1)
    expect(record.ssn).to eq("111-11-1111")
    expect(record.ssn_changed?).to be(false)
    expect(record.ssn_bidx_changed?).to be(false)

    record.save!
    fresh = klass.find(record.id)
    expect([fresh.email, fresh.name, fresh.ssn]).to eq(["edited@example.com", "renamed", "111-11-1111"])
    expect(fresh.email_key_id).to eq(1)
    expect(klass.find_by_ssn("111-11-1111")&.id).to eq(record.id)
  end

  it "leaves a clean record exactly as a reload would" do
    record = klass.find(klass.create!(ssn: "111-11-1111", email: "a@example.com").id)
    rotate!
    expect(record.reencrypt!).to be(true)
    expect(record.changed?).to be(false)
    expect(record.ssn_key_id).to eq(1)
    expect(record.email_key_id).to eq(1)
  end

  it "does not raise for the key id of a stored \"\" column default" do
    record = klass.create!(ssn: "111-11-1111")
    expect(record.notes_ciphertext).to eq("")
    expect(record.notes_key_id).to be_nil
  end

  it "leaves a stored \"\" untouched while rotating another field" do
    record = klass.find(klass.create!(ssn: "111-11-1111").id)
    rotate!
    expect(record.reencrypt!).to be(true)
    expect(record.notes_ciphertext).to eq("")
    expect(klass.connection.select_value("SELECT notes FROM reenc_pendings WHERE id = #{record.id}")).to eq("")
    expect(klass.reencrypt_all!).to eq(0)
  end

  it "does not count or rewrite blank (\"\") rows as needing rotation" do
    klass.create!(ssn: "111-11-1111")
    rotate!
    expect(klass.needs_reencryption(:notes).count).to eq(0)
  end
end
