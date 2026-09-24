require "spec_helper"

describe ConcernsOnRails::Models::Monetizable do
  before do
    ActiveRecord::Schema.define do
      create_table :monetizable_products, force: true do |t|
        t.integer :price_cents
        t.integer :shipping_cents
        t.integer :total_cents
        t.integer :balance
      end
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end

    Object.send(:remove_const, :MonetizableProduct) if Object.const_defined?(:MonetizableProduct)
  end

  def product_class(&body)
    Class.new(TestModel) do
      self.table_name = "monetizable_products"
      include ConcernsOnRails::Models::Monetizable

      class_eval(&body)
    end
  end

  describe "derived accessors" do
    it "reads cents as a BigDecimal in major units" do
      klass = product_class { monetizable :price_cents }
      expect(klass.new(price_cents: 1999).price).to eq(BigDecimal("19.99"))
    end

    it "writes major units rounded to whole cents" do
      klass = product_class { monetizable :price_cents }

      product = klass.new
      product.price = 19.99
      expect(product.price_cents).to eq(1999)

      product.price = "5"
      expect(product.price_cents).to eq(500)

      product.price = 19.999 # rounds half-up
      expect(product.price_cents).to eq(2000)
    end

    it "formats the amount for display" do
      klass = product_class { monetizable :price_cents }
      expect(klass.new(price_cents: 123_456).formatted_price).to eq("$1,234.56")
    end

    it "treats nil as nil in all three accessors" do
      klass = product_class { monetizable :price_cents }

      product = klass.new(price_cents: nil)
      expect(product.price).to be_nil
      expect(product.formatted_price).to be_nil

      product.price = 10
      product.price = nil
      expect(product.price_cents).to be_nil
    end
  end

  # The writer fed Strings straight to BigDecimal, so the concern's OWN
  # formatted output ("$19.99", "1,234.50") came back as nil, and a
  # non-finite Float raised FloatDomainError out of the setter.
  describe "writer input parsing" do
    def cents_for(klass, value, field: :price)
      product = klass.new
      product.public_send("#{field}=", value)
      product.public_send("#{field}_cents")
    end

    it "accepts the formatted output and delimited amounts" do
      klass = product_class { monetizable :price_cents }

      expect(cents_for(klass, "$19.99")).to eq(1999)
      expect(cents_for(klass, "1,234.50")).to eq(123_450)
      expect(cents_for(klass, " $1,234.56 ")).to eq(123_456)
      expect(cents_for(klass, "-$5.00")).to eq(-500)
      expect(cents_for(klass, "$ 7")).to eq(700)
      expect(cents_for(klass, " 12.5 ")).to eq(1250)
    end

    it "round-trips formatted_<name> back through the writer" do
      klass = product_class { monetizable :price_cents }
      [123_456, -500, 0, 7, 100_000_000].each do |cents|
        expect(cents_for(klass, klass.new(price_cents: cents).formatted_price)).to eq(cents)
      end
    end

    it "honours a comma-separator locale's unit, delimiter and separator" do
      klass = product_class { monetizable :total_cents, unit: "€", delimiter: ".", separator: "," }

      expect(cents_for(klass, "€1.999,99", field: :total)).to eq(199_999)
      expect(cents_for(klass, "1.234,5 €", field: :total)).to eq(123_450)
      expect(cents_for(klass, "19,99", field: :total)).to eq(1999)
      # A plain decimal String is still read canonically (no regression).
      expect(cents_for(klass, "19.99", field: :total)).to eq(1999)
      expect(cents_for(klass, klass.new(total_cents: 123_456).formatted_total, field: :total)).to eq(123_456)
    end

    # A finite but astronomically large amount got past the finiteness check
    # and raised FloatDomainError from the cents rounding; a long exponent or
    # digit string could also be used to burn CPU in BigDecimal.
    it "casts overflowing and oversized input to nil instead of raising" do
      klass = product_class { monetizable :price_cents }

      ["1e100000000", "-1e100000000", "1e-100000000", "9" * 10_000, "1#{'0' * 200}", "1e99999999999999999999",
       BigDecimal("1e100000000"), 10**400, 1e300].each do |huge|
        expect(cents_for(klass, huge)).to be_nil, "#{huge.to_s[0, 30].inspect} should cast to nil"
      end
      expect(cents_for(klass, "1e3")).to eq(100_000)
      expect(cents_for(klass, "92233720368547758.07")).to eq(9_223_372_036_854_775_807)
    end

    # In a "," separator field, "1.234" used to be read as the decimal 1.234
    # (123 cents) while "€1.234" was 1234.00 and "1.234.567" was 1234567.
    it "reads '.'-grouped thousands consistently in a comma-separator field" do
      klass = product_class { monetizable :total_cents, unit: "€", delimiter: ".", separator: "," }

      { "1.234" => 123_400, "€1.234" => 123_400, "1.234 €" => 123_400, "-1.234" => -123_400,
        "1.234.567" => 123_456_700, "€1.234.567" => 123_456_700, "19.99" => 1999, "1.5" => 150,
        "€19.99" => 1999, "1.234,5" => 123_450, "12.34.5" => nil }.each do |input, cents|
        expect(cents_for(klass, input, field: :total)).to eq(cents), "#{input.inspect} => #{cents.inspect}"
      end
    end

    it "only strips the unit at the start or the end of the amount" do
      klass = product_class { monetizable :price_cents }
      euro = product_class { monetizable :total_cents, unit: "EUR ", delimiter: ".", separator: "," }

      expect(cents_for(klass, "5$5")).to be_nil
      expect(cents_for(klass, "1$,234")).to be_nil
      expect(cents_for(klass, "$5$")).to be_nil
      expect(cents_for(klass, "5 $")).to eq(500)
      expect(cents_for(klass, "- $5")).to eq(-500)
      expect(cents_for(klass, "$-5")).to eq(-500)
      expect(cents_for(euro, "EUR 3.500,50", field: :total)).to eq(350_050)
      expect(cents_for(euro, "3.500,50 EUR", field: :total)).to eq(350_050)
      expect(cents_for(euro, "3.5EUR00", field: :total)).to be_nil
    end

    it "casts non-finite numbers and garbage to nil instead of raising" do
      klass = product_class { monetizable :price_cents }

      [Float::NAN, Float::INFINITY, -Float::INFINITY, BigDecimal("NaN"), "NaN", "Infinity",
       "abc", "", "  ", "$", "1.2.3", "12abc", "($5.00)", "1,5", "12,34.5", "$$5"].each do |garbage|
        expect(cents_for(klass, garbage)).to be_nil, "#{garbage.inspect} should cast to nil"
      end
    end
  end

  describe "options" do
    it "names the methods via :as" do
      klass = product_class { monetizable :shipping_cents, as: :shipping }

      product = klass.new
      product.shipping = 4.5
      expect(product.shipping_cents).to eq(450)
      expect(product.formatted_shipping).to eq("$4.50")
    end

    it "honors unit / delimiter / separator" do
      klass = product_class do
        monetizable :total_cents, unit: "€", delimiter: ".", separator: ","
      end

      expect(klass.new(total_cents: 199_999).formatted_total).to eq("€1.999,99")
    end
  end

  describe "configuration errors" do
    it "raises when the cents column name cannot derive a money name and no :as is given" do
      expect { product_class { monetizable :balance } }
        .to raise_error(ArgumentError, /cannot derive a money method name/)
    end

    it "raises when :as is combined with multiple fields" do
      expect { product_class { monetizable :price_cents, :shipping_cents, as: :amount } }
        .to raise_error(ArgumentError, /:as cannot be combined with multiple fields/)
    end

    it "raises when no fields are given" do
      expect { product_class { monetizable } }
        .to raise_error(ArgumentError, /at least one field is required/)
    end

    it "raises when the column does not exist" do
      expect { product_class { monetizable :missing_cents } }
        .to raise_error(ArgumentError, /does not exist in the database/)
    end

    it "raises when :subunit_to_unit is not positive" do
      expect { product_class { monetizable :price_cents, subunit_to_unit: 0 } }
        .to raise_error(ArgumentError, /:subunit_to_unit must be a positive integer/)
    end

    it "coerces a String :subunit_to_unit (1.26 — the writer silently nil'd, the reader raised)" do
      klass = product_class { monetizable :price_cents, subunit_to_unit: "100" }
      product = klass.new

      product.price = 19.99
      expect(product.price_cents).to eq(1999)
      expect(product.price).to eq(BigDecimal("19.99"))
      expect(product.formatted_price).to eq("$19.99")
    end
  end

  describe "Support::Money formatting edge cases" do
    it "does not print a spurious minus for an amount that rounds to zero" do
      expect(ConcernsOnRails::Support::Money.format(-1, subunit_to_unit: 100_000)).to eq("$0.00")
    end
  end

  describe "class-level aggregates and formatting overrides" do
    let(:klass) do
      product_class do
        monetizable :price_cents
        monetizable :total_cents, unit: "€", delimiter: ".", separator: ","
      end
    end

    before do
      klass.create!(price_cents: 1999, total_cents: 100_000)
      klass.create!(price_cents: 501, total_cents: 250_050)
      klass.create!(price_cents: nil, total_cents: 0)
    end

    it "sum_/average_/minimum_/maximum_<name> return BigDecimals in major units" do
      expect(klass.sum_price).to eq(BigDecimal("25.00"))
      expect(klass.average_price).to eq(BigDecimal("12.5")) # AVG skips the NULL row
      expect(klass.minimum_price).to eq(BigDecimal("5.01"))
      expect(klass.maximum_price).to eq(BigDecimal("19.99"))
      expect(klass.sum_price).to be_a(BigDecimal)
    end

    it "is relation-aware and nil-safe on empty sets" do
      expect(klass.where("price_cents > 1000").sum_price).to eq(BigDecimal("19.99"))
      expect(klass.where(total_cents: 0).sum_total).to eq(0)
      expect(klass.none.sum_price).to eq(0)
      expect(klass.none.average_price).to be_nil
      expect(klass.none.maximum_price).to be_nil
    end

    it "maps a grouped relation's aggregate instead of feeding the Hash to BigDecimal" do
      grouped = klass.group(:total_cents).sum_price
      expect(grouped[100_000]).to eq(BigDecimal("19.99"))
      expect(grouped[250_050]).to eq(BigDecimal("5.01"))
      expect(grouped[0]).to eq(0) # SUM over that group's single NULL row, as AR reports it

      formatted = klass.group(:total_cents).formatted_sum_price
      expect(formatted[100_000]).to eq("$19.99")
      expect(formatted[250_050]).to eq("$5.01")
      expect(formatted[0]).to eq("$0.00")
    end

    it "formatted_<aggregate>_<name> uses the field's formatting options" do
      expect(klass.formatted_sum_price).to eq("$25.00")
      expect(klass.formatted_average_price).to eq("$12.50")
      expect(klass.formatted_sum_total).to eq("€3.500,50")
      expect(klass.where("price_cents > 1000").formatted_maximum_price).to eq("$19.99")
      expect(klass.none.formatted_average_price).to be_nil
    end

    it "formatted_<name> and the formatted aggregates accept per-call overrides" do
      expect(klass.new(price_cents: 123_456).formatted_price(unit: "€", delimiter: ".", separator: ",")).to eq("€1.234,56")
      expect(klass.formatted_sum_price(unit: "£")).to eq("£25.00")
      expect(klass.new(price_cents: 1999).formatted_price).to eq("$19.99") # defaults untouched
      expect { klass.new(price_cents: 1).formatted_price(units: "x") }
        .to raise_error(ArgumentError, /unknown formatting option\(s\): units/)
    end

    it "coerces per-call precision:/subunit_to_unit: overrides the way the macro does" do
      product = klass.new(price_cents: 123_456)

      expect(product.formatted_price(subunit_to_unit: "100")).to eq("$1,234.56")
      expect(product.formatted_price(precision: "1")).to eq("$1,234.6")
      expect(klass.formatted_sum_price(subunit_to_unit: "1000", precision: "3")).to eq("$2.500")
      expect { product.formatted_price(subunit_to_unit: 0) }
        .to raise_error(ArgumentError, /:subunit_to_unit must be a positive integer/)
      expect { product.formatted_price(precision: "two") }
        .to raise_error(ArgumentError, /:precision must be an integer/)
    end

    it "coerces a String :precision at the macro too" do
      money = product_class { monetizable :price_cents, precision: "0" }

      expect(money.new(price_cents: 123_456).formatted_price).to eq("$1,235")
      expect { product_class { monetizable :price_cents, precision: 1.5 } }
        .to raise_error(ArgumentError, /:precision must be an integer/)
    end

    it "derives the aggregate names from as: too" do
      amounts = product_class { monetizable :balance, as: :amount, unit: "£" }
      amounts.delete_all
      amounts.create!(balance: 100)
      amounts.create!(balance: 250)
      expect(amounts.sum_amount).to eq(BigDecimal("3.50"))
      expect(amounts.formatted_sum_amount).to eq("£3.50")
    end
  end
end
