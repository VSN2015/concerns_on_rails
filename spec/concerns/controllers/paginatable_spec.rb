require "spec_helper"

describe ConcernsOnRails::Controllers::Paginatable do
  before do
    ActiveRecord::Schema.define do
      create_table :widgets, force: true do |t|
        t.string :name
      end
    end

    class Widget < TestModel
      self.table_name = "widgets"
    end

    50.times { |i| Widget.create!(name: "Widget #{i}") }
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end

    Object.send(:remove_const, :Widget) if Object.const_defined?(:Widget)
  end

  let(:controller_class) do
    Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Paginatable
    end
  end

  it "uses the default per_page (25) when no params are given" do
    controller = controller_class.new
    records = controller.paginated(Widget.all)
    expect(records.size).to eq(25)
    expect(controller.response.headers["X-Per-Page"]).to eq("25")
    expect(controller.response.headers["X-Page"]).to eq("1")
    expect(controller.response.headers["X-Total-Count"]).to eq("50")
    expect(controller.response.headers["X-Total-Pages"]).to eq("2")
  end

  it "honors a custom per_page param" do
    controller = controller_class.new(params: { per_page: 10 })
    records = controller.paginated(Widget.all)
    expect(records.size).to eq(10)
    expect(controller.response.headers["X-Total-Pages"]).to eq("5")
  end

  it "honors a custom page param" do
    controller = controller_class.new(params: { page: 2, per_page: 10 })
    records = controller.paginated(Widget.all)
    expect(records.first.name).to eq("Widget 10")
    expect(controller.response.headers["X-Page"]).to eq("2")
  end

  it "caps per_page at max_per_page" do
    klass = Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Paginatable

      paginate_by per_page: 25, max_per_page: 30
    end
    controller = klass.new(params: { per_page: 999 })
    controller.paginated(Widget.all)
    expect(controller.response.headers["X-Per-Page"]).to eq("30")
  end

  it "normalizes page < 1 to 1" do
    controller = controller_class.new(params: { page: -5 })
    controller.paginated(Widget.all)
    expect(controller.response.headers["X-Page"]).to eq("1")
  end

  it "handles a page beyond the last page (empty result, still sets headers)" do
    controller = controller_class.new(params: { page: 99, per_page: 10 })
    records = controller.paginated(Widget.all)
    expect(records.to_a).to be_empty
    expect(controller.response.headers["X-Total-Count"]).to eq("50")
  end

  it "handles empty relations" do
    Widget.delete_all
    controller = controller_class.new
    records = controller.paginated(Widget.all)
    expect(records.to_a).to be_empty
    expect(controller.response.headers["X-Total-Count"]).to eq("0")
    expect(controller.response.headers["X-Total-Pages"]).to eq("0")
  end

  it "exposes paginate_by to override class-level defaults" do
    klass = Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Paginatable

      paginate_by per_page: 5
    end
    controller = klass.new
    records = controller.paginated(Widget.all)
    expect(records.size).to eq(5)
  end
end
