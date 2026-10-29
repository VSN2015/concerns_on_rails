require "spec_helper"

# PARAMS-3: Paginatable's COUNT stripped the SELECT list, which also stripped
# the alias a grouped relation's HAVING reads — `HAVING n > 1` raised
# StatementInvalid (no such column: n) on SQLite and MySQL, both of which allow
# an alias in HAVING (PostgreSQL does not, so the app's own query fails there).
describe ConcernsOnRails::Controllers::Paginatable do
  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :grouped_rows, force: true do |t|
        t.string :category
      end
    end
    stub_const("GroupedRow", Class.new(TestModel) { self.table_name = "grouped_rows" })
    %w[a b a c c c].each { |category| GroupedRow.create!(category: category) }
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  let(:controller) do
    Class.new(FakeController) { include ConcernsOnRails::Controllers::Paginatable }.new(params: {})
  end

  def total_for(relation)
    controller.paginated(relation).to_a
    controller.response.headers["X-Total-Count"]
  end

  it "counts the groups of a HAVING that reads a select alias" do
    skip "PostgreSQL does not allow an alias in HAVING" if TestDatabase.postgresql?

    relation = GroupedRow.select("category, COUNT(*) AS n").group(:category).having("n > 1")
    expect(relation.to_a.size).to eq(2) # the relation itself is valid SQL here
    expect(total_for(relation)).to eq("2")
  end

  it "counts the groups of a HAVING written over the aggregate (every adapter)" do
    relation = GroupedRow.select("category, COUNT(*) AS n").group(:category).having("COUNT(*) > 1")
    expect(total_for(relation)).to eq("2")
    expect(controller.pagination_meta[:total_pages]).to eq(1)
  end

  it "paginates the grouped rows by the same total" do
    relation = GroupedRow.select("category, COUNT(*) AS n").group(:category).having("COUNT(*) > 1").order(:category)
    page = Class.new(FakeController) { include ConcernsOnRails::Controllers::Paginatable }.new(params: { per_page: "1", page: "2" })
    expect(page.paginated(relation).map(&:category)).to eq(["c"])
    expect(page.response.headers["X-Total-Count"]).to eq("2")
  end

  it "keeps the plain GROUP BY count for a grouped relation with no HAVING, and for ungrouped ones" do
    expect(total_for(GroupedRow.group(:category).select(:category))).to eq("3")
    expect(total_for(GroupedRow.group(:category))).to eq("3")
    expect(total_for(GroupedRow.all)).to eq("6")
    expect(total_for(GroupedRow.where(category: "zzz"))).to eq("0")
  end
end
