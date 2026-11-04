require "spec_helper"

# TRANS-S3 (audit 2026-10-29): Monetizable's writer only capped the magnitude at
# 10**24 major units, so `price = "1e18"` (1e20 cents) passed and the SAVE
# raised ActiveModel::RangeError (a 500) instead of the writer returning nil
# for oversized input, as it does for every other unreadable amount. The cents
# are now checked against the column's own range at assignment.
describe "Monetizable: an amount the cents column cannot hold" do
  before do
    ActiveRecord::Schema.define do
      create_table :money_range_items, force: true do |t|
        t.integer :price_cents, limit: 4
        t.bigint :big_cents
      end
    end
  end

  after { ActiveRecord::Base.connection.drop_table(:money_range_items, if_exists: true) }

  let(:klass) do
    Class.new(TestModel) do
      self.table_name = "money_range_items"
      include ConcernsOnRails::Models::Monetizable

      monetizable :price_cents
      monetizable :big_cents
    end
  end

  describe "a 4-byte integer column (limit: 4, about 21.4 million units)" do
    it "writes nil for an amount past the column and saves without raising" do
      item = klass.new(price: "1e18")

      expect(item.price_cents).to be_nil
      expect(item.price).to be_nil
      expect { item.save! }.not_to raise_error
    end

    it "writes nil just past the limit and keeps the largest representable amount" do
      item = klass.new
      item.price = "21474836.48" # 2**31 cents
      expect(item.price_cents).to be_nil
      item.price = "21474836.47"
      expect(item.price_cents).to eq(2_147_483_647)
      item.save!
      expect(item.reload.price_cents).to eq(2_147_483_647)
    end

    it "treats a negative amount past the column the same way" do
      expect(klass.new(price: "-1e18").price_cents).to be_nil
      expect(klass.new(price: "-21474836.48").price_cents).to eq(-2_147_483_648)
    end

    it "accepts a numeric (not only a String) amount" do
      expect(klass.new(price: 10**15).price_cents).to be_nil
      expect(klass.new(price: 12.5).price_cents).to eq(1250)
    end
  end

  describe "an 8-byte bigint column" do
    it "holds an amount a 4-byte column cannot, and writes nil past its own limit" do
      item = klass.new(big: "1e12")
      expect(item.big_cents).to eq(10**14)
      item.save!
      expect(item.reload.big_cents).to eq(10**14)

      expect(klass.new(big: "1e18").big_cents).to be_nil
      expect { klass.new(big: "1e18").save! }.not_to raise_error
    end
  end

  it "clears an earlier value when the new amount does not fit (like any unreadable amount)" do
    item = klass.new(price: "5.00")
    item.price = "1e18"

    expect(item.price_cents).to be_nil
  end
end
