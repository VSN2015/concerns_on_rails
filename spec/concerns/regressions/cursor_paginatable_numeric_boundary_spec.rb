require "spec_helper"

# Audit 2026-10-10 PARAM-9. A numeric boundary was cast through the column's
# type and bound if `serializable?` said so, but nothing checked a DECIMAL
# boundary against the column's precision, nor its size: `1e20` on a
# decimal(10,2) column — a value no row can hold, so no cursor ever minted
# it — decoded and bound, and the walk silently ended with an empty 200. And
# `"1e5000000"` was expanded by BigDecimal#to_s("F") into a 5,000,060-character
# SQL literal (`"1e99999999"`, 12 bytes, is ~100 MB per request) — the
# amplification Support::NumericOperand bounds for Filterable. A plain numeric
# boundary is now read through NumericOperand and must be :exact.
describe ConcernsOnRails::Controllers::CursorPaginatable do
  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :priced_items, force: true do |t|
        t.decimal :price, precision: 10, scale: 2
        t.decimal :weight
        t.float :rating
      end
    end
    stub_const("PricedItem", Class.new(TestModel) { self.table_name = "priced_items" })
    [[12.5, 1, 0.5], [12.5, 2, 1.5], [99.99, 3, 2.5], [1, 4, 3.5]].each do |price, weight, rating|
      PricedItem.create!(price: price, weight: weight, rating: rating)
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  def controller_for(order)
    Class.new(FakeController) do
      include ConcernsOnRails::Controllers::CursorPaginatable

      cursor_paginate_by order: order, per_page: 1
    end
  end

  def token(column, boundary)
    payload = { "t" => "priced_items", "o" => ["#{column}:asc", "id:asc"], "d" => "next", "v" => [boundary, 1] }
    [JSON.generate(payload)].pack("m0").tr("+/", "-_").delete("=")
  end

  def page(column, boundary)
    controller_for({ column => :asc }).new(params: { cursor: token(column, boundary) }).cursor_paginated(PricedItem.all)
  end

  it "refuses a decimal boundary beyond the column's precision, or too long / too wide to read" do
    %w[1e20 100000000 1e5000000 1e99999999].each do |huge|
      expect { page(:price, huge) }
        .to raise_error(ConcernsOnRails::Controllers::CursorPaginatable::InvalidCursor), "accepted: #{huge}"
    end
    expect { page(:weight, "1e5000000") }.to raise_error(ConcernsOnRails::Controllers::CursorPaginatable::InvalidCursor)
    expect { page(:price, "1#{'0' * 120}") }.to raise_error(ConcernsOnRails::Controllers::CursorPaginatable::InvalidCursor)
  end

  it "refuses a decimal boundary finer than the column's scale, and a non-number" do
    ["12.345", "abc", true].each do |tampered|
      expect { page(:price, tampered) }
        .to raise_error(ConcernsOnRails::Controllers::CursorPaginatable::InvalidCursor), "accepted: #{tampered.inspect}"
    end
  end

  it "still walks decimal, float and integer columns through their minted boundaries" do
    { price: :asc, weight: :asc, rating: :asc }.each do |column, dir|
      klass = controller_for({ column => dir })
      seen = []
      cursor = nil
      6.times do
        controller = klass.new(params: { cursor: cursor })
        seen.concat(controller.cursor_paginated(PricedItem.all).map(&:id))
        cursor = controller.cursor_pagination_meta[:next_cursor]
        break unless cursor
      end
      expect(seen).to eq(PricedItem.order(column => dir, id: dir).pluck(:id)), column.to_s
    end
  end

  it "accepts an in-range decimal boundary written either way" do
    expect(page(:price, "12.5").map(&:price)).to eq([BigDecimal("12.5")])
    expect(page(:price, "0.125e2").map(&:price)).to eq([BigDecimal("12.5")])
  end
end
