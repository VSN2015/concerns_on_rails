require "spec_helper"

# Audit 2026-10-10 PARAM-10. `select("DISTINCT category")` is the other common
# spelling of a distinct select list, but the subquery count only looked at
# `distinct_value` (false here), so the plain count stripped the select list
# and COUNTed every underlying row: 6 instead of 3, a wrong X-Total-Count and
# X-Total-Pages, phantom empty trailing pages, and a Link rel="last" past the
# data. ActiveRecord's own `relation.count` answers 3.
describe ConcernsOnRails::Controllers::Paginatable do
  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :distinct_items, force: true do |t|
        t.string :category
        t.string :distinct_note
      end
    end
    stub_const("DistinctItem", Class.new(TestModel) { self.table_name = "distinct_items" })
    %w[x x x y y z].each { |category| DistinctItem.create!(category: category, distinct_note: "n") }
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  let(:controller) do
    Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Paginatable

      paginate_by per_page: 2
    end.new
  end

  def totals(relation)
    controller.paginated(relation).to_a
    controller.response.headers.values_at("X-Total-Count", "X-Total-Pages")
  end

  it "counts a select list spelled with DISTINCT as its distinct rows" do
    column = TestDatabase.quoted_column("category")

    expect(totals(DistinctItem.select("DISTINCT category"))).to eq(%w[3 2])
    expect(totals(DistinctItem.select("  distinct #{column}"))).to eq(%w[3 2])
    expect(totals(DistinctItem.select(Arel.sql("DISTINCT(category)")))).to eq(%w[3 2])
    expect(totals(DistinctItem.select("DISTINCT category").order(:category))).to eq(%w[3 2])
  end

  it "still counts every row for a select list that only mentions distinct" do
    expect(totals(DistinctItem.select(:distinct_note))).to eq(%w[6 3])
    expect(totals(DistinctItem.select("category AS distinct_category"))).to eq(%w[6 3])
  end
end
