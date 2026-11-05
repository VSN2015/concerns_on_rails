require "spec_helper"

# Audit 2026-10-29 PARAMS-S2 (cursor half). `cursor_fetch_page` did
# `scoped.limit(limit + 1)`, replacing the caller's LIMIT, so walking
# `CursorRow.order(:score).limit(5)` kept going to the end of the table. The
# keyset WHERE and the per_page + 1 probe now run over the relation as a
# derived table, so the walk ends inside the caller's window.
describe ConcernsOnRails::Controllers::CursorPaginatable do
  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :cursor_rows, force: true do |t|
        t.integer :score
        t.string :label
      end
    end
    stub_const("CursorRow", Class.new(TestModel) { self.table_name = "cursor_rows" })
    (1..10).each { |i| CursorRow.create!(score: i, label: "r#{i}") }
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

      cursor_paginate_by order: { score: :asc }, per_page: 2, bidirectional: true
    end
  end

  def walk(relation, per_page_klass = klass)
    seen = []
    pages = []
    token = nil
    10.times do
      controller = per_page_klass.new(params: { cursor: token })
      page = controller.cursor_paginated(relation).map(&:score)
      pages << [page, controller.cursor_pagination_meta[:has_more]]
      seen.concat(page)
      token = controller.cursor_pagination_meta[:next_cursor]
      break unless token
    end
    [seen, pages]
  end

  it "walks a limited relation inside its window and stops after the last row" do
    seen, pages = walk(CursorRow.order(:score).limit(5))

    expect(seen).to eq([1, 2, 3, 4, 5])
    expect(pages).to eq([[[1, 2], true], [[3, 4], true], [[5], false]])
  end

  it "walks an offset + limit window, and an offset-only one" do
    expect(walk(CursorRow.order(:score).offset(3).limit(4)).first).to eq([4, 5, 6, 7])
    expect(walk(CursorRow.order(:score).offset(7)).first).to eq([8, 9, 10])
  end

  it "windows by the CALLER's order while the walk follows the cursor order" do
    seen, = walk(CursorRow.order(score: :desc).limit(5))
    expect(seen).to eq([6, 7, 8, 9, 10])
  end

  it "keeps prev cursors consistent inside the window" do
    relation = CursorRow.order(:score).limit(5)
    first = klass.new
    first.cursor_paginated(relation)
    second = klass.new(params: { cursor: first.cursor_pagination_meta[:next_cursor] })
    expect(second.cursor_paginated(relation).map(&:score)).to eq([3, 4])
    meta = second.cursor_pagination_meta
    expect(meta[:has_prev]).to be(true)

    back = klass.new(params: { cursor: meta[:prev_cursor] })
    expect(back.cursor_paginated(relation).map(&:score)).to eq([1, 2])
    expect(back.cursor_pagination_meta[:has_prev]).to be(false)

    last = klass.new(params: { cursor: second.cursor_pagination_meta[:next_cursor] })
    expect(last.cursor_paginated(relation).map(&:score)).to eq([5])
    expect(last.cursor_pagination_meta[:has_more]).to be(false)
  end

  it "keeps the unlimited walk and a where-scoped limited one unchanged" do
    expect(walk(CursorRow.order(:score)).first).to eq((1..10).to_a)
    expect(walk(CursorRow.where("score > 4").order(:score).limit(3)).first).to eq([5, 6, 7])
  end

  it "walks a limited relation over a nullable ordering column (NULLS LAST)" do
    CursorRow.where(score: [2, 4]).update_all(label: nil)
    nullable = Class.new(FakeController) do
      include ConcernsOnRails::Controllers::CursorPaginatable

      cursor_paginate_by order: { label: :asc }, per_page: 2
    end
    seen = []
    token = nil
    6.times do
      controller = nullable.new(params: { cursor: token })
      seen.concat(controller.cursor_paginated(CursorRow.order(:score).limit(5)).map(&:score))
      token = controller.cursor_pagination_meta[:next_cursor]
      break unless token
    end
    expect(seen.sort).to eq([1, 2, 3, 4, 5])
    expect(seen.last(2)).to match_array([2, 4]) # NULL labels last
  end
end
