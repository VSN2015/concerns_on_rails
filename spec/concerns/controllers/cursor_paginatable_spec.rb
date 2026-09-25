require "spec_helper"
require "support/integration_harness"
require "active_support/rescuable"

# NOTE: FakeController cannot simulate performed?/double-render; the concern's
# raise-based error path makes that real-Rails failure mode structurally
# impossible (the action aborts at the raise), which is the mitigation.
# Every multi-page walk below constructs a fresh controller per request —
# headers and the meta memo are per-instance, exactly like real controllers.
describe ConcernsOnRails::Controllers::CursorPaginatable do
  let(:controller_class) do
    Class.new(FakeController) { include ConcernsOnRails::Controllers::CursorPaginatable }
  end

  def make_controller(params = {})
    controller_class.new(params: params)
  end

  def decode(token)
    JSON.parse(Base64.urlsafe_decode64(token))
  end

  def encode(payload)
    Base64.urlsafe_encode64(JSON.generate(payload), padding: false)
  end

  before(:each) do
    ActiveRecord::Schema.define do
      # NOT NULL on purpose: these columns exercise the plain keyset SQL (row
      # tuples, `col dir`); nullable ordering columns have their own table
      # in "NULL ordering values".
      create_table :items, force: true do |t|
        t.string :name, null: false, default: ""
        t.integer :score, null: false, default: 0
        t.datetime :created_at, precision: 6, null: false
      end

      create_table :widgets, force: true do |t|
        t.datetime :created_at, precision: 6
      end

      create_table :no_pks, id: false, force: true do |t|
        t.integer :value
      end
    end

    class Item < TestModel; end
    class Widget < TestModel; end

    class NoPk < TestModel
      self.table_name = "no_pks"
      self.primary_key = nil
    end

    base = Time.utc(2026, 1, 1)
    1.upto(50) do |i|
      # score: i / 10 gives 10-way ties — exercises the PK tiebreaker
      Item.create!(name: format("item-%02d", i), score: i / 10, created_at: base + i)
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
    %i[Item Widget NoPk OrderedItem].each do |const|
      Object.send(:remove_const, const) if Object.const_defined?(const)
    end
  end

  describe "first page (defaults)" do
    it "returns DEFAULT_PER_PAGE records ordered by id asc with the full header set" do
      controller = make_controller
      records = controller.cursor_paginated(Item.all)

      expect(records.size).to eq(25)
      expect(records.map(&:id)).to eq(Item.order(:id).limit(25).pluck(:id))

      headers = controller.response.headers
      expect(headers["X-Per-Page"]).to eq("25")
      expect(headers["X-Count"]).to eq("25")
      expect(headers["X-Has-More"]).to eq("true")
      expect(headers["X-Next-Cursor"]).to match(/\A[A-Za-z0-9_-]+\z/)
    end
  end

  describe "cursor walking" do
    it "continues exactly where the previous page ended" do
      page1 = make_controller(per_page: 10)
      page1.cursor_paginated(Item.all)

      page2 = make_controller(per_page: 10, cursor: page1.response.headers["X-Next-Cursor"])
      records = page2.cursor_paginated(Item.all)

      all_ids = Item.order(:id).pluck(:id)
      expect(records.map(&:id)).to eq(all_ids[10, 10])
    end

    it "ends the walk with has_more false and no next cursor" do
      cursor = nil
      pages = []
      loop do
        controller = make_controller({ per_page: 20, cursor: cursor }.compact)
        pages << controller.cursor_paginated(Item.all)
        cursor = controller.response.headers["X-Next-Cursor"]
        next if cursor

        expect(controller.response.headers["X-Has-More"]).to eq("false")
        expect(controller.response.headers).not_to have_key("X-Next-Cursor")
        expect(controller.cursor_pagination_meta[:next_cursor]).to be_nil
        break
      end

      expect(pages.map(&:size)).to eq([20, 20, 10])
    end

    it "paginates descending order across pages" do
      page1 = make_controller(per_page: 10)
      records1 = page1.cursor_paginated(Item.all, order: { id: :desc })
      expect(records1.first.id).to eq(Item.maximum(:id))

      page2 = make_controller(per_page: 10, cursor: page1.response.headers["X-Next-Cursor"])
      records2 = page2.cursor_paginated(Item.all, order: { id: :desc })

      ids = records1.map(&:id) + records2.map(&:id)
      expect(ids).to eq(ids.sort.reverse)
      expect(ids.uniq.size).to eq(20)
    end

    it "walks mixed-direction multi-column orderings without skips or repeats" do
      collected = []
      cursor = nil
      loop do
        controller = make_controller({ per_page: 7, cursor: cursor }.compact)
        records = controller.cursor_paginated(Item.all, order: { score: :desc, name: :asc })
        collected.concat(records.map(&:id))
        cursor = controller.response.headers["X-Next-Cursor"]
        break unless cursor
      end

      # PK tiebreaker inherits the LAST column's direction (:asc here)
      expect(collected).to eq(Item.order(score: :desc, name: :asc, id: :asc).pluck(:id))
    end

    it "never duplicates or skips rows across ties (tiebreaker proof)" do
      collected = []
      cursor = nil
      scores = []
      loop do
        controller = make_controller({ per_page: 7, cursor: cursor }.compact)
        records = controller.cursor_paginated(Item.all, order: { score: :desc })
        collected.concat(records.map(&:id))
        scores.concat(records.map(&:score))
        cursor = controller.response.headers["X-Next-Cursor"]
        break unless cursor
      end

      expect(collected.size).to eq(collected.uniq.size)
      expect(collected.to_set).to eq(Item.pluck(:id).to_set)
      expect(scores).to eq(scores.sort.reverse)
    end
  end

  describe "per_page resolution" do
    let(:configured_class) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::CursorPaginatable

        cursor_paginate_by order: :id, per_page: 5, max_per_page: 8
      end
    end

    it "clamps params[:per_page] to max_per_page" do
      controller = configured_class.new(params: { per_page: 999 })
      expect(controller.cursor_paginated(Item.all).size).to eq(8)
      expect(controller.response.headers["X-Per-Page"]).to eq("8")
    end

    it "falls back to the configured default for non-positive values" do
      controller = configured_class.new(params: { per_page: -3 })
      expect(controller.cursor_paginated(Item.all).size).to eq(5)
    end

    it "honors a per-call per_page over params" do
      controller = configured_class.new(params: { per_page: 999 })
      expect(controller.cursor_paginated(Item.all, per_page: 3).size).to eq(3)
    end

    # `max_per_page: 0` is documented as "no cap", and with no cap an
    # untrusted `?per_page=99999999999999999999` reached LIMIT unclamped —
    # an unauthenticated 500 Paginatable had already closed with MAX_PER_PAGE.
    context "when max_per_page is 0 (no cap)" do
      let(:uncapped_class) do
        Class.new(FakeController) do
          include ConcernsOnRails::Controllers::CursorPaginatable

          cursor_paginate_by order: :id, per_page: 5, max_per_page: 0
        end
      end
      let(:huge) { "99999999999999999999" }

      it "clamps an out-of-range per_page to the absolute ceiling instead of 500ing" do
        controller = uncapped_class.new(params: { per_page: huge })

        expect(controller.cursor_paginated(Item.all).size).to eq(50)
        expect(controller.response.headers["X-Per-Page"]).to eq(described_class::MAX_PER_PAGE.to_s)
      end

      it "clamps a per-call per_page too" do
        controller = uncapped_class.new

        expect(controller.cursor_pagination_meta(Item.all, per_page: 10**30)[:per_page])
          .to eq(described_class::MAX_PER_PAGE)
      end

      it "still honors an ordinary per_page far above the default cap" do
        controller = uncapped_class.new(params: { per_page: 500 })

        expect(controller.cursor_pagination_meta(Item.all)[:per_page]).to eq(500)
      end
    end
  end

  describe "invalid cursors" do
    it "raises InvalidCursor on malformed tokens and leaves no stale meta" do
      ["%%%not-base64", Base64.urlsafe_encode64("junk"), Base64.urlsafe_encode64("[1,2]")].each do |bad|
        controller = make_controller(cursor: bad)
        expect do
          controller.cursor_paginated(Item.all)
        end.to raise_error(described_class::InvalidCursor, /Invalid pagination cursor/)
        expect(controller.cursor_pagination_meta).to be_nil
      end
    end

    it "rejects cursors minted under a different order configuration" do
      minted = make_controller(per_page: 10)
      minted.cursor_paginated(Item.all, order: { name: :asc })
      token = minted.response.headers["X-Next-Cursor"]

      expect do
        make_controller(cursor: token).cursor_paginated(Item.all, order: { score: :desc })
      end.to raise_error(described_class::InvalidCursor, /does not match/)

      expect do
        make_controller(cursor: token).cursor_paginated(Item.all, order: { name: :desc })
      end.to raise_error(described_class::InvalidCursor, /does not match/)

      expect do
        make_controller(cursor: token).cursor_paginated(Item.all)
      end.to raise_error(described_class::InvalidCursor, /does not match/)
    end

    it "rejects cursors replayed against another table" do
      Widget.create!(created_at: Time.utc(2026, 1, 1))

      minted = make_controller(per_page: 10)
      minted.cursor_paginated(Item.all, order: { created_at: :asc })
      token = minted.response.headers["X-Next-Cursor"]

      expect do
        make_controller(cursor: token).cursor_paginated(Widget.all, order: { created_at: :asc })
      end.to raise_error(described_class::InvalidCursor, /does not match/)
    end

    it "rejects tampered non-scalar and null cursor values" do
      [
        encode("t" => "items", "o" => ["created_at:asc", "id:asc"], "v" => [{ "1" => 2026 }, 5]),
        encode("t" => "items", "o" => ["created_at:asc", "id:asc"], "v" => [nil, 5])
      ].each do |token|
        expect do
          make_controller(cursor: token).cursor_paginated(Item.all, order: { created_at: :asc })
        end.to raise_error(described_class::InvalidCursor, /Invalid pagination cursor/)
      end
    end

    # Values that pass the JSON-scalar check but CAST to nil (1e400 is Float
    # infinity, which Integer#cast turns into nil; a non-date string on a
    # datetime column) or cannot be bound on the column (an integer beyond
    # its range) used to reach the WHERE as `(score, id) > (NULL, 1)` — an
    # empty 200 that silently ended the client's walk — or a RangeError 500
    # on Rails 6.0. They are tampering, and get the same 400 as any other.
    it "rejects boundary values that cast to nil or cannot be bound on the column" do
      # Hand-written JSON: JSON.generate refuses to emit 1e400 (Infinity).
      {
        '{"t":"items","o":["score:asc","id:asc"],"v":[1e400,1]}' => { score: :asc },
        '{"t":"items","o":["score:asc","id:asc"],"v":[99999999999999999999,1]}' => { score: :asc },
        '{"t":"items","o":["score:asc","id:asc"],"v":[1,-99999999999999999999]}' => { score: :asc },
        '{"t":"items","o":["created_at:asc","id:asc"],"v":["not-a-date",1]}' => { created_at: :asc }
      }.each do |json, order|
        token = Base64.urlsafe_encode64(json, padding: false)

        expect do
          make_controller(cursor: token).cursor_paginated(Item.all, order: order)
        end.to raise_error(described_class::InvalidCursor, /Invalid pagination cursor/), "accepted: #{json}"
      end
    end

    it "rejects a value list whose length does not match the column set" do
      token = encode("t" => "items", "o" => ["created_at:asc", "id:asc"], "v" => [5])

      expect do
        make_controller(cursor: token).cursor_paginated(Item.all, order: { created_at: :asc })
      end.to raise_error(described_class::InvalidCursor, /Invalid pagination cursor/)
    end

    it "treats blank cursors as the first page" do
      ["", "  "].each do |blank|
        controller = make_controller(cursor: blank)
        expect(controller.cursor_paginated(Item.all).size).to eq(25)
      end
    end
  end

  describe "meta and headers" do
    it "memoizes meta, mirrors the headers, and clears the memo on failure" do
      controller = make_controller(per_page: 10)
      controller.cursor_paginated(Item.all)

      meta = controller.cursor_pagination_meta
      expect(meta).to eq(
        per_page: 10,
        count: 10,
        has_more: true,
        next_cursor: controller.response.headers["X-Next-Cursor"]
      )

      controller.params[:cursor] = "%%%broken"
      expect { controller.cursor_paginated(Item.all) }.to raise_error(described_class::InvalidCursor)
      expect(controller.cursor_pagination_meta).to be_nil
    end

    it "computes standalone meta without touching headers or the memo" do
      controller = make_controller(per_page: 10)
      meta = controller.cursor_pagination_meta(Item.all)

      expect(meta[:count]).to eq(10)
      expect(meta[:has_more]).to be(true)
      expect(controller.response.headers).to be_empty
      expect(controller.cursor_pagination_meta).to be_nil
    end

    it "handles an empty scope" do
      controller = make_controller
      records = controller.cursor_paginated(Item.where(id: nil))

      expect(records).to eq([])
      expect(controller.response.headers["X-Count"]).to eq("0")
      expect(controller.response.headers["X-Has-More"]).to eq("false")
      expect(controller.response.headers).not_to have_key("X-Next-Cursor")
    end
  end

  describe "developer errors" do
    it "raises ArgumentError for unknown columns" do
      expect do
        make_controller.cursor_paginated(Item.all, order: :nonexistent)
      end.to raise_error(ArgumentError, /does not exist/)
    end

    it "raises ArgumentError for nested-array order declarations" do
      expect do
        make_controller.cursor_paginated(Item.all, order: [%i[score desc]])
      end.to raise_error(ArgumentError, /must be column names/)
    end

    it "raises ArgumentError for tables without a single-column primary key" do
      expect do
        make_controller.cursor_paginated(NoPk.all)
      end.to raise_error(ArgumentError, /single-column primary key/)
    end

    it "raises ArgumentError for invalid directions at macro time" do
      expect do
        Class.new(FakeController) do
          include ConcernsOnRails::Controllers::CursorPaginatable

          cursor_paginate_by order: { id: :sideways }
        end
      end.to raise_error(ArgumentError, /must be :asc or :desc/)
    end
  end

  describe "ordering interplay" do
    it "reorders away a default_scope ordering" do
      class OrderedItem < TestModel
        self.table_name = "items"
        default_scope { order(name: :desc) }
      end

      controller = make_controller(per_page: 10)
      records = controller.cursor_paginated(OrderedItem.all, order: :id)

      ids = records.map(&:id)
      expect(ids).to eq(ids.sort)
    end
  end

  describe "bidirectional pagination" do
    let(:bidi_class) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::CursorPaginatable

        cursor_paginate_by order: :id, bidirectional: true
      end
    end

    def bidi_controller(params = {})
      bidi_class.new(params: params)
    end

    it "mints no prev cursor on the first page" do
      controller = bidi_controller(per_page: 10)
      controller.cursor_paginated(Item.all)

      headers = controller.response.headers
      expect(headers["X-Has-Prev"]).to eq("false")
      expect(headers).not_to have_key("X-Prev-Cursor")
      expect(controller.cursor_pagination_meta[:has_prev]).to be(false)
      expect(controller.cursor_pagination_meta[:prev_cursor]).to be_nil
    end

    it "returns to the previous page exactly via the prev cursor" do
      page1 = bidi_controller(per_page: 10)
      records1 = page1.cursor_paginated(Item.all)

      page2 = bidi_controller(per_page: 10, cursor: page1.response.headers["X-Next-Cursor"])
      page2.cursor_paginated(Item.all)

      back = bidi_controller(per_page: 10, cursor: page2.response.headers["X-Prev-Cursor"])
      records_back = back.cursor_paginated(Item.all)

      expect(records_back.map(&:id)).to eq(records1.map(&:id))
      # back at the true first page: nothing before it, plenty after it
      expect(back.response.headers["X-Has-Prev"]).to eq("false")
      expect(back.response.headers).not_to have_key("X-Prev-Cursor")
      expect(back.response.headers["X-Has-More"]).to eq("true")
      expect(back.response.headers["X-Next-Cursor"]).not_to be_nil
    end

    it "walks backward across pages in canonical order (desc ordering)" do
      page1 = bidi_controller(per_page: 15)
      r1 = page1.cursor_paginated(Item.all, order: { id: :desc })

      page2 = bidi_controller(per_page: 15, cursor: page1.response.headers["X-Next-Cursor"])
      r2 = page2.cursor_paginated(Item.all, order: { id: :desc })

      page3 = bidi_controller(per_page: 15, cursor: page2.response.headers["X-Next-Cursor"])
      page3.cursor_paginated(Item.all, order: { id: :desc })

      back2 = bidi_controller(per_page: 15, cursor: page3.response.headers["X-Prev-Cursor"])
      rb2 = back2.cursor_paginated(Item.all, order: { id: :desc })
      expect(rb2.map(&:id)).to eq(r2.map(&:id))

      back1 = bidi_controller(per_page: 15, cursor: back2.response.headers["X-Prev-Cursor"])
      rb1 = back1.cursor_paginated(Item.all, order: { id: :desc })
      expect(rb1.map(&:id)).to eq(r1.map(&:id))
      expect(back1.response.headers["X-Has-Prev"]).to eq("false")
    end

    it "honors a per-call bidirectional override" do
      controller = make_controller(per_page: 10)
      controller.cursor_paginated(Item.all, bidirectional: true)

      expect(controller.cursor_pagination_meta).to have_key(:has_prev)
      expect(controller.response.headers["X-Has-Prev"]).to eq("false")
    end

    it "rejects prev cursors on forward-only configurations" do
      page1 = bidi_controller(per_page: 10)
      page1.cursor_paginated(Item.all)
      page2 = bidi_controller(per_page: 10, cursor: page1.response.headers["X-Next-Cursor"])
      page2.cursor_paginated(Item.all)
      prev_token = page2.response.headers["X-Prev-Cursor"]

      expect do
        make_controller(cursor: prev_token).cursor_paginated(Item.all)
      end.to raise_error(described_class::InvalidCursor, /does not match/)
    end

    it "treats direction-less (pre-bidirectional) cursors as forward cursors" do
      boundary_id = Item.order(:id).pluck(:id)[9]
      token = encode("t" => "items", "o" => ["id:asc"], "v" => [boundary_id])

      records = make_controller(per_page: 10, cursor: token).cursor_paginated(Item.all)
      expect(records.first.id).to eq(Item.order(:id).pluck(:id)[10])
    end
  end

  describe "order presets" do
    let(:preset_class) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::CursorPaginatable

        cursor_paginate_by order_presets: { newest: { id: :desc }, alpha: { name: :asc } }, per_page: 10
      end
    end

    it "uses the first preset as the default when the param is absent" do
      records = preset_class.new(params: {}).cursor_paginated(Item.all)

      expect(records.first.id).to eq(Item.maximum(:id))
    end

    it "honors an explicit default_preset" do
      klass = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::CursorPaginatable

        cursor_paginate_by order_presets: { newest: { id: :desc }, alpha: { name: :asc } },
                           default_preset: :alpha, per_page: 10
      end

      records = klass.new(params: {}).cursor_paginated(Item.all)
      expect(records.map(&:name)).to eq(records.map(&:name).sort)
    end

    it "applies the preset named by the order param" do
      records = preset_class.new(params: { order: "alpha" }).cursor_paginated(Item.all)

      expect(records.map(&:name)).to eq(records.map(&:name).sort)
    end

    it "raises InvalidOrderPreset for unknown names, listing the presets" do
      controller = preset_class.new(params: { order: "bogus" })

      expect do
        controller.cursor_paginated(Item.all)
      end.to raise_error(described_class::InvalidOrderPreset,
                         /Unknown order preset 'bogus'. Available: newest, alpha/)
    end

    it "invalidates in-flight cursors when the client switches presets" do
      minted = preset_class.new(params: { order: "newest", per_page: 10 })
      minted.cursor_paginated(Item.all)
      token = minted.response.headers["X-Next-Cursor"]

      expect do
        preset_class.new(params: { order: "alpha", cursor: token }).cursor_paginated(Item.all)
      end.to raise_error(described_class::InvalidCursor, /does not match/)
    end

    it "reads the preset from a custom order_param" do
      klass = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::CursorPaginatable

        cursor_paginate_by order_presets: { newest: { id: :desc } }, order_param: :sort
      end

      records = klass.new(params: { sort: "newest" }).cursor_paginated(Item.all)
      expect(records.first.id).to eq(Item.maximum(:id))
    end

    it "validates the macro configuration" do
      base = Class.new(FakeController) { include ConcernsOnRails::Controllers::CursorPaginatable }

      expect { base.cursor_paginate_by(order: :id, order_presets: { a: :id }) }
        .to raise_error(ArgumentError, /not both/)
      expect { base.cursor_paginate_by(per_page: 5) }
        .to raise_error(ArgumentError, /order: or order_presets: is required/)
      expect { base.cursor_paginate_by(order_presets: { a: :id }, default_preset: :b) }
        .to raise_error(ArgumentError, /default_preset 'b' is not one of/)
      expect { base.cursor_paginate_by(order: :id, default_preset: :a) }
        .to raise_error(ArgumentError, /default_preset: requires order_presets:/)
    end
  end

  describe "predicate strategies" do
    def capture_sql(&block)
      queries = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        queries << payload[:sql] unless payload[:name] == "SCHEMA"
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
      queries
    end

    def second_page_sql(controller_klass, order)
      page1 = controller_klass.new(params: { per_page: 10 })
      page1.cursor_paginated(Item.all, order: order)
      token = page1.response.headers["X-Next-Cursor"]
      capture_sql do
        controller_klass.new(params: { per_page: 10, cursor: token }).cursor_paginated(Item.all, order: order)
      end.join("\n")
    end

    it ":auto uses a row-value tuple for uniform multi-column orders on a row-value adapter" do
      sql = second_page_sql(controller_class, { score: :desc })
      tuple = "(#{TestDatabase.qualified('items', 'score')}, #{TestDatabase.qualified('items', 'id')})"

      expect(sql).to include("#{tuple} <")
      expect(sql).not_to include(" OR ")
    end

    it ":auto falls back to OR-expansion for mixed directions" do
      sql = second_page_sql(controller_class, { score: :desc, name: :asc })

      expect(sql).to include(" OR ")
    end

    it "row and OR strategies paginate identically across ties" do
      walk = lambda do |klass|
        collected = []
        cursor = nil
        loop do
          controller = klass.new(params: { per_page: 7, cursor: cursor }.compact)
          collected.concat(controller.cursor_paginated(Item.all, order: { score: :desc }).map(&:id))
          cursor = controller.response.headers["X-Next-Cursor"]
          break unless cursor
        end
        collected
      end

      row_class = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::CursorPaginatable

        cursor_paginate_by order: :id, predicate: :row
      end
      or_class = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::CursorPaginatable

        cursor_paginate_by order: :id, predicate: :or
      end

      expect(walk.call(row_class)).to eq(walk.call(or_class))
    end

    it "predicate: :row raises on mixed directions instead of silently changing strategy" do
      klass = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::CursorPaginatable

        cursor_paginate_by order: :id, predicate: :row
      end
      page1 = klass.new(params: { per_page: 10 })
      page1.cursor_paginated(Item.all, order: { score: :desc, name: :asc })
      token = page1.response.headers["X-Next-Cursor"]

      expect do
        klass.new(params: { per_page: 10, cursor: token })
             .cursor_paginated(Item.all, order: { score: :desc, name: :asc })
      end.to raise_error(ArgumentError, /requires uniform order directions/)
    end

    it "rejects unknown predicate modes at macro time" do
      expect do
        Class.new(FakeController) do
          include ConcernsOnRails::Controllers::CursorPaginatable

          cursor_paginate_by order: :id, predicate: :fancy
        end
      end.to raise_error(ArgumentError, /predicate: must be one of/)
    end
  end

  # Nullable ordering columns paginate with their NULLs LAST — whatever the
  # direction, the adapter's own NULL placement (SQLite/MySQL first
  # ascending, PostgreSQL first descending) and the page size — every row
  # exactly once, no errors, no extra queries. A keyset `col > v` is never
  # TRUE for a NULL, so NULL rows used to vanish (or, briefly, 500).
  describe "NULL ordering values" do
    before do
      ActiveRecord::Schema.define do
        create_table(:nullable_items, force: true) do |t|
          t.string :name, **(TestDatabase.adapter == "sqlite3" ? { collation: "NOCASE" } : {})
          t.integer :score
        end
      end
      stub_const("NullableItem", Class.new(TestModel) { self.table_name = "nullable_items" })
      # NULLs in the first and the secondary column, ties on both, and
      # case-variant names (equal under a case-insensitive collation).
      [["a", 3], ["A", nil], ["b", 1], ["B", 1], [nil, 2], [nil, nil], ["c", nil], ["a", 3], ["d", 2], [nil, 1]]
        .each { |name, score| NullableItem.create!(name: name, score: score) }
    end

    let(:bidi_class) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::CursorPaginatable

        cursor_paginate_by order: :id, bidirectional: true
      end
    end

    def bidi_page(relation, order, per_page, cursor)
      controller = bidi_class.new(params: { per_page: per_page, cursor: cursor }.compact)
      [controller.cursor_paginated(relation, order: order).map(&:id), controller.cursor_pagination_meta]
    end

    # Forward to the end, then back to the start with prev cursors; returns
    # [forward ids, backward ids (in canonical order)]. Bounded, so a cycling
    # walk fails instead of hanging.
    def walk_both_ways(relation, order, per_page:)
      pages = [bidi_page(relation, order, per_page, nil)]
      pages << bidi_page(relation, order, per_page, pages.last.last[:next_cursor]) while pages.last.last[:next_cursor] && pages.size < 50
      back = pages.last.first.dup
      cursor = pages.last.last[:prev_cursor]
      30.times do
        break unless cursor

        ids, meta = bidi_page(relation, order, per_page, cursor)
        back.unshift(*ids)
        cursor = meta[:prev_cursor]
      end
      [pages.flat_map(&:first), back]
    end

    orders = {
      "score asc" => { score: :asc },
      "score desc" => { score: :desc },
      "name asc, score desc (NULL secondary)" => { name: :asc, score: :desc },
      "score desc, name asc (mixed)" => { score: :desc, name: :asc },
      "name desc" => { name: :desc }
    }
    orders.each do |label, order|
      [1, 2, 3].each do |per_page|
        it "walks every row exactly once, both ways — #{label}, per_page #{per_page}" do
          forward, backward = walk_both_ways(NullableItem.all, order, per_page: per_page)
          all_ids = NullableItem.pluck(:id)

          expect(forward).to match_array(all_ids)
          expect(forward.uniq.size).to eq(forward.size)
          expect(backward).to eq(forward)
        end
      end
    end

    it "puts the NULLs last whatever the direction (and the adapter)" do
      %i[asc desc].each do |dir|
        ids, = walk_both_ways(NullableItem.all, { score: dir }, per_page: 4)
        scores = NullableItem.where(id: ids).to_h { |item| [item.id, item.score] }.values_at(*ids)

        expect(scores.last(3)).to all(be_nil), "#{dir}: #{scores.inspect}"
        expect(scores.first(7).compact).to eq(dir == :asc ? scores.first(7).compact.sort : scores.first(7).compact.sort.reverse)
      end
    end

    it "walks DISTINCT and joined relations the same way" do
      table = TestDatabase.quoted_table("nullable_items")
      relation = NullableItem.distinct.joins("INNER JOIN #{table} other ON other.id = #{table}.id")

      forward, backward = walk_both_ways(relation, { score: :desc, name: :asc }, per_page: 3)
      expect(forward).to match_array(NullableItem.pluck(:id))
      expect(backward).to eq(forward)
    end

    it "walks client-selected presets the same way" do
      klass = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::CursorPaginatable

        cursor_paginate_by order_presets: { top: { score: :desc }, alpha: { name: :asc } }, per_page: 2
      end
      %w[top alpha].each do |preset|
        seen = []
        cursor = nil
        loop do
          controller = klass.new(params: { order: preset, cursor: cursor }.compact)
          seen.concat(controller.cursor_paginated(NullableItem.all).map(&:id))
          cursor = controller.cursor_pagination_meta[:next_cursor]
          break unless cursor
        end
        expect(seen).to match_array(NullableItem.pluck(:id)), preset
      end
    end

    it "encodes a NULL boundary explicitly and rejects null on a NOT NULL column" do
      NullableItem.where.not(score: nil).delete_all
      controller = make_controller(per_page: 1)
      controller.cursor_paginated(NullableItem.all, order: :score)
      expect(decode(controller.cursor_pagination_meta[:next_cursor])["v"].first).to be_nil

      tampered = encode("t" => "nullable_items", "o" => ["score:asc", "id:asc"], "v" => [1, nil])
      expect { make_controller(cursor: tampered).cursor_paginated(NullableItem.all, order: :score) }
        .to raise_error(described_class::InvalidCursor, /Invalid pagination cursor/)
    end

    # Regressions of the fail-loudly design this replaced: one NULL row far
    # past page 1 made page 1 raise, and every page paid an extra
    # EXISTS (... IS NULL) — a full scan when the column has no NULLs.
    it "renders page 1 when a NULL row lies far past it" do
      NullableItem.delete_all
      1.upto(30) { |i| NullableItem.create!(name: "n#{i}", score: i) }
      NullableItem.create!(name: "null", score: nil)

      records = make_controller(per_page: 5).cursor_paginated(NullableItem.all, order: { score: :asc })
      expect(records.map(&:score)).to eq([1, 2, 3, 4, 5])
    end

    it "runs exactly one query per page, NULL-aware ordering included" do
      first = make_controller(per_page: 3)
      first.cursor_paginated(NullableItem.all, order: :score)
      queries = []
      callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        make_controller(per_page: 3, cursor: first.cursor_pagination_meta[:next_cursor])
          .cursor_paginated(NullableItem.all, order: :score)
      end
      expect(queries.size).to eq(1)
      column = TestDatabase.qualified("nullable_items", "score")
      placement =
        TestDatabase.adapter == "postgresql" ? "#{column} ASC NULLS LAST" : "CASE WHEN #{column} IS NULL THEN 1 ELSE 0 END ASC"
      expect(queries.first).to include(placement)
    end

    it "keeps the plain ORDER BY (no NULL-placement expression) for NOT NULL columns" do
      queries = []
      callback = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        make_controller(per_page: 3).cursor_paginated(Item.all, order: :score)
      end

      plain = "ORDER BY #{TestDatabase.qualified('items', 'score')} ASC, #{TestDatabase.qualified('items', 'id')} ASC"
      expect(queries.first).to include(plain)
      expect(queries.first).not_to match(/CASE|NULLS/)
    end
  end

  # A display override (`def name = super.upcase`) is common, and the cursor
  # boundary used to be read through it: "ITEM-10" sorts before every
  # lowercase name, so `name > 'ITEM-10'` restarted the walk at page one —
  # forever. The cursor keys on the stored value the WHERE compares against.
  describe "an overridden attribute reader" do
    it "keys the cursor on the stored value, so no row repeats or is skipped" do
      shouting = Class.new(Item) do
        def name = super&.upcase
      end

      seen = []
      cursor = nil
      10.times do
        controller = make_controller({ per_page: 10, cursor: cursor }.compact)
        seen.concat(controller.cursor_paginated(shouting.all, order: :name).map(&:id))
        cursor = controller.cursor_pagination_meta[:next_cursor]
        break unless cursor
      end

      expect(seen).to eq(Item.order(:name, :id).pluck(:id))
    end
  end

  # Every keyword defaulted, so a subclass that re-declared only `order:`
  # silently reset the rest — including the parent's `signed:`, turning
  # cursor signing OFF for the whole subtree.
  describe "re-declaring cursor_paginate_by in a subclass" do
    let(:parent) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::CursorPaginatable

        cursor_paginate_by order: { id: :asc }, signed: "k" * 32, per_page: 7, max_per_page: 50,
                           bidirectional: true, predicate: :or, link_header: false
      end
    end

    it "inherits every option the subclass does not pass" do
      child = Class.new(parent) { cursor_paginate_by order: { id: :desc } }

      expect(child.cursor_paginatable_order).to eq([%i[id desc]])
      expect(child.cursor_paginatable_signed).to eq("k" * 32)
      expect(child.cursor_paginatable_per_page).to eq(7)
      expect(child.cursor_paginatable_max_per_page).to eq(50)
      expect(child.cursor_paginatable_bidirectional).to be(true)
      expect(child.cursor_paginatable_predicate).to eq(:or)
      expect(child.cursor_paginatable_link_header).to be(false)
      expect(parent.cursor_paginatable_order).to eq([%i[id asc]])
    end

    it "inherits the ordering when the subclass only tunes other options" do
      child = Class.new(parent) { cursor_paginate_by per_page: 3 }

      expect(child.cursor_paginatable_order).to eq([%i[id asc]])
      expect(child.cursor_paginatable_per_page).to eq(3)
      expect(child.cursor_paginatable_signed).to eq("k" * 32)
    end

    it "still lets a subclass switch an option off explicitly" do
      child = Class.new(parent) { cursor_paginate_by signed: false, bidirectional: false }

      expect(child.cursor_paginatable_signed).to be(false)
      expect(child.cursor_paginatable_bidirectional).to be(false)
    end

    it "replaces the ordering source wholesale: order: over inherited presets, and back" do
      presets = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::CursorPaginatable

        cursor_paginate_by order_presets: { newest: { id: :desc }, alpha: { name: :asc } }, default_preset: :alpha
      end
      fixed = Class.new(presets) { cursor_paginate_by order: :id }
      expect(fixed.cursor_paginatable_order).to eq([%i[id asc]])
      expect(fixed.cursor_paginatable_order_presets).to be_nil
      expect(fixed.cursor_paginatable_default_preset).to be_nil

      repicked = Class.new(presets) { cursor_paginate_by default_preset: :newest }
      expect(repicked.cursor_paginatable_default_preset).to eq(:newest)
      expect(repicked.cursor_paginatable_order_presets.keys).to eq(%i[newest alpha])

      expect { Class.new(fixed) { cursor_paginate_by default_preset: :newest } }
        .to raise_error(ArgumentError, /default_preset: requires order_presets:/)
    end
  end

  describe "datetime precision" do
    it "round-trips microsecond timestamps across a page boundary" do
      Item.delete_all
      base = Time.utc(2026, 3, 1, 12, 0, 0)
      4.times { |i| Item.create!(name: "micro-#{i}", created_at: base + Rational(i, 1_000_000)) }

      collected = []
      cursor = nil
      loop do
        controller = make_controller({ per_page: 2, cursor: cursor }.compact)
        records = controller.cursor_paginated(Item.all, order: { created_at: :asc })
        collected.concat(records.map(&:id))
        cursor = controller.response.headers["X-Next-Cursor"]
        break unless cursor
      end

      expect(collected).to eq(Item.order(:created_at, :id).pluck(:id))
      expect(collected.size).to eq(4)
    end
  end

  describe "rescue_from integration" do
    let(:rescuable_base) do
      Class.new(FakeController) { include ActiveSupport::Rescuable }
    end

    let(:rescuable_class) do
      rescuable = rescuable_base
      Class.new(rescuable) { include ConcernsOnRails::Controllers::CursorPaginatable }
    end

    it "registers a rescue_from handler for InvalidCursor" do
      expect(rescuable_class.rescue_handlers.map(&:first))
        .to include("ConcernsOnRails::Controllers::CursorPaginatable::InvalidCursor")
    end

    it "renders a 400 envelope when the handler dispatches" do
      controller = rescuable_class.new(params: { cursor: "%%%broken" })
      error = begin
        controller.cursor_paginated(Item.all)
        nil
      rescue described_class::InvalidCursor => e
        e
      end

      expect(controller.rescue_with_handler(error)).to be_truthy
      expect(controller.rendered[:status]).to eq(:bad_request)
      expect(controller.rendered[:json][:error][:code]).to eq("invalid_cursor")
    end

    it "registers and renders the InvalidOrderPreset handler" do
      rescuable = rescuable_base
      klass = Class.new(rescuable) do
        include ConcernsOnRails::Controllers::CursorPaginatable

        cursor_paginate_by order_presets: { newest: { id: :desc } }
      end

      controller = klass.new(params: { order: "bogus" })
      error = begin
        controller.cursor_paginated(Item.all)
        nil
      rescue described_class::InvalidOrderPreset => e
        e
      end

      expect(controller.rescue_with_handler(error)).to be_truthy
      expect(controller.rendered[:status]).to eq(:bad_request)
      expect(controller.rendered[:json][:error][:code]).to eq("invalid_order_preset")
    end

    it "delegates to render_error when Respondable is included" do
      rescuable = rescuable_base
      combined_class = Class.new(rescuable) do
        include ConcernsOnRails::Controllers::Respondable
        include ConcernsOnRails::Controllers::CursorPaginatable
      end

      controller = combined_class.new(params: { cursor: "%%%broken" })
      error = begin
        controller.cursor_paginated(Item.all)
        nil
      rescue described_class::InvalidCursor => e
        e
      end

      controller.rescue_with_handler(error)
      expect(controller.rendered[:status]).to eq(:bad_request)
      expect(controller.rendered[:json][:success]).to be(false)
      expect(controller.rendered[:json][:error][:code]).to eq("invalid_cursor")
    end

    it "lets InvalidCursor propagate from bare controllers (no rescue_from available)" do
      expect(controller_class).not_to respond_to(:rescue_handlers)
      controller = make_controller(cursor: "%%%broken")

      expect { controller.cursor_paginated(Item.all) }.to raise_error(described_class::InvalidCursor)
    end
  end

  describe "query behavior" do
    it "issues exactly one SELECT and never a COUNT" do
      queries = []
      callback = lambda do |_name, _start, _finish, _id, payload|
        queries << payload[:sql] unless payload[:name] == "SCHEMA"
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        make_controller.cursor_paginated(Item.all)
      end

      expect(queries.grep(/SELECT COUNT/i)).to be_empty
      expect(queries.grep(/\ASELECT/i).size).to eq(1)
    end

    it "accepts a bare model class" do
      from_class = make_controller.cursor_paginated(Item)
      from_relation = make_controller.cursor_paginated(Item.all)

      expect(from_class.map(&:id)).to eq(from_relation.map(&:id))
    end
  end

  describe "RFC 8288 Link header (through the real ActionController stack)" do
    def cursor_link_controller(**macro)
      IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::CursorPaginatable

        cursor_paginate_by(order: { created_at: :asc }, per_page: 20, **macro)

        define_method(:index) { render json: cursor_paginated(Item.all).map(&:id) }
      end
    end

    def links(result)
      header = result.header("Link")
      return {} unless header

      header.split(", ").to_h { |entry| entry.match(/\A<(.+)>; rel="(.+)"\z/).captures.reverse }
    end

    it "emits next (with the X-Next-Cursor token) on the first page, and no first/prev" do
      result = IntegrationHarness.dispatch(cursor_link_controller, :index, query: "per_page=20")
      token = result.header("X-Next-Cursor")
      expect(token).to be_present
      expect(links(result)).to eq("next" => "http://example.org/?per_page=20&cursor=#{token}")
    end

    it "emits first (cursor dropped) once a cursor is in play, and no next on the last page" do
      first = IntegrationHarness.dispatch(cursor_link_controller, :index, query: "per_page=20")
      second = IntegrationHarness.dispatch(cursor_link_controller, :index, query: "per_page=20&cursor=#{first.header('X-Next-Cursor')}")
      expect(links(second).keys).to match_array(%w[first next])
      expect(links(second)["first"]).to eq("http://example.org/?per_page=20")

      third = IntegrationHarness.dispatch(cursor_link_controller, :index, query: "per_page=20&cursor=#{second.header('X-Next-Cursor')}")
      expect(third.header("X-Has-More")).to eq("false")
      expect(links(third).keys).to eq(%w[first])
    end

    it "adds prev in bidirectional mode, preserving the order preset param" do
      klass = cursor_link_controller(bidirectional: true, order: nil, order_presets: { oldest: { created_at: :asc } })
      first = IntegrationHarness.dispatch(klass, :index, query: "order=oldest&per_page=20")
      second = IntegrationHarness.dispatch(klass, :index, query: "order=oldest&per_page=20&cursor=#{first.header('X-Next-Cursor')}")
      expect(links(second).keys).to match_array(%w[first prev next])
      expect(links(second)["prev"]).to eq("http://example.org/?order=oldest&per_page=20&cursor=#{second.header('X-Prev-Cursor')}")
    end

    it "can be switched off with cursor_paginate_by link_header: false" do
      result = IntegrationHarness.dispatch(cursor_link_controller(link_header: false), :index, query: "per_page=20")
      expect(result.header("Link")).to be_nil
      expect(result.header("X-Next-Cursor")).to be_present
    end

    it "is skipped silently when the controller has no request (bare harness)" do
      c = make_controller(per_page: 5)
      c.class.cursor_paginate_by(order: { created_at: :asc })
      c.cursor_paginated(Item.all)
      expect(c.response.headers).not_to have_key("Link")
      expect(c.response.headers["X-Has-More"]).to eq("true")
    end
  end

  describe "signed cursors (cursor_paginate_by signed:)" do
    let(:key) { "a-very-long-and-secret-signing-key" }

    def signed_controller(params = {}, signed: key, **macro)
      klass = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::CursorPaginatable

        cursor_paginate_by(order: { created_at: :asc }, signed: signed, **macro)
      end
      klass.new(params: params)
    end

    it "mints payload.signature tokens (URL-safe, 64-hex HMAC) and walks pages exactly like unsigned ones" do
      page1 = signed_controller({ per_page: 10 })
      page1.cursor_paginated(Item.all)
      token = page1.response.headers["X-Next-Cursor"]
      expect(token).to match(/\A[A-Za-z0-9_-]+\.[0-9a-f]{64}\z/)
      expect(decode(token.split(".").first)).to include("t" => "items", "v" => be_an(Array))

      page2 = signed_controller({ per_page: 10, cursor: token })
      expect(page2.cursor_paginated(Item.all).map(&:id)).to eq(Item.order(:created_at, :id).pluck(:id)[10, 10])
    end

    it "rejects a tampered payload, a tampered signature, and an unsigned token — fail closed" do
      page1 = signed_controller({ per_page: 10 })
      page1.cursor_paginated(Item.all)
      payload, signature = page1.response.headers["X-Next-Cursor"].split(".")

      forged_payload = encode(decode(payload).merge("v" => [decode(payload)["v"][0], 1]))
      [
        "#{forged_payload}.#{signature}",
        "#{payload}.#{signature.reverse}",
        payload,
        "#{payload}.",
        "#{payload}.#{signature}.extra"
      ].each do |bad|
        expect { signed_controller({ cursor: bad }).cursor_paginated(Item.all) }
          .to raise_error(described_class::InvalidCursor, /Invalid pagination cursor/), "accepted: #{bad}"
      end
    end

    it "signs prev cursors in bidirectional mode too" do
      page1 = signed_controller({ per_page: 10 }, bidirectional: true)
      page1.cursor_paginated(Item.all)
      page2 = signed_controller({ per_page: 10, cursor: page1.response.headers["X-Next-Cursor"] }, bidirectional: true)
      page2.cursor_paginated(Item.all)
      prev = page2.response.headers["X-Prev-Cursor"]
      expect(prev).to match(/\A[A-Za-z0-9_-]+\.[0-9a-f]{64}\z/)
      back = signed_controller({ per_page: 10, cursor: prev }, bidirectional: true)
      expect(back.cursor_paginated(Item.all).map(&:id)).to eq(Item.order(:created_at, :id).pluck(:id)[0, 10])
    end

    it "keys from a Proc (resolved per request) or a String; tokens do not verify under another key" do
      proc_page = signed_controller({ per_page: 5 }, signed: -> { "rotating-#{key}" })
      proc_page.cursor_paginated(Item.all)
      token = proc_page.response.headers["X-Next-Cursor"]
      expect { signed_controller({ cursor: token }, signed: "rotating-#{key}").cursor_paginated(Item.all) }.not_to raise_error
      expect { signed_controller({ cursor: token }, signed: key).cursor_paginated(Item.all) }
        .to raise_error(described_class::InvalidCursor)
    end

    it "signed: true uses Rails.application.secret_key_base when Rails is present" do
      app = Struct.new(:secret_key_base).new("rails-secret-key-base-value")
      stub_const("Rails", Module.new)
      Rails.define_singleton_method(:application) { app }
      page1 = signed_controller({ per_page: 5 }, signed: true)
      page1.cursor_paginated(Item.all)
      token = page1.response.headers["X-Next-Cursor"]
      expect { signed_controller({ cursor: token }, signed: "rails-secret-key-base-value").cursor_paginated(Item.all) }.not_to raise_error
    end

    it "signed: true without a Rails application raises a configuration error at first use" do
      hide_const("Rails")
      c = signed_controller({ per_page: 5 }, signed: true)
      expect { c.cursor_paginated(Item.all) }
        .to raise_error(ArgumentError, /signed: true needs Rails\.application\.secret_key_base.*pass signed: -> \{ \.\.\. \}/)
    end

    it "rejects a blank key and an unsupported signed: value at class load" do
      expect { signed_controller({}, signed: "") }.to raise_error(ArgumentError, /signed: must be true, false, a String or a callable/)
      expect { signed_controller({}, signed: 42) }.to raise_error(ArgumentError, /signed: must be true, false, a String or a callable/)
    end

    it "stays unsigned by default (existing tokens keep their shape)" do
      c = make_controller(per_page: 10)
      c.cursor_paginated(Item.all)
      expect(c.response.headers["X-Next-Cursor"]).to match(/\A[A-Za-z0-9_-]+\z/)
      expect(controller_class.cursor_paginatable_signed).to be(false)
    end
  end
end
