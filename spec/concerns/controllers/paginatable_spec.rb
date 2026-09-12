require "spec_helper"
require "support/integration_harness"

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

  describe "RFC 8288 Link header (through the real ActionController stack)" do
    def link_controller(&extra)
      IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Paginatable

        class_eval(&extra) if extra

        define_method(:index) { render json: paginated(Widget.order(:id)).map(&:id) }
      end
    end

    def links(result)
      header = result.header("Link")
      return {} unless header

      header.split(", ").to_h { |entry| entry.match(/\A<(.+)>; rel="(.+)"\z/).captures.reverse }
    end

    it "emits first/prev/next/last relative to the current page, preserving the other query params" do
      result = IntegrationHarness.dispatch(link_controller, :index, query: "page=2&per_page=10&q=abc")
      expect(links(result)).to eq(
        "first" => "http://example.org/?page=1&per_page=10&q=abc",
        "prev" => "http://example.org/?page=1&per_page=10&q=abc",
        "next" => "http://example.org/?page=3&per_page=10&q=abc",
        "last" => "http://example.org/?page=5&per_page=10&q=abc"
      )
    end

    it "omits prev on the first page and next on the last page" do
      first = IntegrationHarness.dispatch(link_controller, :index, query: "per_page=10")
      expect(links(first).keys).to match_array(%w[first next last])
      expect(links(first)["next"]).to eq("http://example.org/?per_page=10&page=2")

      last = IntegrationHarness.dispatch(link_controller, :index, query: "page=5&per_page=10")
      expect(links(last).keys).to match_array(%w[first prev last])
    end

    it "points prev at the last page when the requested page is past the end" do
      result = IntegrationHarness.dispatch(link_controller, :index, query: "page=99&per_page=10")
      expect(links(result)).to include("prev" => "http://example.org/?page=5&per_page=10", "last" => "http://example.org/?page=5&per_page=10")
      expect(links(result)).not_to have_key("next")
    end

    it "emits no Link header for an empty collection" do
      Widget.delete_all
      result = IntegrationHarness.dispatch(link_controller, :index, query: "per_page=10")
      expect(result.header("Link")).to be_nil
      expect(result.header("X-Total-Count")).to eq("0")
    end

    it "can be switched off with paginate_by link_header: false" do
      klass = link_controller { paginate_by link_header: false }
      result = IntegrationHarness.dispatch(klass, :index, query: "page=2&per_page=10")
      expect(result.header("Link")).to be_nil
      expect(result.header("X-Page")).to eq("2")
    end

    it "appends to a Link header something else already set (Deprecatable, CDN hints)" do
      klass = link_controller do
        before_action { response.set_header("Link", '<https://docs.example.com/v2>; rel="deprecation"') }
      end
      result = IntegrationHarness.dispatch(klass, :index, query: "page=2&per_page=10")
      expect(result.header("Link")).to start_with('<https://docs.example.com/v2>; rel="deprecation", <http://example.org/?page=1')
    end

    it "works for in-memory collections too" do
      klass = IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Paginatable

        define_method(:index) { render json: paginated((1..30).to_a) }
      end
      result = IntegrationHarness.dispatch(klass, :index, query: "page=1&per_page=10")
      expect(links(result)["last"]).to eq("http://example.org/?page=1&per_page=10".sub("page=1", "page=3"))
    end

    it "is skipped silently when the controller has no request (bare harness)" do
      controller = controller_class.new(params: { page: 2, per_page: 10 })
      controller.paginated(Widget.all)
      expect(controller.response.headers).not_to have_key("Link")
      expect(controller.response.headers["X-Page"]).to eq("2")
    end
  end
  describe "total: (a page that is already paginated — external APIs, search services)" do
    let(:page_items) { (11..20).map { |i| "remote #{i}" } } # what the upstream returned for page 2 of 10

    it "returns the collection unsliced and takes the totals from total:" do
      controller = controller_class.new(params: { page: 2, per_page: 10 })
      page = controller.paginated(page_items, total: 95)
      expect(page).to eq(page_items)
      expect(controller.response.headers).to include(
        "X-Total-Count" => "95", "X-Page" => "2", "X-Per-Page" => "10", "X-Total-Pages" => "10"
      )
      expect(controller.pagination_meta).to eq(total: 95, page: 2, per_page: 10, total_pages: 10)
    end

    it "leaves a relation untouched too (no LIMIT/OFFSET, no COUNT)" do
      controller = controller_class.new(params: { page: 3, per_page: 5 })
      sql = []
      callback = ->(*, payload) { sql << payload[:sql] if payload[:sql] =~ /\ASELECT/i }
      records = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        controller.paginated(Widget.where(name: "Widget 1"), total: 42).to_a
      end
      expect(records.map(&:name)).to eq(["Widget 1"])
      expect(sql.size).to eq(1)
      expect(sql.first).not_to match(/LIMIT|COUNT/i)
      expect(controller.response.headers["X-Total-Count"]).to eq("42")
      expect(controller.response.headers["X-Total-Pages"]).to eq("9")
    end

    it "builds the Link header from total:" do
      klass = IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Paginatable

        define_method(:index) { render json: paginated(%w[a b], total: 45) }
      end
      result = IntegrationHarness.dispatch(klass, :index, query: "page=2&per_page=10")
      expect(result.header("Link")).to include('<http://example.org/?page=5&per_page=10>; rel="last"')
      expect(result.header("Link")).to include('<http://example.org/?page=3&per_page=10>; rel="next"')
    end

    it "pagination_meta accepts total: with or without a collection, skipping the COUNT" do
      controller = controller_class.new(params: { page: 4, per_page: 20 })
      expect(controller.pagination_meta(total: 61)).to eq(total: 61, page: 4, per_page: 20, total_pages: 4)
      expect(controller.pagination_meta(Widget.all, total: 61)).to eq(total: 61, page: 4, per_page: 20, total_pages: 4)
    end

    it "handles total: 0 (empty page, no Link)" do
      controller = controller_class.new
      expect(controller.paginated([], total: 0)).to eq([])
      expect(controller.response.headers["X-Total-Count"]).to eq("0")
      expect(controller.response.headers["X-Total-Pages"]).to eq("0")
      expect(controller.response.headers).not_to have_key("Link")
    end

    it "rejects a negative or non-Integer total:" do
      controller = controller_class.new
      expect { controller.paginated([], total: -1) }.to raise_error(ArgumentError, /total: must be a non-negative Integer/)
      expect { controller.paginated([], total: "95") }.to raise_error(ArgumentError, /total: must be a non-negative Integer/)
      expect { controller.pagination_meta(total: 1.5) }.to raise_error(ArgumentError, /total: must be a non-negative Integer/)
    end

    it "still slices and counts when total: is omitted" do
      controller = controller_class.new(params: { page: 2, per_page: 3 })
      expect(controller.paginated(page_items)).to eq(page_items[3, 3])
      expect(controller.response.headers["X-Total-Count"]).to eq("10")
    end
  end

  describe "page_param: / per_page_param: / style: :jsonapi" do
    def ids(klass, params)
      klass.new(params: params).paginated(Widget.order(:id)).map(&:id)
    end

    it "reads custom top-level param names" do
      klass = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Paginatable

        paginate_by page_param: :p, per_page_param: :limit
      end
      controller = klass.new(params: { p: "2", limit: "10", page: "9", per_page: "3" })
      expect(controller.paginated(Widget.order(:id)).map(&:id)).to eq((11..20).to_a)
      expect(controller.response.headers).to include("X-Page" => "2", "X-Per-Page" => "10")
      expect(klass.paginatable_page_param).to eq(["p"])
    end

    it "reads nested JSON:API page[number] / page[size] via style: :jsonapi, tolerating garbage" do
      klass = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Paginatable

        paginate_by style: :jsonapi
      end
      expect(ids(klass, page: { number: "3", size: "10" })).to eq((21..30).to_a)
      expect(ids(klass, page: { number: "3", size: "10" }).size).to eq(10)
      expect(ids(klass, page: "abc").size).to eq(25) # not a Hash → defaults
      expect(ids(klass, page: { number: ["1"] }).first).to eq(1)
      expect(ids(klass, {}).first).to eq(1)
      expect(klass.paginatable_page_param).to eq(%w[page number])
      expect(klass.paginatable_per_page_param).to eq(%w[page size])
    end

    it "accepts an explicit nested path and validates the options" do
      klass = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Paginatable

        paginate_by page_param: %i[paging page], per_page_param: %i[paging per]
      end
      expect(ids(klass, paging: { page: 2, per: 5 })).to eq((6..10).to_a)

      build = lambda do |**opts|
        Class.new(FakeController) do
          include ConcernsOnRails::Controllers::Paginatable

          paginate_by(**opts)
        end
      end
      expect { build.call(style: :weird) }.to raise_error(ArgumentError, /style: must be :flat or :jsonapi/)
      expect { build.call(page_param: []) }.to raise_error(ArgumentError, /page_param: must be a param name or a path/)
      expect { build.call(per_page_param: 5) }.to raise_error(ArgumentError, /per_page_param: must be a param name or a path/)
    end

    it "builds the Link header with the configured names — nested ones encoded the Rack way" do
      jsonapi = IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Paginatable

        paginate_by style: :jsonapi
        define_method(:index) { render json: paginated(Widget.order(:id)).map(&:id) }
      end
      result = IntegrationHarness.dispatch(jsonapi, :index, query: "page[number]=2&page[size]=10&q=abc")
      header = result.header("Link")
      expect(header).to include(%(<http://example.org/?page%5Bnumber%5D=3&page%5Bsize%5D=10&q=abc>; rel="next"))
      expect(header).to include(%(<http://example.org/?page%5Bnumber%5D=5&page%5Bsize%5D=10&q=abc>; rel="last"))
      expect(header).to include(%(<http://example.org/?page%5Bnumber%5D=1&page%5Bsize%5D=10&q=abc>; rel="first"))
      expect(result.header("X-Page")).to eq("2")

      flat = IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Paginatable

        paginate_by page_param: :p, per_page_param: :limit
        define_method(:index) { render json: paginated(Widget.order(:id)).map(&:id) }
      end
      result = IntegrationHarness.dispatch(flat, :index, query: "p=2&limit=10")
      expect(result.header("Link")).to include(%(<http://example.org/?p=3&limit=10>; rel="next"))
    end
  end

  describe "window:" do
    # `total:` drives total_pages without materializing thousands of rows:
    # total 1000 / per_page 10 => 100 pages.
    def meta(window:, page:, total:, per_page: 10)
      klass = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Paginatable
      end
      klass.paginate_by(window: window)
      klass.new(params: { page: page, per_page: per_page }).pagination_meta(total: total)
    end

    it "returns first, last and a window of pages either side of the current page" do
      expect(meta(window: 3, page: 47, total: 1000)[:pages])
        .to eq([1, :gap, 44, 45, 46, 47, 48, 49, 50, :gap, 100])
    end

    it "omits the leading gap when the window reaches the first page" do
      expect(meta(window: 3, page: 2, total: 1000)[:pages]).to eq([1, 2, 3, 4, 5, :gap, 100])
    end

    it "fills a one-page gap rather than hiding a single page behind an ellipsis" do
      expect(meta(window: 3, page: 6, total: 1000)[:pages]).to eq([1, 2, 3, 4, 5, 6, 7, 8, 9, :gap, 100])
    end

    it "omits the trailing gap when the window reaches the last page" do
      expect(meta(window: 3, page: 99, total: 1000)[:pages]).to eq([1, :gap, 96, 97, 98, 99, 100])
    end

    it "lists every page when the window spans the whole collection" do
      expect(meta(window: 3, page: 3, total: 50)[:pages]).to eq([1, 2, 3, 4, 5])
      expect(meta(window: 3, page: 1, total: 4)[:pages]).to eq([1])
    end

    it "clamps a page past the last page into the window" do
      expect(meta(window: 2, page: 999, total: 1000)[:pages]).to eq([1, :gap, 98, 99, 100])
    end

    it "keeps only first, current and last with window: 0" do
      expect(meta(window: 0, page: 47, total: 1000)[:pages]).to eq([1, :gap, 47, :gap, 100])
    end

    it "omits pages: entirely for an empty collection" do
      expect(meta(window: 3, page: 1, total: 0)).not_to have_key(:pages)
    end

    it "omits pages: entirely when window: is not declared" do
      controller = controller_class.new(params: { page: 2, per_page: 10 })
      controller.paginated(Widget.order(:id))
      expect(controller.pagination_meta).not_to have_key(:pages)
      expect(controller.pagination_meta(total: 1000)).not_to have_key(:pages)
    end

    it "includes pages: in the meta memoized by paginated" do
      klass = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Paginatable
      end
      klass.paginate_by(window: 0, per_page: 5)
      controller = klass.new(params: { page: 5 })
      controller.paginated(Widget.order(:id)) # 50 widgets / 5 => 10 pages
      expect(controller.pagination_meta[:pages]).to eq([1, :gap, 5, :gap, 10])
      expect(controller.response.headers["X-Total-Pages"]).to eq("10")
    end

    it "validates window: at declaration" do
      build = lambda do |window|
        Class.new(FakeController) do
          include ConcernsOnRails::Controllers::Paginatable

          paginate_by(window: window)
        end
      end
      expect { build.call(-1) }.to raise_error(ArgumentError, /window: must be a non-negative Integer/)
      expect { build.call("3") }.to raise_error(ArgumentError, /window: must be a non-negative Integer/)
      expect { build.call(2.5) }.to raise_error(ArgumentError, /window: must be a non-negative Integer/)
      expect(build.call(nil).paginatable_window).to be_nil
      expect(build.call(false).paginatable_window).to be_nil
      expect(build.call(0).paginatable_window).to eq(0)
    end
  end

  describe "an out-of-range page (untrusted input)" do
    # `?page=99999999999999999999` produced offset 2499999999999999999950,
    # which raised StatementInvalid on a relation and RangeError ("bignum too
    # big to convert into `long'") on an Array — an unauthenticated 500 on
    # every index action. per_page was capped; page was not.
    let(:huge) { "99999999999999999999" }

    it "does not blow up on a relation" do
      controller = controller_class.new(params: { page: huge })

      expect { controller.paginated(Widget.all).to_a }.not_to raise_error
    end

    it "does not blow up on an in-memory collection" do
      controller = controller_class.new(params: { page: huge })

      expect { controller.paginated((1..50).to_a) }.not_to raise_error
    end

    it "clamps to the maximum page and reports it in the meta and headers" do
      controller = controller_class.new(params: { page: huge })
      controller.paginated(Widget.all).to_a

      max = ConcernsOnRails::Controllers::Paginatable::MAX_PAGE
      expect(controller.pagination_meta[:page]).to eq(max)
      expect(controller.response.headers["X-Page"]).to eq(max.to_s)
    end

    it "returns an empty page past the end rather than wrapping to page 1" do
      controller = controller_class.new(params: { page: huge })

      expect(controller.paginated(Widget.all).to_a).to be_empty
    end

    it "leaves ordinary pages untouched" do
      controller = controller_class.new(params: { page: 2 })

      expect(controller.paginated(Widget.all).to_a.size).to eq(25)
      expect(controller.pagination_meta[:page]).to eq(2)
    end
  end

  describe "paginate_by validation" do
    def declare(**opts)
      expect do
        Class.new(FakeController) do
          include ConcernsOnRails::Controllers::Paginatable

          paginate_by(**opts)
        end
      end
    end

    # `LIMIT -1` means NO LIMIT on SQLite/MySQL, so a negative per_page
    # silently serialized the whole table on every request.
    it "rejects a negative per_page" do
      declare(per_page: -1).to raise_error(ArgumentError, /per_page: must be a positive integer/)
    end

    it "rejects a zero per_page" do
      declare(per_page: 0).to raise_error(ArgumentError, /per_page: must be a positive integer/)
    end

    it "rejects a negative max_per_page" do
      declare(max_per_page: -5).to raise_error(ArgumentError, /max_per_page: must be a non-negative integer/)
    end

    it "allows max_per_page: 0 (documented as 'no cap')" do
      declare(max_per_page: 0).not_to raise_error
    end

    it "allows ordinary values" do
      declare(per_page: 10, max_per_page: 100).not_to raise_error
    end
  end
end
