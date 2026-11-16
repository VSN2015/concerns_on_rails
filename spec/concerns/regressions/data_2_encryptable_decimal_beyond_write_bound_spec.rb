require "spec_helper"

describe "Encryptable :decimal past the write bound is never destroyed" do
  before do
    ActiveRecord::Base.logger = nil
    ActiveRecord::Schema.define do
      create_table :data_enc_decimals, force: true do |t|
        t.text :amount
        t.string :amount_bidx
      end
    end
    @old = ConcernsOnRails.encryption.key
    @old_id = ConcernsOnRails.encryption.key_id
    @old_prev = ConcernsOnRails.encryption.previous_keys
    ConcernsOnRails.configure_encryption do |c|
      c.key = "a" * 64
      c.key_id = 0
      c.previous_keys = {}
    end
  end
  after do
    ConcernsOnRails.configure_encryption do |c|
      c.key = @old
      c.key_id = @old_id
      c.previous_keys = @old_prev
    end
    ActiveRecord::Base.connection.drop_table(:data_enc_decimals, if_exists: true)
  end

  let(:klass) do
    Class.new(TestModel) do
      self.table_name = "data_enc_decimals"
      include ConcernsOnRails::Models::Encryptable

      encryptable :amount, type: :decimal, blind_index: { column: :amount_bidx }
    end
  end

  # A value stored before the 1.36 write bound (or by another writer). Returns the envelope.
  def store_huge(id)
    env = ConcernsOnRails::Support::Encryptor.encrypt("1#{"0" * 1100}", key: "a" * 64, key_id: 0)
    klass.where(id: id).update_all(["amount = ?", env])
    env
  end

  def rotate_key
    ConcernsOnRails.configure_encryption do |c|
      c.key = "b" * 64
      c.key_id = 1
      c.previous_keys = { 0 => "a" * 64 }
    end
  end

  # The column as stored (pluck would run the type and decrypt it).
  def raw(id) = ActiveRecord::Base.connection.select_value("SELECT amount FROM data_enc_decimals WHERE id = #{id.to_i}")

  # The read agrees with the write bound: a value past it reads nil (like a field
  # that cannot be decrypted), so rotation refuses it and an edit cannot NULL it.
  it "reads a value past the write bound as nil" do
    id = klass.create!.id
    store_huge(id)
    expect(klass.find(id).amount).to be_nil
  end

  it "reencrypt! leaves the ciphertext alone instead of writing NULL" do
    id = klass.create!.id
    env = store_huge(id)
    rotate_key
    expect(klass.find(id).reencrypt!).to be(false)
    expect(raw(id)).to eq(env)
  end

  it "reencrypt_all! never NULLs it and still rotates its siblings" do
    huge = klass.create!.id
    env = store_huge(huge)
    small = klass.create!(amount: "12.5").id
    rotate_key
    klass.reencrypt_all!
    expect(raw(huge)).to eq(env)
    expect(klass.find(small).amount).to eq(BigDecimal("12.5"))
    expect(klass.find(small).amount_key_id).to eq(1)
  end

  it "re-assigning the value read does not save NULL over it" do
    id = klass.create!.id
    env = store_huge(id)
    rec = klass.find(id)
    rec.amount = rec.amount # rubocop:disable Lint/SelfAssignment
    rec.save!
    expect(raw(id)).to eq(env)
  end

  it "still reads a long, in-bound stored decimal exactly" do
    id = klass.create!.id
    digits = "1.#{"3" * 150}"
    klass.where(id: id).update_all(["amount = ?", ConcernsOnRails::Support::Encryptor.encrypt(digits, key: "a" * 64, key_id: 0)])
    expect(klass.find(id).amount).to eq(BigDecimal(digits))
  end
end
