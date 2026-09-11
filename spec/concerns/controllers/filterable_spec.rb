require "spec_helper"

describe ConcernsOnRails::Controllers::Filterable do
  before do
    ActiveRecord::Schema.define do
      create_table :articles, force: true do |t|
        t.string :title
        t.string :status
        t.string :category
        t.datetime :published_at
      end
    end

    class Article < TestModel
      self.table_name = "articles"
      scope :published, -> { where.not(published_at: nil) }
    end

    Article.create!(title: "A", status: "draft", category: "news")
    Article.create!(title: "B", status: "published", category: "news", published_at: Time.zone.now)
    Article.create!(title: "C", status: "published", category: "blog", published_at: Time.zone.now)
    Article.create!(title: "D", status: "draft", category: "blog")
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end

    Object.send(:remove_const, :Article) if Object.const_defined?(:Article)
  end

  describe "direct where mode" do
    let(:controller_class) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable

        filter_by :status, :category
      end
    end

    it "filters by a single param" do
      controller = controller_class.new(params: { status: "published" })
      expect(controller.filtered(Article.all).pluck(:title)).to match_array(%w[B C])
    end

    it "composes multiple filters" do
      controller = controller_class.new(params: { status: "published", category: "blog" })
      expect(controller.filtered(Article.all).pluck(:title)).to eq(["C"])
    end

    it "skips blank params" do
      controller = controller_class.new(params: { status: "" })
      expect(controller.filtered(Article.all).count).to eq(4)
    end

    it "skips missing params" do
      controller = controller_class.new
      expect(controller.filtered(Article.all).count).to eq(4)
    end

    it "ignores a nested-hash param instead of raising (no 500)" do
      controller = controller_class.new(params: { status: { gt: "5" } })
      expect { controller.filtered(Article.all).to_a }.not_to raise_error
      expect(controller.filtered(Article.all).count).to eq(4)
    end
  end

  describe "scope mode" do
    let(:controller_class) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable

        filter_by :published, scope: :published
      end
    end

    it "calls the named scope when param is present and truthy" do
      controller = controller_class.new(params: { published: "1" })
      expect(controller.filtered(Article.all).pluck(:title)).to match_array(%w[B C])
    end

    it "skips when param is blank" do
      controller = controller_class.new
      expect(controller.filtered(Article.all).count).to eq(4)
    end
  end

  describe "lambda mode" do
    let(:controller_class) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable

        filter_by :q, with: ->(rel, v) { rel.where("title LIKE ?", "%#{v}%") }
      end
    end

    it "delegates to the lambda" do
      controller = controller_class.new(params: { q: "C" })
      expect(controller.filtered(Article.all).pluck(:title)).to eq(["C"])
    end
  end

  describe "configuration errors" do
    it "raises when no fields are given" do
      expect do
        Class.new(FakeController) do
          include ConcernsOnRails::Controllers::Filterable

          filter_by
        end
      end.to raise_error(ArgumentError, /at least one field is required/)
    end

    it "raises when both :scope and :with are passed" do
      expect do
        Class.new(FakeController) do
          include ConcernsOnRails::Controllers::Filterable

          filter_by :status, scope: :published, with: ->(rel, _v) { rel }
        end
      end.to raise_error(ArgumentError, /pass either :scope or :with, not both/)
    end
  end
  describe "operators and type coercion" do
    before do
      ActiveRecord::Schema.define do
        create_table :products, force: true do |t|
          t.string :name
          t.string :status
          t.decimal :price, precision: 10, scale: 2
          t.integer :stock
          t.datetime :discontinued_at
        end
      end

      class Product < TestModel
        self.table_name = "products"
      end

      Product.create!(name: "Lamp 100% cotton shade", status: "active", price: 10, stock: 5)
      Product.create!(name: "Desk", status: "active", price: 250.5, stock: 0, discontinued_at: Time.zone.now)
      Product.create!(name: "Chair", status: "archived", price: 99.99, stock: 12)
      Product.create!(name: "Lampshade", status: "draft", price: 30, stock: 1)
    end

    after(:each) { Object.send(:remove_const, :Product) if Object.const_defined?(:Product) }

    let(:controller_class) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable

        filter_by :price, :stock, :status, :name, :discontinued_at, operators: true
      end
    end

    def names(params)
      controller_class.new(params: params).filtered(Product.order(:id)).pluck(:name)
    end

    it "keeps plain equality working" do
      expect(names(status: "active")).to eq(["Lamp 100% cotton shade", "Desk"])
    end

    it "supports gt / gte / lt / lte with the suffix form, cast through the column type" do
      expect(names(price_gte: "30")).to eq(%w[Desk Chair Lampshade])
      expect(names(price_gt: "30")).to eq(%w[Desk Chair])
      expect(names(price_lt: "30")).to eq(["Lamp 100% cotton shade"])
      expect(names(price_lte: "30")).to eq(["Lamp 100% cotton shade", "Lampshade"])
      expect(names(price_gte: "20", price_lte: "100")).to eq(%w[Chair Lampshade])
    end

    it "supports the bracket form ?price[gte]=…&price[lte]=…" do
      expect(names(price: { gte: "20", lte: "100" })).to eq(%w[Chair Lampshade])
    end

    it "supports not / in / not_in (comma list or array)" do
      expect(names(status_not: "active")).to eq(%w[Chair Lampshade])
      expect(names(status_in: "archived,draft")).to eq(%w[Chair Lampshade])
      expect(names(status_in: %w[archived draft])).to eq(%w[Chair Lampshade])
      expect(names(status_not_in: "archived, draft")).to eq(["Lamp 100% cotton shade", "Desk"])
    end

    it "supports null=true/false" do
      expect(names(discontinued_at_null: "true")).to eq(["Lamp 100% cotton shade", "Chair", "Lampshade"])
      expect(names(discontinued_at_null: "false")).to eq(["Desk"])
      expect(names(discontinued_at_null: "0")).to eq(["Desk"])
    end

    it "supports contains / starts_with with LIKE wildcards escaped" do
      expect(names(name_contains: "amp")).to eq(["Lamp 100% cotton shade", "Lampshade"])
      expect(names(name_starts_with: "Lamp")).to eq(["Lamp 100% cotton shade", "Lampshade"])
      expect(names(name_contains: "100%")).to eq(["Lamp 100% cotton shade"])
      expect(names(name_contains: "100% c")).to eq(["Lamp 100% cotton shade"])
      expect(names(name_contains: "_")).to eq([])
    end

    it "casts comparison values through the column type (integer column, string param)" do
      expect(names(stock_gte: "5")).to eq(["Lamp 100% cotton shade", "Chair"])
      expect(names(stock_lt: "1")).to eq(["Desk"])
    end

    it "skips blank operator values and ignores non-scalar ones" do
      expect(names(price_gte: "")).to eq(["Lamp 100% cotton shade", "Desk", "Chair", "Lampshade"])
      expect(names(price_gte: { nested: "1" })).to eq(["Lamp 100% cotton shade", "Desk", "Chair", "Lampshade"])
      expect(names(status_in: [{ x: 1 }])).to eq(["Lamp 100% cotton shade", "Desk", "Chair", "Lampshade"])
    end

    it "ignores unknown bracket keys and, without operators:, ignores suffix params entirely" do
      expect(names(price: { between: "1,2" })).to eq(["Lamp 100% cotton shade", "Desk", "Chair", "Lampshade"])

      plain = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable

        filter_by :price
      end
      expect(plain.new(params: { price_gte: "30" }).filtered(Product.all).count).to eq(4)
    end

    it "honours an operator subset" do
      subset = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable

        filter_by :price, operators: %i[gte]
      end
      expect(subset.new(params: { price_gte: "30", price_lte: "50" }).filtered(Product.order(:id)).pluck(:name))
        .to eq(%w[Desk Chair Lampshade])
    end

    it "type: overrides the cast and pre-casts the value handed to a with: lambda" do
      klass = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable

        filter_by :min_stock, type: :integer, with: ->(rel, v) { rel.where(rel.model.arel_table[:stock].gteq(v)) }
        filter_by :since, type: :date, with: ->(rel, v) { rel.where("discontinued_at >= ?", v) }
      end
      seen = nil
      probe = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable

        filter_by :min_stock, type: :integer, with: lambda { |rel, v|
          seen = v
          rel
        }
      end
      probe.new(params: { min_stock: "5" }).filtered(Product.all)
      expect(seen).to eq(5)

      expect(klass.new(params: { min_stock: "5" }).filtered(Product.order(:id)).pluck(:name)).to eq(["Lamp 100% cotton shade", "Chair"])
      expect(klass.new(params: { since: (Time.zone.today - 1).iso8601 }).filtered(Product.order(:id)).pluck(:name)).to eq(["Desk"])
      expect(klass.new(params: { since: (Time.zone.today + 2).iso8601 }).filtered(Product.order(:id)).pluck(:name)).to eq([])
    end

    it "hands a with: lambda the RAW value when no type: is declared, even on a real column" do
      # The param name matches a column, but without type: the lambda must
      # still receive the String it always did — an existing lambda comparing
      # v == "1" or doing string work must not silently stop matching.
      seen = nil
      probe = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable

        filter_by :stock, with: lambda { |rel, v|
          seen = v
          rel
        }
      end
      probe.new(params: { stock: "5" }).filtered(Product.all)
      expect(seen).to eq("5")
      expect(seen).to be_a(String)

      seen_date = nil
      dates = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable

        filter_by :discontinued_at, with: lambda { |rel, v|
          seen_date = v
          rel
        }
      end
      dates.new(params: { discontinued_at: "2020-01-02" }).filtered(Product.all)
      expect(seen_date).to eq("2020-01-02")
    end

    it "records the rule so the configuration is introspectable" do
      expect(controller_class.filterable_rules[:price]).to include(operators: described_class::OPERATORS, type: nil)
    end

    describe "configuration errors" do
      it "rejects operators: with scope: or with:" do
        expect do
          Class.new(FakeController) do
            include ConcernsOnRails::Controllers::Filterable

            filter_by :status, scope: :published, operators: true
          end
        end.to raise_error(ArgumentError, /operators: only apply to direct-where filters/)
      end

      it "rejects unknown operator names, listing the valid ones" do
        expect do
          Class.new(FakeController) do
            include ConcernsOnRails::Controllers::Filterable

            filter_by :price, operators: %i[gte between]
          end
        end.to raise_error(ArgumentError, /unknown operator\(s\) :between.*valid: :not, :gt/)
      end

      it "rejects an unknown type:" do
        expect do
          Class.new(FakeController) do
            include ConcernsOnRails::Controllers::Filterable

            filter_by :price, type: :money
          end
        end.to raise_error(ArgumentError, /type: :money is not an ActiveModel type/)
      end
    end
  end
end
