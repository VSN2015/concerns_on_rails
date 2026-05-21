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
end
