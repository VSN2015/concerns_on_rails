require "spec_helper"
require "support/integration_harness"

# Audit 2026-10-10 PARAM-2. A cursor is Base64 of arbitrary bytes, and
# JSON.parse admits both "\u0000" and raw invalid UTF-8 inside a JSON string —
# values JSON.generate could never have minted from a database row. Both were
# cast through the String type and inlined into the keyset WHERE: a NUL byte
# cut the SQL short (StatementInvalid 500 on SQLite and PostgreSQL), invalid
# UTF-8 raised ArgumentError on Rails 7.0 and is a PostgreSQL encoding error.
# The documented answer for a value no cursor ever carries is the
# InvalidCursor 400.
describe ConcernsOnRails::Controllers::CursorPaginatable do
  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :boundary_items, force: true do |t|
        t.string :title
      end
    end
    stub_const("BoundaryItem", Class.new(TestModel) { self.table_name = "boundary_items" })
    %w[a b c d e].each { |title| BoundaryItem.create!(title: title) }
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  let(:controller_class) do
    Class.new(FakeController) do
      include ConcernsOnRails::Controllers::CursorPaginatable

      cursor_paginate_by order: { title: :asc }, per_page: 2
    end
  end

  def token_for(json)
    [json].pack("m0").tr("+/", "-_").delete("=")
  end

  def cursor(title)
    token_for(JSON.generate("t" => "boundary_items", "o" => ["title:asc", "id:asc"], "d" => "next", "v" => [title, 1]))
  end

  # Only the MySQL adapters both store a NUL in a text column and escape it
  # in a quoted literal, so only there can such a boundary have been minted.
  it "rejects a String boundary carrying a NUL byte as an InvalidCursor (MySQL: pages past it)" do
    controller = controller_class.new(params: { cursor: cursor("a\u0000b") })
    if TestDatabase.mysql?
      expect(controller.cursor_paginated(BoundaryItem.all).map(&:title)).to eq(%w[b c])
    else
      expect { controller.cursor_paginated(BoundaryItem.all) }
        .to raise_error(ConcernsOnRails::Controllers::CursorPaginatable::InvalidCursor)
    end
  end

  it "rejects a String boundary that is not valid UTF-8 as an InvalidCursor" do
    raw = %({"t":"boundary_items","o":["title:asc","id:asc"],"d":"next","v":["\xFF",1]}).b
    expect { controller_class.new(params: { cursor: token_for(raw) }).cursor_paginated(BoundaryItem.all) }
      .to raise_error(ConcernsOnRails::Controllers::CursorPaginatable::InvalidCursor)
  end

  it "still walks every row through minted String boundaries" do
    seen = []
    token = nil
    4.times do
      controller = controller_class.new(params: { cursor: token })
      seen.concat(controller.cursor_paginated(BoundaryItem.all).map(&:title))
      token = controller.cursor_pagination_meta[:next_cursor]
      break unless token
    end
    expect(seen).to eq(%w[a b c d e])
  end

  it "renders the 400 through real ActionController dispatch" do
    controller = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::CursorPaginatable

      cursor_paginate_by order: { title: :asc }, per_page: 2

      def index
        render json: cursor_paginated(BoundaryItem.all).map(&:title)
      end
    end

    raw = %({"t":"boundary_items","o":["title:asc","id:asc"],"d":"next","v":["a\xFFb",1]}).b
    result = IntegrationHarness.dispatch(controller, :index, query: "cursor=#{token_for(raw)}")
    expect(result.status).to eq(400)
    expect(JSON.parse(result.body).dig("error", "code")).to eq("invalid_cursor")
  end
end
