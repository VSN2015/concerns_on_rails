require "spec_helper"

# PARAMS-7: page / per_page were read with String#to_i, which keeps only the
# leading digits — `?per_page=1e3` was 1, `?page=2.9` was 2 and `?per_page=10abc`
# was 10 — the lossy reading Filterable's operands already dropped. They are now
# read as exact whole numbers (NumericOperand); anything else is the default.
describe ConcernsOnRails::Support::ScalarParam do
  describe ".to_i" do
    it "reads exact whole numbers, scientific and decimal spellings included" do
      expect(described_class.to_i("1e3", default: 7)).to eq(1000)
      expect(described_class.to_i("2.0", default: 7)).to eq(2)
      expect(described_class.to_i(" 12 ", default: 7)).to eq(12)
      expect(described_class.to_i("+4", default: 7)).to eq(4)
      expect(described_class.to_i(3.0, default: 7)).to eq(3)
      expect(described_class.to_i("-3", default: 7)).to eq(-3)
      expect(described_class.to_i("99999999999999999999", default: 7)).to eq(99_999_999_999_999_999_999)
    end

    it "falls back to the default for anything that is not a whole number" do
      ["2.9", "10abc", "1e", "0x10", "1_000", "twelve", "", " ", "1e-1", "1e99999", "9" * 101, 2.9, "1.5e0"].each do |junk|
        expect(described_class.to_i(junk, default: 7)).to eq(7), "expected #{junk.inspect} to fall back"
      end
    end
  end

  describe ".per_page" do
    it "reads ?per_page=1e3 as 1000 (capped), never 1" do
      expect(described_class.per_page("1e3", default: 25, cap: 200)).to eq(200)
      expect(described_class.per_page("1e3", default: 25, cap: 0)).to eq(1000)
    end

    it "uses the default for a fractional or trailing-garbage value" do
      expect(described_class.per_page("10abc", default: 25, cap: 200)).to eq(25)
      expect(described_class.per_page("7.5", default: 25, cap: 200)).to eq(25)
    end
  end

  describe "through the paginators" do
    it "Paginatable: ?per_page=1e3 and ?page=2e0 are read exactly; ?page=2.9 is page 1" do
      klass = Class.new(FakeController) { include ConcernsOnRails::Controllers::Paginatable }

      controller = klass.new(params: { per_page: "1e3", page: "2e0" })
      controller.paginated((1..500).to_a)
      expect(controller.response.headers["X-Per-Page"]).to eq("200")
      expect(controller.response.headers["X-Page"]).to eq("2")

      controller = klass.new(params: { per_page: "10abc", page: "2.9" })
      controller.paginated((1..500).to_a)
      expect(controller.response.headers["X-Per-Page"]).to eq("25")
      expect(controller.response.headers["X-Page"]).to eq("1")
    end

    context "with CursorPaginatable" do
      before do
        ActiveRecord::Schema.define(verbose: false) { create_table(:scalar_rows, force: true) { |t| t.string :name } }
        stub_const("ScalarRow", Class.new(TestModel) { self.table_name = "scalar_rows" })
        6.times { |i| ScalarRow.create!(name: "r#{i}") }
      end

      after(:each) do
        ActiveRecord::Base.connection.tables.each do |table|
          next if table == "schema_migrations"

          ActiveRecord::Base.connection.drop_table(table)
        end
      end

      it "reads ?per_page=1e1 as 10 (capped by the rows) and ?per_page=2.5 as the default" do
        klass = Class.new(FakeController) do
          include ConcernsOnRails::Controllers::CursorPaginatable

          cursor_paginate_by order: :id, per_page: 4
        end

        expect(klass.new(params: { per_page: "1e1" }).cursor_paginated(ScalarRow.all).size).to eq(6)
        expect(klass.new(params: { per_page: "2.5" }).cursor_paginated(ScalarRow.all).size).to eq(4)
        expect(klass.new(params: {}).cursor_paginated(ScalarRow.all, per_page: 2).size).to eq(2)
      end
    end
  end
end
