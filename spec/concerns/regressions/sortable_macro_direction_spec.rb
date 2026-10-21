require "spec_helper"

# Audit 2026-10-10 PARAM-6. The request side downcases `?direction=` (so
# `?direction=DESC` works), but the macro did not: `sortable_by ...,
# direction: "DESC"` (or `:DESC`) silently fell back to :asc, so every
# default listing came out the wrong way round with no error at class load —
# and a typo (`direction: :dsc`) did the same. CursorPaginatable raises for a
# bad direction; Sortable now normalizes the case and raises for the rest.
describe ConcernsOnRails::Controllers::Sortable do
  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :direction_items, force: true do |t|
        t.string :title
      end
    end
    stub_const("DirectionItem", Class.new(TestModel) { self.table_name = "direction_items" })
    DirectionItem.create!(title: "a")
    DirectionItem.create!(title: "b")
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  def controller_class(direction)
    Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Sortable

      sortable_by :title, default: :title, direction: direction
    end
  end

  it "honours the default direction whatever its case, String or Symbol" do
    ["DESC", :DESC, "Desc", "desc", :desc].each do |direction|
      klass = controller_class(direction)
      expect(klass.sortable_default_direction).to eq(:desc)
      expect(klass.new.sorted(DirectionItem.all).pluck(:title)).to eq(%w[b a])
    end
    expect(controller_class("ASC").new.sorted(DirectionItem.all).pluck(:title)).to eq(%w[a b])
  end

  it "raises at class load for a direction that is neither asc nor desc" do
    ["descending", :dsc, "", nil, 1].each do |direction|
      expect { controller_class(direction) }
        .to raise_error(ArgumentError, /direction: must be :asc or :desc/)
    end
  end

  it "leaves the class unconfigured when the direction is refused" do
    klass = Class.new(FakeController) { include ConcernsOnRails::Controllers::Sortable }

    expect { klass.sortable_by :title, direction: :sideways }.to raise_error(ArgumentError)
    expect(klass.sortable_allowed_fields).to eq([])
  end
end
