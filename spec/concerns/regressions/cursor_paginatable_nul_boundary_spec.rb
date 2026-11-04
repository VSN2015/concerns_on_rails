require "spec_helper"

# PARAMS-5: on SQLite a text column can hold a NUL byte (a bound INSERT stores
# it), but the keyset WHERE inlines the boundary as a quoted literal, which
# SQLite cuts at the NUL — and the code refused such a boundary outright, so a
# cursor the gem minted itself ended the walk with a 400 and every row after the
# NUL-bearing one was unreachable. The boundary now goes in as
# CAST(X'<hex>' AS TEXT). PostgreSQL cannot store a NUL, so the example only
# runs where one can be stored (SQLite, MySQL).
describe ConcernsOnRails::Controllers::CursorPaginatable do
  before do
    skip "PostgreSQL cannot store a NUL byte in a text column" if TestDatabase.postgresql?

    ActiveRecord::Schema.define(verbose: false) do
      create_table :nul_boundary_names, force: true do |t|
        t.string :name, null: false, default: ""
        t.integer :rank, null: false, default: 0
      end
    end
    stub_const("NulBoundaryName", Class.new(TestModel) { self.table_name = "nul_boundary_names" })
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  def walk(klass, per_page_params = {})
    seen = []
    token = nil
    10.times do
      controller = klass.new(params: per_page_params.merge(token ? { cursor: token } : {}))
      seen.concat(controller.cursor_paginated(NulBoundaryName.all).map(&:name))
      token = controller.response.headers["X-Next-Cursor"]
      break unless token
    end
    seen
  end

  def controller_with(**options)
    Class.new(FakeController) do
      include ConcernsOnRails::Controllers::CursorPaginatable

      cursor_paginate_by(**options)
    end
  end

  let(:names) { %W[a b c d\u0000x d\u0000y e f] }

  before { names.each_with_index { |name, i| NulBoundaryName.create!(name: name, rank: i) } }

  it "walks past a row whose ordering value holds a NUL (ascending, boundary on the NUL row)" do
    expect(walk(controller_with(order: { name: :asc }, per_page: 2))).to eq(names)
  end

  it "walks it descending, and under a composite ordering with each predicate strategy" do
    expect(walk(controller_with(order: { name: :desc }, per_page: 2))).to eq(names.reverse)

    %i[or row].each do |predicate|
      klass = controller_with(order: { name: :asc, rank: :asc }, per_page: 3, predicate: predicate)
      expect(walk(klass)).to eq(names)
    end
  end

  it "walks backwards through it too (bidirectional)" do
    klass = controller_with(order: { name: :asc }, per_page: 2, bidirectional: true)
    first = klass.new(params: {})
    first.cursor_paginated(NulBoundaryName.all)
    second = klass.new(params: { cursor: first.response.headers["X-Next-Cursor"] })
    expect(second.cursor_paginated(NulBoundaryName.all).map(&:name)).to eq(%W[c d\u0000x])

    third = klass.new(params: { cursor: second.response.headers["X-Next-Cursor"] })
    expect(third.cursor_paginated(NulBoundaryName.all).map(&:name)).to eq(%W[d\u0000y e])

    back = klass.new(params: { cursor: third.response.headers["X-Prev-Cursor"] })
    expect(back.cursor_paginated(NulBoundaryName.all).map(&:name)).to eq(%W[c d\u0000x])
  end

  it "still compares ordinary strings exactly" do
    expect(walk(controller_with(order: { name: :asc }, per_page: 3))).to eq(names)
  end
end
