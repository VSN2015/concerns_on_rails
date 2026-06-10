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
  end

  describe "Support::Money formatting edge cases" do
    it "does not print a spurious minus for an amount that rounds to zero" do
      expect(ConcernsOnRails::Support::Money.format(-1, subunit_to_unit: 100_000)).to eq("$0.00")
    end
  end
end
