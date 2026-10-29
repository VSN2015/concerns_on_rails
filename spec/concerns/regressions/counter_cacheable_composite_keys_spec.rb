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
