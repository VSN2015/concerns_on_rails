require "spec_helper"

# Audit 2026-10-10, TRANS-2. A `separator:` equal to the delimiter (the usual
# slip: `separator: ","` without `delimiter:`, whose default is "," too) or an
# empty one with decimals to show was accepted. formatted_price printed
# "€1,234,56" / "$1,23450", and the writer read that back as nil, so an edit
# form pre-filled with the formatted value wiped the stored amount.
describe ConcernsOnRails::Models::Monetizable do
  before do
    ActiveRecord::Schema.define do
      create_table :separator_products, force: true do |t|
        t.integer :price_cents
      end
    end
  end

  after do
    ActiveRecord::Base.connection.drop_table(:separator_products, if_exists: true)
  end

  def product_class(**options)
    Class.new(TestModel) do
      self.table_name = "separator_products"
      include ConcernsOnRails::Models::Monetizable

      monetizable :price_cents, **options
    end
  end

  it "refuses a separator equal to the delimiter at the macro" do
    expect { product_class(unit: "€", separator: ",") }
      .to raise_error(ArgumentError, /:separator must differ from the :delimiter/)
    expect { product_class(delimiter: ".", separator: ".") }
      .to raise_error(ArgumentError, /:separator must differ from the :delimiter/)
  end

  it "refuses an empty separator while there are decimals to show" do
    expect { product_class(separator: "") }.to raise_error(ArgumentError, /:separator must not be empty/)
    expect { product_class(separator: "", delimiter: "") }.to raise_error(ArgumentError, /:separator must not be empty/)
  end

  it "accepts an empty separator with precision 0, and distinct marks" do
    expect { product_class(separator: "", precision: 0) }.not_to raise_error
    expect { product_class(separator: "", delimiter: "", precision: 0) }.not_to raise_error
    expect { product_class(unit: "€", delimiter: ".", separator: ",") }.not_to raise_error
    expect { product_class(delimiter: "", separator: ".") }.not_to raise_error
  end

  it "applies the same checks to per-call formatting overrides" do
    product = product_class.new(price_cents: 123_456)

    expect { product.formatted_price(separator: ",") }
      .to raise_error(ArgumentError, /:separator must differ from the :delimiter/)
    expect { product.formatted_price(separator: "") }.to raise_error(ArgumentError, /:separator must not be empty/)
    expect { product.class.formatted_sum_price(delimiter: ".") }
      .to raise_error(ArgumentError, /:separator must differ from the :delimiter/)
    expect(product.formatted_price(unit: "€", delimiter: ".", separator: ",")).to eq("€1.234,56")
    expect(product.formatted_price(separator: "", precision: 0)).to eq("$1,235")
  end

  it "keeps a comma-separator field's formatted output readable back" do
    product = product_class(unit: "€", delimiter: ".", separator: ",").new(price_cents: 123_456)
    expect(product.formatted_price).to eq("€1.234,56")

    product.price = product.formatted_price
    expect(product.price_cents).to eq(123_456)
  end
end
