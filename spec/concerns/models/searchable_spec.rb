require "spec_helper"

describe ConcernsOnRails::Searchable do
  before do
    ActiveRecord::Schema.define do
      create_table :posts, force: true do |t|
        t.string :title
        t.text :body
      end
    end

    class Post < TestModel
      include ConcernsOnRails::Searchable

      searchable_by :title, :body
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  describe ".search" do
    it "matches against any configured column (OR)" do
      Post.create!(title: "Hello world", body: "intro")
      Post.create!(title: "Unrelated",   body: "Hello there")
      Post.create!(title: "Goodbye",     body: "nothing")

      expect(Post.search("hello").pluck(:title)).to match_array(["Hello world", "Unrelated"])
    end

    it "is case-insensitive on SQLite/Postgres (LIKE 'foo' matches 'Foo')" do
      Post.create!(title: "Hello world", body: "")
      expect(Post.search("HELLO").pluck(:title)).to eq(["Hello world"])
    end

    it "matches partial substrings" do
      Post.create!(title: "introduction", body: "")
      expect(Post.search("trod").pluck(:title)).to eq(["introduction"])
    end

    it "returns the full relation when query is nil" do
      Post.create!(title: "a", body: "")
      Post.create!(title: "b", body: "")
      expect(Post.search(nil).count).to eq(2)
    end

    it "returns the full relation when query is blank" do
      Post.create!(title: "a", body: "")
      Post.create!(title: "b", body: "")
      expect(Post.search("   ").count).to eq(2)
    end

    it "treats % in the query as a literal, not a wildcard" do
      Post.create!(title: "100% certain", body: "")
      Post.create!(title: "100 percent",  body: "")

      expect(Post.search("100%").pluck(:title)).to eq(["100% certain"])
    end

    it "treats _ in the query as a literal, not a wildcard" do
      Post.create!(title: "foo_bar", body: "")
      Post.create!(title: "fooxbar", body: "")

      expect(Post.search("foo_bar").pluck(:title)).to eq(["foo_bar"])
    end

    it "is chainable with other scopes" do
      Post.create!(title: "Hello world", body: "")
      Post.create!(title: "Hello again", body: "")

      result = Post.search("hello").where(title: "Hello again")
      expect(result.pluck(:title)).to eq(["Hello again"])
    end
  end

  describe "configuration" do
    it "supports a single column" do
      ActiveRecord::Schema.define do
        create_table :notes, force: true do |t|
          t.string :title
        end
      end

      class Note < TestModel
        include ConcernsOnRails::Searchable

        searchable_by :title
      end

      Note.create!(title: "alpha")
      Note.create!(title: "beta")
      expect(Note.search("alp").pluck(:title)).to eq(["alpha"])
    end

    it "raises ArgumentError when no fields are given" do
      ActiveRecord::Schema.define do
        create_table :empties, force: true do |t|
          t.string :name
        end
      end

      expect do
        class Empty < TestModel
          include ConcernsOnRails::Searchable

          searchable_by
        end
      end.to raise_error(ArgumentError, /at least one field/)
    end

    it "raises ArgumentError when a configured column does not exist" do
      ActiveRecord::Schema.define do
        create_table :bad_posts, force: true do |t|
          t.string :title
        end
      end

      expect do
        class BadPost < TestModel
          include ConcernsOnRails::Searchable

          searchable_by :title, :missing_column
        end
      end.to raise_error(ArgumentError, /'missing_column' does not exist/)
    end
  end

  describe "match modes (1.9)" do
    before do
      ActiveRecord::Schema.define do
        create_table :products, force: true do |t|
          t.string :sku
        end
      end
    end

    it "match: :prefix anchors at the start" do
      class PrefixProduct < TestModel
        self.table_name = "products"
        include ConcernsOnRails::Searchable

        searchable_by :sku, match: :prefix
      end

      PrefixProduct.create!(sku: "ABC-1")
      PrefixProduct.create!(sku: "X-ABC")
      expect(PrefixProduct.search("ABC").pluck(:sku)).to eq(["ABC-1"])
    end

    it "match: :exact requires a full match" do
      class ExactProduct < TestModel
        self.table_name = "products"
        include ConcernsOnRails::Searchable

        searchable_by :sku, match: :exact
      end

      ExactProduct.create!(sku: "ABC")
      ExactProduct.create!(sku: "ABCD")
      expect(ExactProduct.search("ABC").pluck(:sku)).to eq(["ABC"])
    end
  end

  describe "mode: :all (1.9)" do
    before do
      ActiveRecord::Schema.define do
        create_table :books, force: true do |t|
          t.string :title
          t.text :body
        end
      end

      class Book < TestModel
        include ConcernsOnRails::Searchable

        searchable_by :title, :body, mode: :all
      end
    end

    it "requires every whitespace-separated term to match (across any field)" do
      Book.create!(title: "Ruby on Rails", body: "web framework")
      Book.create!(title: "Ruby",          body: "language")

      expect(Book.search("ruby framework").pluck(:title)).to eq(["Ruby on Rails"])
      expect(Book.search("ruby language").pluck(:title)).to eq(["Ruby"])
    end
  end

  describe "option validation (1.9)" do
    before do
      ActiveRecord::Schema.define { create_table(:gadgets, force: true) { |t| t.string :name } }
    end

    it "raises for an unknown mode" do
      expect do
        class BadModeGadget < TestModel
          self.table_name = "gadgets"
          include ConcernsOnRails::Searchable

          searchable_by :name, mode: :bogus
        end
      end.to raise_error(ArgumentError, /unknown mode/)
    end

    it "raises for an unknown match" do
      expect do
        class BadMatchGadget < TestModel
          self.table_name = "gadgets"
          include ConcernsOnRails::Searchable

          searchable_by :name, match: :bogus
        end
      end.to raise_error(ArgumentError, /unknown match/)
    end
  end
  describe "relevance ranking (ranked:)" do
    before do
      ActiveRecord::Schema.define do
        create_table :ranked_posts, force: true do |t|
          t.string :title
          t.text :body
        end
      end
      stub_const("RankedPost", Class.new(TestModel) do
        self.table_name = "ranked_posts"
        include ConcernsOnRails::Searchable

        searchable_by :title, :body, ranked: true
      end)
      stub_const("UnrankedPost", Class.new(TestModel) do
        self.table_name = "ranked_posts"
        include ConcernsOnRails::Searchable

        searchable_by :title, :body
      end)
      RankedPost.create!(title: "Introduction to Ruby", body: "ruby basics") # title contains, body prefix
      RankedPost.create!(title: "ruby", body: "the language")                # title exact
      RankedPost.create!(title: "Rubyists unite", body: "")                  # title prefix
      RankedPost.create!(title: "Gems", body: "Ruby")                        # body exact
      RankedPost.create!(title: "Other", body: "loves ruby")                 # body contains
    end

    it "orders exact before prefix before substring matches, earlier columns first within a tier" do
      expect(RankedPost.search("ruby").pluck(:title))
        .to eq(["ruby", "Gems", "Rubyists unite", "Introduction to Ruby", "Other"])
    end

    it "keeps the relation's existing ORDER BY as the tiebreaker" do
      RankedPost.create!(title: "ruby", body: "another exact")
      expect(RankedPost.order(body: :desc).search("ruby").pluck(:body).first(2)).to eq(["the language", "another exact"])
      expect(RankedPost.order(body: :asc).search("ruby").pluck(:body).first(2)).to eq(["another exact", "the language"])
    end

    it "can be switched on or off per call" do
      expect(UnrankedPost.search("ruby").order_values).to be_empty
      expect(UnrankedPost.search("ruby", ranked: true).pluck(:title).first).to eq("ruby")
      expect(RankedPost.search("ruby", ranked: false).order_values).to be_empty
    end

    it "leaves blank queries unordered and unfiltered" do
      expect(RankedPost.search("").order_values).to be_empty
      expect(RankedPost.search(nil).count).to eq(5)
    end

    it "sums the per-term scores under mode: :all" do
      RankedPost.delete_all
      stub_const("AllRankedPost", Class.new(TestModel) do
        self.table_name = "ranked_posts"
        include ConcernsOnRails::Searchable

        searchable_by :title, :body, mode: :all, ranked: true
      end)
      AllRankedPost.create!(title: "Introduction to Ruby", body: "gems galore") # 4 + 3
      AllRankedPost.create!(title: "Ruby", body: "gems")                        # 0 + 1
      AllRankedPost.create!(title: "rubygems", body: "")                        # 2 + 4
      AllRankedPost.create!(title: "python", body: "gems")                      # excluded: no "ruby"

      expect(AllRankedPost.search("ruby gems").pluck(:title)).to eq(["Ruby", "rubygems", "Introduction to Ruby"])
    end

    it "ranks by column position alone under match: :exact" do
      RankedPost.delete_all
      stub_const("ExactRankedPost", Class.new(TestModel) do
        self.table_name = "ranked_posts"
        include ConcernsOnRails::Searchable

        searchable_by :title, :body, match: :exact, ranked: true
      end)
      ExactRankedPost.create!(title: "x", body: "ruby")
      ExactRankedPost.create!(title: "ruby", body: "x")
      ExactRankedPost.create!(title: "rubyist", body: "rubyist")

      expect(ExactRankedPost.search("ruby").pluck(:title)).to eq(%w[ruby x])
    end

    it "exposes the rank expression through search_rank for select/pluck" do
      ranks = RankedPost.search("ruby").pluck(RankedPost.search_rank("ruby"))
      expect(ranks).to eq([0, 1, 2, 3, 5])
      expect { RankedPost.search_rank("  ") }.to raise_error(ArgumentError, /search_rank needs a non-blank query/)
    end

    it "validates ranked: at class load" do
      expect do
        Class.new(TestModel) do
          self.table_name = "ranked_posts"
          include ConcernsOnRails::Searchable

          searchable_by :title, ranked: :maybe
        end
      end.to raise_error(ArgumentError, /ranked: must be true or false/)
    end
  end
end
