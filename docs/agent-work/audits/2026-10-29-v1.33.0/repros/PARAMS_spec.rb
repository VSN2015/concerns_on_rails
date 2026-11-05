require "spec_helper"

# PARAMS slice audit — concerns_on_rails v1.33.0.
# Every example asserts the CORRECT behaviour; a failure demonstrates the bug.
describe "PARAMS audit" do
  after(:each) do
    ConcernsOnRails.encryption.key = nil
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  describe "PARAMS-1 Filterable on an encryptable column" do
    before do
      ConcernsOnRails.encryption.key = "params-audit-key-params-audit-key"
      ActiveRecord::Schema.define do
        create_table :params_secrets, force: true do |t|
          t.string :name
          t.text :ssn
        end
      end
    end

    let(:model) do
      Class.new(TestModel) do
        self.table_name = "params_secrets"
        include ConcernsOnRails::Models::Encryptable
        encryptable :ssn
      end
    end

    let(:controller_class) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable
        filter_by :ssn, operators: true
      end
    end

    before do
      model.create!(name: "match", ssn: "123")
      model.create!(name: "other", ssn: "999")
    end

    it "PARAMS-1 never returns the row a ?ssn_not= excludes" do
      names = controller_class.new(params: { ssn_not: "123" }).filtered(model.all).pluck(:name)
      expect(names).not_to include("match")
    end

    it "PARAMS-1 never returns the row a ?ssn_not_in= excludes" do
      names = controller_class.new(params: { ssn_not_in: "123" }).filtered(model.all).pluck(:name)
      expect(names).not_to include("match")
    end
  end

  describe "PARAMS-2 re-declaring a controller macro in a subclass" do
    it "PARAMS-2 keeps the parent's Paginatable cap, style and link_header when a subclass only changes per_page" do
      parent = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Paginatable
        paginate_by per_page: 10, max_per_page: 20, style: :jsonapi, link_header: false
      end
      child = Class.new(parent) { paginate_by per_page: 5 }

      expect(child.paginatable_max_per_page).to eq(20)
      expect(child.paginatable_page_param).to eq(%w[page number])
      expect(child.paginatable_link_header).to be(false)
    end

    it "PARAMS-2 still enforces the parent's max_per_page on a subclass's requests" do
      parent = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Paginatable
        paginate_by max_per_page: 20
      end
      child = Class.new(parent) { paginate_by per_page: 5 }

      controller = child.new(params: { per_page: "200" })
      controller.paginated((1..500).to_a)
      expect(controller.response.headers["X-Per-Page"]).to eq("20")
    end

    it "PARAMS-2 keeps the parent's Includable strategy and fieldsets when a subclass adds an association" do
      parent = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Includable
        includable :author, fields: { articles: %i[id title] }, default: :author, strategy: :preload
      end
      child = Class.new(parent) { includable :author, :comments }

      expect(child.includable_strategy).to eq(:preload)
      expect(child.includable_fields).to eq(articles: %i[id title])
    end
  end

  describe "PARAMS-3 Paginatable count of a grouped relation with HAVING on a select alias" do
    before do
      ActiveRecord::Schema.define do
        create_table :params_rows, force: true do |t|
          t.string :category
        end
      end
    end

    it "PARAMS-3 counts the groups instead of raising StatementInvalid" do
      model = Class.new(TestModel) { self.table_name = "params_rows" }
      %w[a b a].each { |category| model.create!(category: category) }
      relation = model.select("category, COUNT(*) AS n").group(:category).having("n > 1")
      expect(relation.to_a.size).to eq(1) # the relation itself is valid SQL here

      controller = Class.new(FakeController) { include ConcernsOnRails::Controllers::Paginatable }.new(params: {})
      expect { controller.paginated(relation).to_a }.not_to raise_error
      expect(controller.response.headers["X-Total-Count"]).to eq("1")
    end
  end

  describe "PARAMS-4 CursorPaginatable predicate: :row with mixed directions" do
    before do
      ActiveRecord::Schema.define do
        create_table :params_feed, force: true do |t|
          t.string :name, null: false, default: ""
          t.integer :score, null: false, default: 0
          t.datetime :created_at, precision: 6, null: false
        end
      end
    end

    it "PARAMS-4 either refuses the declaration or serves the cursor it minted" do
      model = Class.new(TestModel) { self.table_name = "params_feed" }
      5.times { |i| model.create!(name: "x#{i}", score: i % 2, created_at: Time.utc(2026, 1, 1) + i) }
      klass = Class.new(FakeController) { include ConcernsOnRails::Controllers::CursorPaginatable }

      refused = false
      begin
        klass.cursor_paginate_by order: { score: :desc, created_at: :asc }, per_page: 2, predicate: :row
      rescue ArgumentError
        refused = true # refusing at class load is an acceptable fix
      end
      next if refused

      first = klass.new(params: {})
      expect(first.cursor_paginated(model.all).map(&:name)).to eq(%w[x1 x3])
      token = first.response.headers["X-Next-Cursor"]
      expect(token).to be_present
      expect { klass.new(params: { cursor: token }).cursor_paginated(model.all) }.not_to raise_error
    end
  end

  describe "PARAMS-5 CursorPaginatable NUL byte in a stored String boundary (SQLite)" do
    before do
      ActiveRecord::Schema.define do
        create_table :params_names, force: true do |t|
          t.string :name, null: false, default: ""
        end
      end
    end

    it "PARAMS-5 walks past a row whose ordering value holds a NUL (the cursor is one the gem minted)" do
      model = Class.new(TestModel) { self.table_name = "params_names" }
      %W[a b c d\u0000x e f].each { |name| model.create!(name: name) }
      klass = Class.new(FakeController) { include ConcernsOnRails::Controllers::CursorPaginatable }
      klass.cursor_paginate_by order: { name: :asc }, per_page: 2

      seen = []
      token = nil
      4.times do
        controller = klass.new(params: token ? { cursor: token } : {})
        seen.concat(controller.cursor_paginated(model.all).map(&:name))
        token = controller.response.headers["X-Next-Cursor"]
        break unless token
      end
      expect(seen).to eq(%W[a b c d\u0000x e f])
    end
  end

  describe "PARAMS-6 / PARAMS-8 Filterable operand reading" do
    before do
      ActiveRecord::Schema.define do
        create_table :params_items, force: true do |t|
          t.string :name
          t.float :score
          t.datetime :deleted_at
        end
      end
    end

    let(:model) { Class.new(TestModel) { self.table_name = "params_items" } }

    let(:controller_class) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable
        filter_by :deleted_at, :score, operators: true
      end
    end

    before do
      model.create!(name: "live", score: 0.1)
      model.create!(name: "gone", score: 0.2, deleted_at: Time.utc(2026, 1, 1))
    end

    it "PARAMS-6 does not read a non-boolean ?<field>_null= value as true" do
      names = controller_class.new(params: { deleted_at_null: "maybe" }).filtered(model.all).pluck(:name)
      expect(names).not_to eq(["live"]) # ignored (both rows) or failed closed ([]) — never IS NULL
    end

    it "PARAMS-8 compares a float operand exactly: the stored double 0.1 lies above 0.1000000000000000000001" do
      names = controller_class.new(params: { score_gt: "0.1000000000000000000001" }).filtered(model.all).pluck(:name)
      expect(names).to match_array(%w[live gone])
    end

    it "PARAMS-8 matches nothing for a float operand no double equals" do
      names = controller_class.new(params: { score: "0.1000000000000000000001" }).filtered(model.all).pluck(:name)
      expect(names).to eq([])
    end
  end

  describe "PARAMS-7 ScalarParam reads page/per_page with String#to_i" do
    it "PARAMS-7 does not read ?per_page=1e3 as 1" do
      controller = Class.new(FakeController) { include ConcernsOnRails::Controllers::Paginatable }.new(params: { per_page: "1e3" })
      controller.paginated((1..300).to_a)
      expect(controller.response.headers["X-Per-Page"]).not_to eq("1") # 200 (capped) or 25 (rejected), never 1
    end
  end
end
