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

      encryptable :amount, type: :decimal
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
