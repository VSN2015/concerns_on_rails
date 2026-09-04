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

  it "counts groups (not a raw Hash) for a grouped relation" do
    controller = controller_class.new(params: { per_page: 10 })
    records = controller.paginated(Widget.group(:name))
    expect { records.to_a }.not_to raise_error
    # 50 distinct names => 50 groups
    expect(controller.response.headers["X-Total-Count"]).to eq("50")
  end

  it "exposes pagination_meta without applying limit/offset" do
    controller = controller_class.new(params: { page: 2, per_page: 10 })
    meta = controller.pagination_meta(Widget.all)
    expect(meta).to eq(total: 50, page: 2, per_page: 10, total_pages: 5)
  end
  describe "in-memory collections (Array / Enumerable)" do
    let(:items) { (1..50).map { |i| "item #{i}" } }

    it "paginates an Array with the default per_page and sets the headers" do
      controller = controller_class.new
      page = controller.paginated(items)
      expect(page).to be_an(Array)
      expect(page.size).to eq(25)
      expect(page.first).to eq("item 1")
      expect(controller.response.headers).to include(
        "X-Total-Count" => "50", "X-Page" => "1", "X-Per-Page" => "25", "X-Total-Pages" => "2"
      )
    end

    it "honors page and per_page params" do
      controller = controller_class.new(params: { page: 3, per_page: 10 })
      page = controller.paginated(items)
      expect(page).to eq(items[20, 10])
      expect(controller.response.headers["X-Page"]).to eq("3")
      expect(controller.response.headers["X-Total-Pages"]).to eq("5")
    end

    it "returns an empty Array for a page beyond the end (headers still set)" do
      controller = controller_class.new(params: { page: 99, per_page: 10 })
      expect(controller.paginated(items)).to eq([])
      expect(controller.response.headers["X-Total-Count"]).to eq("50")
      expect(controller.response.headers["X-Total-Pages"]).to eq("5")
    end

    it "handles an empty Array" do
      controller = controller_class.new
      expect(controller.paginated([])).to eq([])
      expect(controller.response.headers["X-Total-Count"]).to eq("0")
      expect(controller.response.headers["X-Total-Pages"]).to eq("0")
    end

    it "does not mutate the source Array" do
      controller = controller_class.new(params: { per_page: 5, page: 2 })
      source = items.dup
      controller.paginated(source)
      expect(source).to eq(items)
    end

    it "caps per_page at max_per_page for arrays too" do
      klass = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Paginatable

        paginate_by per_page: 25, max_per_page: 7
      end
      controller = klass.new(params: { per_page: 999 })
      expect(controller.paginated(items).size).to eq(7)
      expect(controller.response.headers["X-Per-Page"]).to eq("7")
    end

    it "accepts any non-Hash Enumerable (Range, Set, Enumerator)" do
      controller = controller_class.new(params: { per_page: 3, page: 2 })
      expect(controller.paginated(1..10)).to eq([4, 5, 6])
      expect(controller.paginated(Set.new(1..10))).to eq([4, 5, 6])
      expect(controller.paginated((1..10).each)).to eq([4, 5, 6])
    end

    it "materializes an Enumerator only once (count + slice share one pass)" do
      passes = 0
      enum = Enumerator.new do |y|
        passes += 1
        (1..10).each { |i| y << i }
      end
      controller = controller_class.new(params: { per_page: 4 })
      expect(controller.paginated(enum)).to eq([1, 2, 3, 4])
      expect(passes).to eq(1)
    end

    it "paginates an Array of records (e.g. a loaded association) the same way" do
      controller = controller_class.new(params: { per_page: 10, page: 2 })
      loaded = Widget.order(:id).to_a
      page = controller.paginated(loaded)
      expect(page).to be_an(Array)
      expect(page.map(&:name)).to eq(loaded[10, 10].map(&:name))
    end

    it "memoizes meta so pagination_meta with no argument reuses it" do
      controller = controller_class.new(params: { page: 2, per_page: 20 })
      controller.paginated(items)
      expect(controller.pagination_meta).to eq(total: 50, page: 2, per_page: 20, total_pages: 3)
    end

    it "computes pagination_meta for an Array without slicing" do
      controller = controller_class.new(params: { page: 2, per_page: 20 })
      expect(controller.pagination_meta(items)).to eq(total: 50, page: 2, per_page: 20, total_pages: 3)
    end

    it "rejects a Hash with an ArgumentError that points at .to_a" do
      controller = controller_class.new
      expect { controller.paginated({ a: 1 }) }
        .to raise_error(ArgumentError, /Paginatable.*got Hash.*\.to_a/)
    end

    it "rejects nil and non-collections" do
      controller = controller_class.new
      expect { controller.paginated(nil) }.to raise_error(ArgumentError, /Paginatable.*got NilClass/)
      expect { controller.paginated("not a collection") }.to raise_error(ArgumentError, /Paginatable.*got String/)
      expect { controller.paginated(42) }.to raise_error(ArgumentError, /Paginatable.*got Integer/)
      expect { controller.pagination_meta(42) }.to raise_error(ArgumentError, /Paginatable.*got Integer/)
    end

    it "still routes relations through SQL LIMIT/OFFSET rather than loading them" do
      controller = controller_class.new(params: { per_page: 10 })
      records = controller.paginated(Widget.all)
      expect(records).to be_a(ActiveRecord::Relation)
      expect(records.to_sql).to match(/LIMIT/i)
    end
  end
end
