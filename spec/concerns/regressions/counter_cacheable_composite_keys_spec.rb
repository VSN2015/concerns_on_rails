require "spec_helper"

# Audit 2026-10-29 GRAPH-2: counter_cacheable_by accepted a belongs_to with a
# composite foreign key (Rails 7.1+) but treated the foreign key as ONE
# column: the child was never counted (no error) and recount_counter_caches!
# emitted invalid SQL (`WHERE NOT (())`). Tuple counting is not implemented,
# so the macro refuses, like a polymorphic association.
describe "CounterCacheable and composite keys", min_rails: "7.1" do
  before do
    ActiveRecord::Schema.define do
      create_table :cc_cpk_orders, primary_key: %i[shop_id id], force: true do |t|
        t.integer :shop_id
        t.integer :id
        t.integer :cc_cpk_items_count, default: 0
      end
      create_table :cc_cpk_items, force: true do |t|
        t.integer :shop_id
        t.integer :order_id
        t.integer :simple_order_id
      end
      create_table :cc_simple_orders, force: true do |t|
        t.integer :cc_cpk_items_count, default: 0
      end
    end
    stub_const("CcCpkOrder", Class.new(TestModel) { self.table_name = "cc_cpk_orders" })
    stub_const("CcSimpleOrder", Class.new(TestModel) { self.table_name = "cc_simple_orders" })
  end

  after(:each) do
    %w[cc_cpk_orders cc_cpk_items cc_simple_orders].each do |table|
      ActiveRecord::Base.connection.drop_table(table, if_exists: true)
    end
  end

  def item_class(&declaration)
    stub_const("CcCpkItem", Class.new(TestModel) do
      self.table_name = "cc_cpk_items"
      include ConcernsOnRails::Models::CounterCacheable

      class_eval(&declaration)
    end)
  end

  it "refuses a composite foreign_key: at the macro" do
    expect do
      item_class do
        belongs_to :cc_cpk_order, class_name: "CcCpkOrder", foreign_key: %i[shop_id order_id], optional: true
        counter_cacheable_by :cc_cpk_order
      end
    end.to raise_error(ArgumentError, /composite/)
  end

  it "refuses a belongs_to whose parent key is composite (primary_key: Array)" do
    expect do
      item_class do
        belongs_to :cc_cpk_order, class_name: "CcCpkOrder", primary_key: %i[shop_id id],
                                  foreign_key: %i[shop_id order_id], optional: true
        counter_cacheable_by :cc_cpk_order
      end
    end.to raise_error(ArgumentError, /composite/)
  end

  it "decides at the macro from the raw options, without memoizing the reflection's foreign key" do
    reflection = nil
    expect do
      item_class do
        belongs_to :cc_cpk_order, class_name: "CcCpkOrder", foreign_key: %i[shop_id order_id], optional: true
        reflection = reflect_on_association(:cc_cpk_order)
        counter_cacheable_by :cc_cpk_order
      end
    end.to raise_error(ArgumentError, /composite/)
    expect(reflection.instance_variable_get(:@foreign_key)).to be_nil
  end

  it "re-checks lazily: a composite key only visible after the macro still raises on first use" do
    klass = item_class do
      belongs_to :simple_order, class_name: "CcSimpleOrder", optional: true
      counter_cacheable_by :simple_order, count: :cc_cpk_items_count
    end
    reflection = klass.reflect_on_association(:simple_order)
    allow(reflection).to receive(:foreign_key).and_return(%w[shop_id order_id])

    expect { klass.recount_counter_caches! }.to raise_error(ArgumentError, /composite/)
    expect { klass.create!(simple_order: CcSimpleOrder.create!) }.to raise_error(ArgumentError, /composite/)
  end

  it "saves a child with a nil foreign key whose belongs_to cannot resolve its parent class" do
    klass = item_class do
      belongs_to :ghost, class_name: "DoesNotExist", foreign_key: :simple_order_id, optional: true
      counter_cacheable_by :ghost, count: :cc_cpk_items_count
    end

    expect { klass.create! }.not_to raise_error
    expect(klass.count).to eq(1)
  end

  it "resolves the parent's key once per reflection, not on every save" do
    klass = item_class do
      belongs_to :simple_order, class_name: "CcSimpleOrder", optional: true
      counter_cacheable_by :simple_order, count: :cc_cpk_items_count
    end
    order = CcSimpleOrder.create!
    calls = 0
    reflection = klass.reflect_on_association(:simple_order)
    allow(reflection).to receive(:association_primary_key).and_wrap_original do |original, *args|
      calls += 1
      original.call(*args)
    end

    klass.create!(simple_order: order)
    after_first = calls
    klass.create!(simple_order: order)

    # the adjustment itself reads the key once per save; the composite check adds none after the first
    expect(calls - after_first).to eq(after_first - 1)
    expect(order.reload.cc_cpk_items_count).to eq(2)
  end

  it "still counts and recounts through a single-column foreign key" do
    klass = item_class do
      belongs_to :simple_order, class_name: "CcSimpleOrder", optional: true
      counter_cacheable_by :simple_order, count: :cc_cpk_items_count
    end
    order = CcSimpleOrder.create!
    klass.create!(simple_order: order)
    klass.create!(simple_order: order)
    expect(order.reload.cc_cpk_items_count).to eq(2)

    CcSimpleOrder.update_all(cc_cpk_items_count: 0)
    klass.recount_counter_caches!
    expect(order.reload.cc_cpk_items_count).to eq(2)
  end
end
