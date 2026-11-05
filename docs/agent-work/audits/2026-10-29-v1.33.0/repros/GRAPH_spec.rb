require "spec_helper"

# GRAPH slice audit repros (v1.33.0). Every example here FAILS on master 033981a,
# and each failure is the bug (not a wrong expectation).
RSpec.describe "GRAPH audit" do
  after do
    %w[gr_invoices gr_orders gr_items gr_tasks gr_pages friendly_id_slugs].each do |t|
      ActiveRecord::Base.connection.drop_table(t, if_exists: true)
    end
  end

  describe "GRAPH-1 Sequenceable: a pre-switch row (NULL period_column) formats in the CURRENT period" do
    before do
      ActiveRecord::Schema.define do
        create_table :gr_invoices, force: true do |t|
          t.integer :sequence
          t.datetime :finalized_at
          t.timestamps null: true
        end
      end
    end

    def klass(**options)
      Class.new(TestModel) do
        self.table_name = "gr_invoices"
        include ConcernsOnRails::Models::Sequenceable
        sequenceable_by :sequence, prefix: "INV-", reset: :year, time_zone: "UTC", **options
      end
    end

    it "GRAPH-1 formats a pre-switch row in its created_at period, not today's" do
      legacy = klass
      old = travel_to(Time.utc(2025, 6, 1)) { legacy.create! }    # issued as INV-2025-1
      travel_to(Time.utc(2026, 2, 1)) { legacy.create! }           # issued as INV-2026-1
      expect(old.formatted_sequence).to eq("INV-2025-1")

      switched = klass(assign: :manual, period_column: :finalized_at)
      displays = travel_to(Time.utc(2026, 3, 1)) do
        [switched.find(old.id).formatted_sequence,
         switched.find_by!(created_at: Time.utc(2026, 2, 1)).formatted_sequence]
      end
      # observed: ["INV-2026-1", "INV-2026-1"] -- two invoices print the same number
      expect(displays).to eq(%w[INV-2025-1 INV-2026-1])
    end
  end

  describe "composite keys (Rails 7.1+)", min_rails: "7.1" do
    describe "GRAPH-2 CounterCacheable with a composite foreign key" do
      before do
        ActiveRecord::Schema.define do
          create_table :gr_orders, primary_key: %i[shop_id id], force: true do |t|
            t.integer :shop_id
            t.integer :id
            t.integer :gr_items_count, default: 0
          end
          create_table :gr_items, force: true do |t|
            t.integer :shop_id
            t.integer :order_id
          end
        end
        stub_const("GrOrder", Class.new(TestModel) { self.table_name = "gr_orders" })
        stub_const("GrItem", Class.new(TestModel) do
          self.table_name = "gr_items"
          include ConcernsOnRails::Models::CounterCacheable
          belongs_to :gr_order, class_name: "GrOrder", foreign_key: %i[shop_id order_id], optional: true
          counter_cacheable_by :gr_order
        end)
      end

      it "GRAPH-2a counts a child on a composite-key parent" do
        order = GrOrder.create!(id: [1, 7])
        item = GrItem.create!(gr_order: order)
        expect([item.shop_id, item.order_id]).to eq([1, 7])
        expect(order.reload.gr_items_count).to eq(1) # observed: 0 (silently never counted)
      end

      it "GRAPH-2b recounts a composite-key parent" do
        order = GrOrder.create!(id: [1, 7])
        GrItem.create!(gr_order: order)
        GrOrder.update_all(gr_items_count: 0)
        # observed: StatementInvalid "... WHERE NOT (()) GROUP BY ..."
        GrItem.recount_counter_caches!
        expect(order.reload.gr_items_count).to eq(1)
      end
    end

    describe "GRAPH-3 Sortable.reposition! on a composite primary key" do
      before do
        ActiveRecord::Schema.define do
          create_table :gr_tasks, primary_key: %i[shop_id id], force: true do |t|
            t.integer :shop_id
            t.integer :id
            t.integer :position
          end
        end
      end

      it "GRAPH-3 repositions rows" do
        k = Class.new(TestModel) do
          self.table_name = "gr_tasks"
          include ConcernsOnRails::Models::Sortable
          sortable_by :position, use_acts_as_list: false
        end
        a = k.create!(id: [1, 1], position: 1)
        b = k.create!(id: [1, 2], position: 2)
        k.reposition!([b.id, a.id]) # observed: TypeError can't quote Array
        expect(k.unscoped.order(:position).map(&:id)).to eq([[1, 2], [1, 1]])
      end
    end
  end

  describe "GRAPH-4 legacy_aliases const_missing is not warning-free under a racing first reference" do
    it "GRAPH-4 does not warn when two first references both reach const_missing" do
      ConcernsOnRails.send(:remove_const, :Maskable) if ConcernsOnRails.const_defined?(:Maskable, false)
      err = StringIO.new
      old = $stderr
      $stderr = err
      begin
        ConcernsOnRails.const_missing(:Maskable) # thread A
        ConcernsOnRails.const_missing(:Maskable) # thread B, entered before A pinned it
      ensure
        $stderr = old
      end
      expect(err.string).not_to include("already initialized constant")
    end
  end
  describe "GRAPH-5 Sluggable: a scope move ignores friendly_id history slugs" do
    before do
      ActiveRecord::Schema.define do
        create_table :gr_pages, force: true do |t|
          t.string :title
          t.string :slug
          t.integer :account_id
        end
        create_table :friendly_id_slugs, force: true do |t|
          t.string :slug, null: false
          t.integer :sluggable_id, null: false
          t.string :sluggable_type, limit: 50
          t.string :scope
          t.datetime :created_at
        end
        # the index friendly_id's own generator migration creates
        add_index :friendly_id_slugs, %i[slug sluggable_type scope], unique: true
      end
      stub_const("GrPage", Class.new(TestModel) do
        self.table_name = "gr_pages"
        include ConcernsOnRails::Models::Sluggable
        sluggable_by :title, history: true, scope: :account_id
      end)
    end

    it "GRAPH-5 moves a record into a scope where another record's history holds its slug" do
      b = GrPage.create!(title: "Foo", account_id: 2)
      b.update!(title: "Bar") # "foo" is now b's history slug in account 2
      a = GrPage.create!(title: "Foo", account_id: 1)
      expect(a.slug).to eq("foo")
      # observed: ActiveRecord::RecordNotUnique (friendly_id_slugs.slug, sluggable_type, scope)
      expect { a.update!(account_id: 2) }.not_to raise_error
      expect(GrPage.where(account_id: 2).friendly.find("foo")).to eq(b)
    end
  end
  describe "GRAPH-6 Duplicable copies a child the loaded association has marked for destruction" do
    before do
      ActiveRecord::Schema.define do
        create_table :gr_lists, force: true do |t|
          t.string :name
        end
        create_table :gr_entries, force: true do |t|
          t.integer :gr_list_id
          t.string :body
        end
      end
      stub_const("GrEntry", Class.new(TestModel) { self.table_name = "gr_entries" })
      stub_const("GrList", Class.new(TestModel) do
        self.table_name = "gr_lists"
        include ConcernsOnRails::Models::Duplicable
        has_many :gr_entries, class_name: "GrEntry", foreign_key: :gr_list_id
        accepts_nested_attributes_for :gr_entries, allow_destroy: true
        duplicable_by associations: %i[gr_entries]
      end)
    end
    after { %w[gr_lists gr_entries].each { |t| ActiveRecord::Base.connection.drop_table(t, if_exists: true) } }

    it "GRAPH-6 leaves out a child marked _destroy (an in-memory edit of the loaded association)" do
      list = GrList.create!(name: "l")
      list.gr_entries.create!(body: "keep")
      dropped = list.gr_entries.create!(body: "drop")
      list.reload
      list.assign_attributes(gr_entries_attributes: [{ id: dropped.id, _destroy: "1" }]) # "save as copy" form
      copy = list.duplicate!
      expect(copy.gr_entries.map(&:body)).to eq(["keep"]) # observed: ["keep", "drop"]
    end
  end
end
