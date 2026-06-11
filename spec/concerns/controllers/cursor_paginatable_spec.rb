require "spec_helper"
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
      create_table :items, force: true do |t|
        t.string :name
        t.integer :score
        t.datetime :created_at, precision: 6
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

    it ":auto uses a row-value tuple for uniform multi-column orders on SQLite" do
      sql = second_page_sql(controller_class, { score: :desc })

      expect(sql).to include('("items"."score", "items"."id") <')
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

  describe "NULL ordering values" do
    it "raises loudly when the page-boundary row has a NULL ordering value" do
      Item.delete_all
      Item.create!(name: "null-score", score: nil)
      Item.create!(name: "scored", score: 1)

      controller = make_controller(per_page: 1)
      expect do
        # SQLite sorts NULLs first ascending, so the NULL row lands on the boundary
        controller.cursor_paginated(Item.all, order: :score)
      end.to raise_error(ArgumentError, /NULL on the page-boundary row/)
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
end
