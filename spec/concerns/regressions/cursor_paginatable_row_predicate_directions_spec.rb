require "spec_helper"

# PARAMS-4: `predicate: :row` compares a row-value tuple (one direction), but
# the uniform-direction check only ran when the keyset WHERE was built — i.e.
# when a cursor was present. A mixed ordering therefore served page 1, minted a
# cursor, and raised ArgumentError (a 500) on every request that followed it.
# It is now refused where the ordering is declared, or before page 1 for a
# per-call `order:`.
describe ConcernsOnRails::Controllers::CursorPaginatable do
  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :row_feed_items, force: true do |t|
        t.string :name, null: false, default: ""
        t.integer :score, null: false, default: 0
        t.datetime :created_at, precision: 6, null: false
      end
    end
    stub_const("RowFeedItem", Class.new(TestModel) { self.table_name = "row_feed_items" })
    5.times { |i| RowFeedItem.create!(name: "x#{i}", score: i % 2, created_at: Time.utc(2026, 1, 1) + i) }
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  let(:base) { Class.new(FakeController) { include ConcernsOnRails::Controllers::CursorPaginatable } }
  let(:message) { /predicate: :row requires uniform order directions/ }

  it "refuses a mixed order: at the macro" do
    expect { base.cursor_paginate_by order: { score: :desc, created_at: :asc }, predicate: :row }
      .to raise_error(ArgumentError, message)
    expect(base.cursor_paginatable_order).to be_nil
  end

  it "refuses an order_presets entry with mixed directions" do
    presets = { newest: { created_at: :desc }, mixed: { score: :desc, created_at: :asc } }
    expect { base.cursor_paginate_by order_presets: presets, predicate: :row }.to raise_error(ArgumentError, message)
  end

  it "refuses a predicate: :row re-declaration over an inherited mixed ordering, and the reverse" do
    parent = Class.new(base) { cursor_paginate_by order: { score: :desc, created_at: :asc } }

    expect { Class.new(parent) { cursor_paginate_by predicate: :row } }.to raise_error(ArgumentError, message)
    row_parent = Class.new(base) { cursor_paginate_by order: { score: :desc }, predicate: :row }
    expect { Class.new(row_parent) { cursor_paginate_by order: { score: :desc, created_at: :asc } } }
      .to raise_error(ArgumentError, message)
  end

  it "refuses a mixed per-call order: before page 1 is served" do
    base.cursor_paginate_by order: { score: :desc, created_at: :desc }, per_page: 2, predicate: :row
    controller = base.new(params: {})

    expect { controller.cursor_paginated(RowFeedItem.all, order: { score: :desc, created_at: :asc }) }
      .to raise_error(ArgumentError, message)
    expect(controller.response.headers["X-Next-Cursor"]).to be_nil
  end

  it "still walks a uniform ordering under predicate: :row, and mixed ones under :auto / :or" do
    base.cursor_paginate_by order: { score: :desc, created_at: :desc }, per_page: 2, predicate: :row
    seen = []
    token = nil
    5.times do
      controller = base.new(params: token ? { cursor: token } : {})
      seen.concat(controller.cursor_paginated(RowFeedItem.all).map(&:name))
      token = controller.response.headers["X-Next-Cursor"]
      break unless token
    end
    expect(seen).to eq(%w[x3 x1 x4 x2 x0])

    %i[auto or].each do |mode|
      klass = Class.new(base) do
        cursor_paginate_by order: { score: :desc, created_at: :asc }, per_page: 2, predicate: mode
      end
      first = klass.new(params: {})
      expect(first.cursor_paginated(RowFeedItem.all).map(&:name)).to eq(%w[x1 x3])
      expect { klass.new(params: { cursor: first.response.headers["X-Next-Cursor"] }).cursor_paginated(RowFeedItem.all) }
        .not_to raise_error
    end
  end
end
