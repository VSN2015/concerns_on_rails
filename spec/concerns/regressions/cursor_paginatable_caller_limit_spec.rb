require "spec_helper"

# Audit 2026-10-29 PARAMS-S2 (cursor half). `cursor_fetch_page` did
# `scoped.limit(limit + 1)`, replacing the caller's LIMIT, so walking
# `CursorRow.order(:score).limit(5)` kept going to the end of the table (and
# OFFSET has no meaning under a keyset WHERE). cursor_paginated now refuses a
# relation that carries a limit or an offset rather than walk rows the caller
# meant to exclude; Paginatable pages such a window.
describe ConcernsOnRails::Controllers::CursorPaginatable do
  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :cursor_rows, force: true do |t|
        t.integer :score
      end
    end
    stub_const("CursorRow", Class.new(TestModel) { self.table_name = "cursor_rows" })
    (1..10).each { |i| CursorRow.create!(score: i) }
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  let(:klass) do
    Class.new(FakeController) do
      include ConcernsOnRails::Controllers::CursorPaginatable

      cursor_paginate_by order: { score: :asc }, per_page: 2
    end
  end

  it "raises for a limited, an offset and an offset + limit relation" do
    [CursorRow.order(:score).limit(5), CursorRow.order(:score).offset(3), CursorRow.order(:score).offset(3).limit(4)].each do |relation|
      expect { klass.new.cursor_paginated(relation) }
        .to raise_error(ArgumentError, %r{replaces the relation's LIMIT/OFFSET; drop them or use Paginatable})
      expect { klass.new.cursor_pagination_meta(relation) }.to raise_error(ArgumentError, %r{LIMIT/OFFSET})
    end
  end

  it "leaves no stale meta behind a refused call" do
    controller = klass.new
    controller.cursor_paginated(CursorRow.order(:score))
    expect { controller.cursor_paginated(CursorRow.order(:score).limit(5)) }.to raise_error(ArgumentError)
    expect(controller.cursor_pagination_meta).to be_nil
  end

  it "still walks an unlimited relation, a zero offset included" do
    [CursorRow.order(:score), CursorRow.order(:score).offset(0), CursorRow].each do |relation|
      seen = []
      token = nil
      10.times do
        controller = klass.new(params: { cursor: token })
        seen.concat(controller.cursor_paginated(relation).map(&:score))
        token = controller.cursor_pagination_meta[:next_cursor]
        break unless token
      end
      expect(seen).to eq((1..10).to_a)
    end
  end
end
