require "spec_helper"

# Audit 2026-10-10, TRANS-10. Digit grouping never starts with a "0" group,
# but both grouping patterns accepted one: a European user's "0,500" (0.5)
# became 500.00 in a default ","-delimited field, and "0.500" became 500 in a
# € field (delimiter "."). Each is a silent, persisted 1000x error.
describe ConcernsOnRails::Models::Monetizable do
  before do
    ActiveRecord::Schema.define do
      create_table :leading_zero_products, force: true do |t|
        t.integer :price_cents
      end
    end
  end

  after do
    ActiveRecord::Base.connection.drop_table(:leading_zero_products, if_exists: true)
  end

  def product_class(**options)
    Class.new(TestModel) do
      self.table_name = "leading_zero_products"
      include ConcernsOnRails::Models::Monetizable

      monetizable :price_cents, **options
    end
  end

  def cents_for(klass, input)
    record = klass.new
    record.price = input
    record.price_cents
  end

  it "never reads a leading-zero group as grouped thousands in a ','-delimited field" do
    dollars = product_class

    { "0,500" => nil, "$0,500" => nil, "-0,250" => nil, "0,500,000" => nil,
      "1,500" => 150_000, "0.50" => 50, "$1,234.50" => 123_450 }.each do |input, cents|
      expect(cents_for(dollars, input)).to eq(cents), "#{input.inspect} => #{cents.inspect}"
    end
  end

  it "reads a leading-zero '.' group as a decimal in a '.'-delimited field" do
    euro = product_class(unit: "€", delimiter: ".", separator: ",")

    { "0.500" => 50, "€0.500" => 50, "-0.250" => -25, "0,50" => 50, "0.500.000" => nil,
      "1.234" => 123_400, "€1.234,50" => 123_450 }.each do |input, cents|
      expect(cents_for(euro, input)).to eq(cents), "#{input.inspect} => #{cents.inspect}"
    end
  end

  it "still round-trips formatted amounts below one" do
    [product_class, product_class(unit: "€", delimiter: ".", separator: ",")].each do |klass|
      [0, 5, 50, 99, -50].each do |amount|
        formatted = klass.new(price_cents: amount).formatted_price
        expect(cents_for(klass, formatted)).to eq(amount), formatted.inspect
      end
    end
  end

  it "keeps Support::Money.parse from scaling a leading-zero group" do
    money = ConcernsOnRails::Support::Money
    euro = { unit: "€", delimiter: ".", separator: "," }

    expect(money.parse("0,500", {})).to be_nil
    expect(money.parse("0.500", euro)).to eq(BigDecimal("0.5"))
    expect(money.parse("-0.250", euro)).to eq(BigDecimal("-0.25"))
  end
end
