require "spec_helper"

# Audit 2026-10-10 PARAM-5. Paginatable and CursorPaginatable accept a bare
# model class (`paginated(Article)`, documented), and so does Includable's
# `with_includes(Article)` — but Filterable#filtered and the controller
# Sortable#sorted called `relation.model`, which a class does not answer:
# `filtered(Article)` with a direct-where filter param, and `sorted(Article)`
# on EVERY request (the default sort always applies), were a NoMethodError
# 500, so `paginated(sorted(filtered(Article)))` could not be written.
describe "filtered / sorted on a bare model class" do
  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :class_items, force: true do |t|
        t.string :title
        t.integer :stock
      end
    end
    stub_const("ClassItem", Class.new(TestModel) { self.table_name = "class_items" })
    ClassItem.create!(title: "a", stock: 1)
    ClassItem.create!(title: "b", stock: 2)
    ClassItem.create!(title: "c", stock: 3)
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  let(:controller_class) do
    Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Filterable
      include ConcernsOnRails::Controllers::Sortable
      include ConcernsOnRails::Controllers::Paginatable

      filter_by :title, :stock, operators: true
      sortable_by :title, :stock, default: :title
      paginate_by per_page: 2
    end
  end

  it "filters a model class with a direct-where, comparison and LIKE filter" do
    expect(controller_class.new(params: { title: "b" }).filtered(ClassItem).pluck(:title)).to eq(["b"])
    expect(controller_class.new(params: { stock_gte: "2" }).filtered(ClassItem).pluck(:title)).to contain_exactly("b", "c")
    expect(controller_class.new(params: { title_contains: "c" }).filtered(ClassItem).pluck(:title)).to eq(["c"])
  end

  it "sorts a model class, by the default rule and by a requested one" do
    expect(controller_class.new.sorted(ClassItem).pluck(:title)).to eq(%w[a b c])
    expect(controller_class.new(params: { sort: "-stock" }).sorted(ClassItem).pluck(:title)).to eq(%w[c b a])
  end

  it "composes paginated(sorted(filtered(Model)))" do
    controller = controller_class.new(params: { stock_gte: "2", sort: "-title" })

    expect(controller.paginated(controller.sorted(controller.filtered(ClassItem))).map(&:title)).to eq(%w[c b])
  end
end
