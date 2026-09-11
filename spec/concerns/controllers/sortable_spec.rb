require "spec_helper"

describe ConcernsOnRails::Controllers::Sortable do
  before do
    ActiveRecord::Schema.define do
      create_table :articles, force: true do |t|
        t.string :title
        t.datetime :created_at
      end
    end

    class Article < TestModel
      self.table_name = "articles"
    end

    Article.create!(title: "Charlie", created_at: 3.days.ago)
    Article.create!(title: "Alice",   created_at: 1.day.ago)
    Article.create!(title: "Bob",     created_at: 2.days.ago)
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end

    Object.send(:remove_const, :Article) if Object.const_defined?(:Article)
  end

  let(:controller_class) do
    Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Sortable

      sortable_by :created_at, :title, default: :created_at, direction: :desc
    end
  end

  it "applies a whitelisted sort column from params" do
    controller = controller_class.new(params: { sort: "title", direction: "asc" })
    expect(controller.sorted(Article.all).pluck(:title)).to eq(%w[Alice Bob Charlie])
  end

  it "falls back to the default field when params[:sort] is not whitelisted" do
    controller = controller_class.new(params: { sort: "; DROP TABLE articles;--" })
    # Default field :created_at, default direction :desc — newest first
    expect(controller.sorted(Article.all).first.title).to eq("Alice")
  end

  it "falls back to the default direction when params[:direction] is invalid" do
    controller = controller_class.new(params: { sort: "title", direction: "sideways" })
    # default direction :desc
    expect(controller.sorted(Article.all).pluck(:title)).to eq(%w[Charlie Bob Alice])
  end

  it "uses defaults when no params are given" do
    controller = controller_class.new
    expect(controller.sorted(Article.all).first.title).to eq("Alice")
  end

  it "accepts direction case-insensitively" do
    controller = controller_class.new(params: { sort: "title", direction: "ASC" })
    expect(controller.sorted(Article.all).pluck(:title)).to eq(%w[Alice Bob Charlie])
  end

  it "uses the first declared field as default when :default is not specified" do
    klass = Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Sortable

      sortable_by :title, :created_at
    end
    controller = klass.new
    expect(controller.sorted(Article.all).pluck(:title)).to eq(%w[Alice Bob Charlie])
  end

  it "accepts a default: that clients cannot select, without making it selectable" do
    klass = Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Sortable

      sortable_by :title, default: :created_at, direction: :desc
    end

    # The default orders the relation...
    expect(klass.new.sorted(Article.all).pluck(:title)).to eq(%w[Alice Bob Charlie])
    # ...but it is not in the allow-list, so a client still cannot ask for it.
    expect(klass.sortable_allowed_fields).to eq([:title])
    expect(klass.new(params: { sort: "created_at" }).sorted(Article.all).pluck(:title))
      .to eq(%w[Alice Bob Charlie])
  end

  it "keeps a dotted plain field a qualified column instead of one quoted identifier" do
    klass = Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Sortable

      sortable_by "articles.title"
    end

    sql = klass.new(params: { sort: "articles.title" }).sorted(Article.all).to_sql
    expect(sql).to include('"articles"."title"')
    expect(sql).not_to include('"articles.title"')
  end

  it "raises when no fields are given" do
    expect do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Sortable

        sortable_by
      end
    end.to raise_error(ArgumentError, /at least one field is required/)
  end

  it "overrides an existing ORDER BY (uses reorder, not additive order)" do
    controller = controller_class.new(params: { sort: "title", direction: "asc" })
    pre_ordered = Article.order(title: :desc)
    # Additive .order would keep title DESC first; reorder makes the requested
    # title ASC win.
    expect(controller.sorted(pre_ordered).pluck(:title)).to eq(%w[Alice Bob Charlie])
  end

  it "applies multiple whitelisted columns from a comma-separated sort param" do
    a = Article.create!(title: "Same", created_at: 1.day.ago)
    b = Article.create!(title: "Same", created_at: 2.days.ago)
    controller = controller_class.new(params: { sort: "title,created_at", direction: "asc" })
    # title ties, so created_at asc breaks the tie (older record first)
    result = controller.sorted(Article.where(title: "Same")).to_a
    expect(result).to eq([b, a])
  end
  describe "per-column directions, association columns and NULL ordering" do
    before do
      ActiveRecord::Schema.define do
        create_table :sort_authors, force: true do |t|
          t.string :name
        end
        create_table :sort_posts, force: true do |t|
          t.string :title
          t.integer :sort_author_id
          t.decimal :price, precision: 8, scale: 2
          t.datetime :created_at
        end
      end
      stub_const("SortAuthor", Class.new(TestModel) { self.table_name = "sort_authors" })
      stub_const("SortPost", Class.new(TestModel) do
        self.table_name = "sort_posts"
        belongs_to :sort_author, optional: true
      end)
      zed = SortAuthor.create!(name: "Zed")
      amy = SortAuthor.create!(name: "Amy")
      SortPost.create!(title: "p1", sort_author: zed, price: 10, created_at: 3.days.ago)
      SortPost.create!(title: "p2", sort_author: amy, price: nil, created_at: 1.day.ago)
      SortPost.create!(title: "p3", sort_author: nil, price: 5, created_at: 2.days.ago)
    end

    let(:klass) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Sortable

        sortable_by :created_at, :title,
                    author: { column: "sort_authors.name", joins: :sort_author },
                    price: { nulls: :last },
                    default: :created_at, direction: :desc
      end
    end

    def titles(params)
      klass.new(params: params).sorted(SortPost.all).map(&:title)
    end

    it "honours a - prefix per column (JSON:API style), leaving un-prefixed columns on params[:direction]" do
      expect(titles(sort: "-created_at")).to eq(%w[p2 p3 p1])
      expect(titles(sort: "created_at", direction: "asc")).to eq(%w[p1 p3 p2])
      expect(titles(sort: "-title,created_at", direction: "asc")).to eq(%w[p3 p2 p1])
      expect(titles(sort: "+title", direction: "desc")).to eq(%w[p1 p2 p3])
    end

    it "sorts by an association column through a LEFT OUTER JOIN, keeping rows without the association" do
      result = titles(sort: "+author")
      expect(result).to eq(%w[p2 p1 p3]).or eq(%w[p3 p2 p1]) # NULL placement is adapter-defined
      expect(result.reject { |t| t == "p3" }).to eq(%w[p2 p1])
      expect(titles(sort: "-author").reject { |t| t == "p3" }).to eq(%w[p1 p2])
      expect(titles(sort: "author").reject { |t| t == "p3" }).to eq(%w[p1 p2]) # bare key → default direction (desc)
    end

    it "orders NULLs last when asked, on both directions" do
      expect(titles(sort: "+price")).to eq(%w[p3 p1 p2]) # SQLite would otherwise put NULL first on ASC
      expect(titles(sort: "-price")).to eq(%w[p1 p3 p2])
      expect(titles(sort: "price")).to eq(%w[p1 p3 p2]) # bare key → default direction (desc)
    end

    it "keeps the allow-list strict — unknown keys and raw SQL fall back to the default" do
      expect(titles(sort: "sort_authors.name")).to eq(%w[p2 p3 p1]) # default: created_at desc
      expect(titles(sort: "-title; DROP TABLE sort_posts;--")).to eq(%w[p2 p3 p1])
      expect(klass.sortable_allowed_fields).to eq(%i[created_at title author price])
    end

    it "does not add the join when no association column is requested" do
      sql = klass.new(params: { sort: "title" }).sorted(SortPost.all).to_sql
      expect(sql).not_to match(/JOIN/i)
      joined = klass.new(params: { sort: "author" }).sorted(SortPost.all).to_sql
      expect(joined).to match(/LEFT OUTER JOIN "sort_authors"/i)
    end

    it "supports an inner join when asked (join: :inner) and still reorders any prior ORDER BY" do
      inner = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Sortable

        sortable_by :title, author: { column: "sort_authors.name", joins: :sort_author, join: :inner }
      end
      result = inner.new(params: { sort: "author" }).sorted(SortPost.order(title: :desc)).map(&:title)
      expect(result).to eq(%w[p2 p1]) # p3 has no author → dropped by the INNER JOIN
    end

    it "validates the declaration at class load" do
      build = lambda do |**rules|
        Class.new(FakeController) do
          include ConcernsOnRails::Controllers::Sortable

          sortable_by(:title, **rules)
        end
      end
      expect { build.call(author: { column: "name; DROP" }) }
        .to raise_error(ArgumentError, /column: must be a Symbol or a "table.column" String/)
      expect { build.call(author: { column: "sort_authors.name", nulls: :middle }) }
        .to raise_error(ArgumentError, /nulls: must be :first or :last/)
      expect { build.call(author: { column: "sort_authors.name", join: :cross }) }
        .to raise_error(ArgumentError, /join: must be :left or :inner/)
      expect { build.call(author: { colum: "sort_authors.name" }) }.to raise_error(ArgumentError, /unknown option\(s\) for author: colum/)
    end
  end
end
