require "spec_helper"

# Audit 2026-10-29 GRAPH-3: Sortable.reposition! assumed a single-column
# primary key (`CASE id`, `where(id => ids)`, `type_for_attribute(primary_key)`)
# and raised "TypeError: can't quote Array" on a composite one (Rails 7.1+).
# Composite keys are supported: ids are [shop_id, id] tuples (a record is
# accepted too), cast column by column, and the rows are written with one
# UPDATE each addressed through Support::PrimaryKey.
describe "Sortable.reposition! on a composite primary key", min_rails: "7.1" do
  before do
    ActiveRecord::Schema.define do
      create_table :srt_cpk_tasks, primary_key: %i[shop_id id], force: true do |t|
        t.integer :shop_id
        t.integer :id
        t.integer :list_id
        t.integer :position
      end
    end
  end

  after(:each) { ActiveRecord::Base.connection.drop_table(:srt_cpk_tasks, if_exists: true) }

  def build_model(direction: :asc)
    Class.new(TestModel) do
      self.table_name = "srt_cpk_tasks"
      include ConcernsOnRails::Models::Sortable

      sortable_by position: direction, use_acts_as_list: false
    end
  end

  let(:klass) { build_model }
  let!(:a) { klass.create!(id: [1, 1], position: 1) }
  let!(:b) { klass.create!(id: [1, 2], position: 2) }
  let!(:c) { klass.create!(id: [2, 1], position: 3) }

  def order_of(model = klass)
    model.unscoped.order(:position).map(&:id)
  end

  it "applies the given tuple order and returns the row count" do
    expect(klass.reposition!([c.id, a.id, b.id])).to eq(3)
    expect(order_of).to eq([[2, 1], [1, 1], [1, 2]])
    expect(klass.unscoped.order(:position).pluck(:position)).to eq([1, 2, 3])
  end

  it "accepts records, and tuples whose parts arrive as Strings (params)" do
    klass.reposition!([b, %w[2 1], %w[1 1]])
    expect(order_of).to eq([[1, 2], [2, 1], [1, 1]])
  end

  it "pushes unlisted rows after the listed ones (missing: :append) and raises for missing: :raise" do
    expect(klass.reposition!([c.id])).to eq(3)
    expect(order_of).to eq([[2, 1], [1, 1], [1, 2]])

    expect { klass.reposition!([c.id], missing: :raise) }.to raise_error(ArgumentError, /missing from ids/)
  end

  it "refuses duplicates, ids outside the relation and malformed tuples before writing" do
    expect { klass.reposition!([a.id, a.id]) }.to raise_error(ArgumentError, /duplicate id/)
    expect { klass.reposition!([[9, 9]]) }.to raise_error(ArgumentError, /not in this relation/)
    expect { klass.reposition!([1]) }.to raise_error(ArgumentError, /composite/)
    expect { klass.reposition!([[1, 2, 3]]) }.to raise_error(ArgumentError, /composite/)
    expect(order_of).to eq([[1, 1], [1, 2], [2, 1]])
  end

  it "works on a relation (only that list is renumbered) and on a :desc list" do
    klass.where(shop_id: 1).reposition!([b.id, a.id])
    expect(klass.unscoped.where(shop_id: 1).order(:position).map(&:id)).to eq([[1, 2], [1, 1]])
    expect(klass.find(c.id).position).to eq(3)

    desc = build_model(direction: :desc)
    desc.reposition!([a.id, b.id, c.id])
    expect(desc.unscoped.order(position: :desc).map(&:id)).to eq([[1, 1], [1, 2], [2, 1]])
  end
end
