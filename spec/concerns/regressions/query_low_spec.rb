require "spec_helper"

# Three LOW findings in the query-side controller concerns.
describe "query-side controller concerns, LOW findings" do
  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :query_low_rows, force: true do |t|
        t.string :name
        t.integer :stock
        t.decimal :weight
      end
    end
    stub_const("QueryLowRow", Class.new(TestModel) do
      self.table_name = "query_low_rows"
      alias_attribute :qty, :stock
    end)
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      ActiveRecord::Base.connection.drop_table(table) unless table == "schema_migrations"
    end
  end

  describe "Sortable follows a chain of alias_attribute keys" do
    it "orders a two- and three-deep alias key by its column" do
      # Newer Rails refuses an alias of an alias when the attribute is used; the chain only exists on the older lines.
      skip "Rails #{ActiveRecord.version} refuses an alias of an alias" if ActiveRecord.version >= Gem::Version.new("7.2")

      QueryLowRow.alias_attribute :amount, :qty
      QueryLowRow.alias_attribute :level, :amount
      3.times { |i| QueryLowRow.create!(name: "r#{i}", stock: 3 - i) }
      klass = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Sortable

        sortable_by :amount, :level
      end

      %w[amount level].each do |key|
        expect(klass.new(params: { sort: key }).sorted(QueryLowRow.all).map(&:name)).to eq(%w[r2 r1 r0]), key
        expect(klass.new(params: { sort: "-#{key}" }).sorted(QueryLowRow.all).map(&:name)).to eq(%w[r0 r1 r2]), key
      end
    end
  end

  describe "Filterable reads a numeric column's operand as a number whatever type: says" do
    let(:klass) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable

        filter_by :stock, type: :string, operators: true
      end
    end

    before { [0, 5, 10].each { |stock| QueryLowRow.create!(name: "s#{stock}", stock: stock) } }

    def names(params)
      klass.new(params: params).filtered(QueryLowRow.all).pluck(:name).sort
    end

    it "fails closed on a non-number instead of reading its numeric prefix" do
      expect(names(stock_gt: "abc")).to eq([])
      expect(names(stock_lt: "abc")).to eq([])
      expect(names(stock: "abc")).to eq([])
      expect(names(stock_gt: "4abc")).to eq([]) # was `stock > 4`
    end

    it "still compares a real number exactly" do
      expect(names(stock_gt: "4")).to eq(%w[s10 s5])
      expect(names(stock_gt: "4.5")).to eq(%w[s10 s5])
      expect(names(stock_gte: "5.5")).to eq(%w[s10])
    end
  end

  describe "Filterable keeps a non-String type: over an integer column (epoch seconds)" do
    let(:epoch) { Time.utc(2026, 1, 1).to_i }

    before do
      QueryLowRow.create!(name: "old", stock: epoch - 100)
      QueryLowRow.create!(name: "new", stock: epoch + 100)
    end

    def names(type, params)
      klass = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable

        filter_by :stock, type: type, operators: true
      end
      klass.new(params: params).filtered(QueryLowRow.all).pluck(:name).sort
    end

    it "still compares a :datetime operand against the epoch" do
      expect(names(:datetime, stock_gte: "2026-01-01 00:00:00")).to eq(%w[new])
      expect(names(:datetime, stock_lt: "2026-01-01 00:00:00")).to eq(%w[old])
    end

    it "leaves a :boolean operand on its own path" do
      expect(names(:boolean, stock_gt: "0")).to eq(%w[new old]) # "0" casts to false => stock > 0
    end
  end

  describe "CursorPaginatable reads back a decimal boundary it minted" do
    let(:controller) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::CursorPaginatable

        cursor_paginate_by order: { weight: :asc }, per_page: 1
      end.new
    end

    it "round-trips a decimal with 120 significant digits" do
      digits = "1.#{'3' * 119}"
      record = QueryLowRow.create!(weight: BigDecimal(digits))
      minted = controller.send(:cursor_minted_value, QueryLowRow, record, :weight)
      expect(minted.length).to be > 100
      expect(controller.send(:cast_cursor_value!, QueryLowRow, :weight, minted)).to eq(BigDecimal(digits))
    end

    it "still refuses an oversized or too-wide hand-made decimal boundary" do
      ["1#{'0' * 2100}", "1.#{'3' * 2100}", "1e5000000", "1e99999999"].each do |huge|
        expect { controller.send(:cast_cursor_value!, QueryLowRow, :weight, huge) }
          .to raise_error(ConcernsOnRails::Controllers::CursorPaginatable::InvalidCursor), "accepted: #{huge[0, 20]}"
      end
    end
  end
end
