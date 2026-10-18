require "spec_helper"

# Audit 2026-10-10, TRANS-11. `precision:` defaulted to 2 whatever
# `subunit_to_unit:` was, so a 3-decimal currency (KWD, BHD, OMR, TND, JOD:
# 1000 fils) formatted 1.999 KD as "KD2.00", and assigning that formatted
# value back (an edit form) stored 2000 instead of 1999. The default is now
# max(2, the subunit's decimal places when it is a power of ten).
describe ConcernsOnRails::Models::Monetizable do
  before do
    ActiveRecord::Schema.define do
      create_table :subunit_products, force: true do |t|
        t.integer :price_cents
      end
    end
  end

  after do
    ActiveRecord::Base.connection.drop_table(:subunit_products, if_exists: true)
  end

  def product_class(**options)
    Class.new(TestModel) do
      self.table_name = "subunit_products"
      include ConcernsOnRails::Models::Monetizable

      monetizable :price_cents, **options
    end
  end

  it "round-trips the formatted value of a 3-decimal currency" do
    product = product_class(unit: "KD", subunit_to_unit: 1000).new(price_cents: 1999)
    expect(product.formatted_price).to eq("KD1.999")

    product.price = product.formatted_price # an edit form pre-filled with the display value
    expect(product.price_cents).to eq(1999)
  end

  it "shows every decimal a power-of-ten subunit carries, in the aggregates too" do
    klass = product_class(unit: "KD", subunit_to_unit: 1000)
    klass.create!(price_cents: 1_234_567)

    expect(klass.new(price_cents: 1_234_567).formatted_price).to eq("KD1,234.567")
    expect(klass.formatted_sum_price).to eq("KD1,234.567")
    expect(product_class(subunit_to_unit: 10_000).new(price_cents: 12_345).formatted_price).to eq("$1.2345")
  end

  it "keeps two decimals for 100-, 10-, 1- and non-power-of-ten subunits" do
    expect(product_class.new(price_cents: 199_999).formatted_price).to eq("$1,999.99")
    expect(product_class(unit: "¥", subunit_to_unit: 1).new(price_cents: 1234).formatted_price).to eq("¥1,234.00")
    expect(product_class(subunit_to_unit: 10).new(price_cents: 15).formatted_price).to eq("$1.50")
    expect(product_class(subunit_to_unit: 5).new(price_cents: 7).formatted_price).to eq("$1.40")
  end

  it "leaves an explicit precision: as given" do
    expect(product_class(subunit_to_unit: 1000, precision: 2).new(price_cents: 1999).formatted_price).to eq("$2.00")
    expect(product_class(unit: "¥", subunit_to_unit: 1, precision: 0).new(price_cents: 1234).formatted_price)
      .to eq("¥1,234")
  end

  it "derives the default from a per-call subunit_to_unit: override as well" do
    product = product_class.new(price_cents: 1999)

    expect(product.formatted_price(subunit_to_unit: 1000)).to eq("$1.999")
    expect(product.formatted_price(subunit_to_unit: 1000, precision: 1)).to eq("$2.0")
    expect(product_class(precision: 2).new(price_cents: 1999).formatted_price(subunit_to_unit: 1000)).to eq("$2.00")
  end

  it "derives it in Support::Money.format when precision is not given" do
    money = ConcernsOnRails::Support::Money

    expect(money.format(1999, unit: "KD", subunit_to_unit: 1000)).to eq("KD1.999")
    expect(money.format(199_999)).to eq("$1,999.99")
  end
end
