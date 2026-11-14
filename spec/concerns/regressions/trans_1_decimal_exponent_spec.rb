require "spec_helper"

# TRANS-1 / ENC-DEC: a short `:decimal` input ("1e5000000") must never expand
# into megabytes (Storable's stored String, its where_ operand, Encryptable's plaintext).
RSpec.describe "decimal exponent bound (Storable + Encryptable)" do
  before do
    ConcernsOnRails.configure_encryption { |c| c.key = "k" * 32 }
    ActiveRecord::Schema.define do
      create_table(:dec_rows, force: true) do |t|
        t.text :settings
        t.text :amount
        t.string :amount_bidx
      end
    end
  end
  after { ActiveRecord::Base.connection.drop_table(:dec_rows) }

  def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  let(:storable_class) do
    Class.new(TestModel) do
      self.table_name = "dec_rows"
      include ConcernsOnRails::Storable

      storable_by :settings, price: { type: :decimal }
    end
  end

  let(:encryptable_class) do
    Class.new(TestModel) do
      self.table_name = "dec_rows"
      include ConcernsOnRails::Models::Encryptable

      encryptable :amount, type: :decimal, blind_index: true
    end
  end

  describe "Storable" do
    ["1e5000000", "-1e5000000", "1e-5000000", "Infinity", "-Infinity", "NaN", "1_000", "1e1001"].each do |input|
      it "casts #{input.inspect} to nil without expanding it" do
        record = storable_class.new
        record.price = input
        expect(record.price).to be_nil
        expect(record.settings.to_s.bytesize).to be < 100
      end
    end

    it "casts a huge BigDecimal handed in directly to nil" do
      record = storable_class.new
      record.price = BigDecimal("1e5000000")
      expect(record.price).to be_nil
    end

    it "still stores ordinary decimals exactly" do
      record = storable_class.new
      record.price = "1234.5678"
      expect(record.price).to eq(BigDecimal("1234.5678"))
      record.price = BigDecimal("1e1000")
      expect(record.price).to eq(BigDecimal("1e1000"))
      record.price = 12
      expect(record.price).to eq(12)
    end

    it "refuses a huge where_<key> operand quickly" do
      started = clock
      expect { storable_class.where_price("1e20000000") }.to raise_error(ArgumentError, /not a valid :decimal/)
      expect(clock - started).to be < 0.2
    end
  end

  describe "values near the bounds and Float precision (round 2)" do
    let(:legit) { [BigDecimal("1e99"), BigDecimal("1e-99"), BigDecimal(1).div(3, 120), BigDecimal("1e999")] }

    it "Storable writes and re-reads them, and keeps a Float's 17th digit" do
      record = storable_class.new
      legit.each do |value|
        record.price = value
        expect(record.price).to eq(value)
        echo = record.settings
        record.price = JSON.parse(echo)["price"] # writer echo of its own stored form
        expect(record.price).to eq(value)
      end
      record.price = 0.1 + 0.2
      expect(record.price).to eq(BigDecimal("0.30000000000000004"))
    end

    it "Storable refuses a multi-megabyte Integer without building it" do
      record = storable_class.new
      started = clock
      record.price = 10**200_000
      expect(record.price).to be_nil
      expect(clock - started).to be < 0.2
    end

    it "Encryptable round-trips them, in memory and after reload" do
      legit.each do |value|
        record = encryptable_class.create!(amount: value)
        expect(record.amount).to eq(value)
        expect(record.reload.amount).to eq(value)
        expect(encryptable_class.find_by_amount(value)).to eq(record)
      end
      expect(encryptable_class.create!(amount: "1e99").reload.amount).to eq(BigDecimal("1e99"))
      expect(encryptable_class.create!(amount: "1e-99").reload.amount).to eq(BigDecimal("1e-99"))
    end

    it "Encryptable keeps a Float's 17th digit and finds it by blind index" do
      record = encryptable_class.create!(amount: 0.1 + 0.2)
      expect(record.reload.amount).to eq(BigDecimal("0.30000000000000004"))
      expect(encryptable_class.find_by_amount(0.1 + 0.2)).to eq(record)
    end

    it "Encryptable where_<field> with a huge operand finds nothing, without expanding it" do
      encryptable_class.create!(amount: "1")
      started = clock
      expect(encryptable_class.where_amount("1e20000000").to_a).to eq([])
      expect(encryptable_class.find_by_amount("1e20000000")).to be_nil
      expect(clock - started).to be < 0.5
    end

    it "reencrypt! and reencrypt_all! keep such values readable" do
      records = legit.map { |value| encryptable_class.create!(amount: value) }
      ConcernsOnRails.configure_encryption do |c|
        c.key = "r" * 32
        c.key_id = 1
        c.previous_keys = { 0 => "k" * 32 }
      end
      expect(encryptable_class.find(records.first.id).reencrypt!).to be(true)
      encryptable_class.reencrypt_all!
      expect(records.map { |r| encryptable_class.find(r.id).amount }).to eq(legit)
      expect(encryptable_class.find_by_amount(legit.last)).to eq(records.last)
    end
  end

  describe "Encryptable" do
    it "does not expand a short exponent string into a multi-megabyte ciphertext" do
      record = encryptable_class.new(amount: "1e5000000")
      started = clock
      record.save!
      expect(clock - started).to be < 0.5
      expect(record.amount_ciphertext.to_s.bytesize).to be < 10_000
      expect(record.reload.amount).to be_nil
    end

    it "treats Infinity/NaN as uncastable" do
      expect(encryptable_class.new(amount: "Infinity").amount).to be_nil
      expect(encryptable_class.new(amount: "NaN").amount).to be_nil
    end

    it "still round-trips an ordinary decimal" do
      record = encryptable_class.create!(amount: "1234.50")
      expect(record.reload.amount).to eq(BigDecimal("1234.5"))
    end
  end
end
