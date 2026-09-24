# frozen_string_literal: true

require "spec_helper"

describe ConcernsOnRails::Taggable do
  before(:each) do
    ActiveRecord::Schema.define do
      create_table :tag_articles, force: true do |t|
        t.string :title
        t.string :tags
        t.timestamps
      end
    end

    class TagArticle < TestModel
      include ConcernsOnRails::Taggable

      taggable_by :tags
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
    Object.send(:remove_const, :TagArticle) if defined?(TagArticle)
  end

  describe ".taggable_by" do
    it "raises if the column does not exist" do
      ActiveRecord::Schema.define do
        create_table :no_tag_models, force: true do |t|
          t.string :title
        end
      end

      expect do
        Class.new(TestModel) do
          self.table_name = "no_tag_models"
          include ConcernsOnRails::Taggable

          taggable_by :tags
        end
      end.to raise_error(ArgumentError, /'tags' does not exist/)
    end

    # An empty delimiter split every stored value into single characters.
    it "raises on an empty delimiter" do
      [nil, ""].each do |delimiter|
        expect do
          Class.new(TestModel) do
            self.table_name = "tag_articles"
            include ConcernsOnRails::Taggable

            taggable_by :tags, delimiter: delimiter
          end
        end.to raise_error(ArgumentError, /delimiter: must be a non-empty String/)
      end
    end
  end

  # tagged_with matches the NORMALIZED column form ("ruby,rails"); a row
  # written around the callback (update_column, raw SQL, an import) as
  # "ruby, rails" was invisible to it while tagged_with? found the tag.
  # normalize_tags! is the repair path.
  describe ".normalize_tags!" do
    def legacy(raw)
      TagArticle.create!(title: raw.to_s).tap { |a| a.update_columns(tags: raw) }
    end

    it "rewrites rows to the normalized form so tagged_with finds them" do
      spaced = legacy("ruby, rails , Ruby")
      blank = legacy(" , ")
      clean = TagArticle.create!(tag_list: %w[go])
      untagged = TagArticle.create!(title: "none")
      expect(TagArticle.tagged_with("rails")).to be_empty # documented limitation

      expect(TagArticle.normalize_tags!).to eq(2)

      expect(spaced.reload[:tags]).to eq("ruby,rails,Ruby")
      expect(blank.reload[:tags]).to be_nil
      expect(clean.reload[:tags]).to eq("go")
      expect(untagged.reload[:tags]).to be_nil
      expect(TagArticle.tagged_with("rails")).to contain_exactly(spaced)
      expect(TagArticle.normalize_tags!).to eq(0) # idempotent
    end

    it "follows the current scope" do
      a = legacy("a, b")
      b = legacy("c, d")

      expect(TagArticle.where(id: a.id).normalize_tags!).to eq(1)
      expect(a.reload[:tags]).to eq("a,b")
      expect(b.reload[:tags]).to eq("c, d")
    end
  end

  describe "#tag_list" do
    it "accepts a string and splits, strips, de-dupes" do
      expect(TagArticle.new(tag_list: "ruby, rails, ruby").tag_list).to eq(%w[ruby rails])
    end

    it "accepts an array" do
      expect(TagArticle.new(tag_list: ["ruby", " rails "]).tag_list).to eq(%w[ruby rails])
    end

    it "is empty for a blank value" do
      expect(TagArticle.new.tag_list).to eq([])
      expect(TagArticle.new(tag_list: "").tag_list).to eq([])
    end

    it "stores nil when cleared" do
      a = TagArticle.create!(title: "t", tag_list: "ruby")
      a.update!(tag_list: [])
      expect(a.reload[:tags]).to be_nil
    end
  end

  describe "before_validation normalization" do
    it "normalizes a directly-assigned raw column value" do
      a = TagArticle.create!(title: "t", tags: " ruby ,rails, ruby ")
      expect(a.reload[:tags]).to eq("ruby,rails")
      expect(a.tag_list).to eq(%w[ruby rails])
    end
  end

  describe "#add_tags / #remove_tags" do
    it "adds without duplicating" do
      a = TagArticle.new(tag_list: "ruby")
      a.add_tags("rails", "ruby")
      expect(a.tag_list).to eq(%w[ruby rails])
    end

    it "removes tags" do
      a = TagArticle.new(tag_list: "ruby, rails, go")
      a.remove_tags("rails")
      expect(a.tag_list).to eq(%w[ruby go])
    end
  end

  describe "#tagged_with?" do
    it "reflects membership" do
      a = TagArticle.new(tag_list: "ruby, rails")
      expect(a.tagged_with?("ruby")).to be(true)
      expect(a.has_tag?("go")).to be(false)
    end
  end

  describe "tags containing the delimiter" do
    # A tag can never survive with the delimiter inside it (the column format
    # cannot escape it) — pre-1.26 such input silently split on the NEXT
    # normalize pass; now it splits eagerly and identically everywhere.
    it "splits eagerly in add_tags / tag_list= / remove_tags" do
      a = TagArticle.new
      a.add_tags("a,b")
      expect(a.tag_list).to eq(%w[a b])

      a.tag_list = ["c,d", "e"]
      expect(a.tag_list).to eq(%w[c d e])

      a.remove_tags("c,d")
      expect(a.tag_list).to eq(%w[e])
    end

    it "answers tagged_with? with AND semantics (mirrors the class-level scope)" do
      a = TagArticle.new(tag_list: %w[c d e])
      expect(a.tagged_with?("c,d")).to be(true)
      expect(a.tagged_with?("c,x")).to be(false)
      expect(a.tagged_with?("")).to be(false)
    end
  end

  describe ".tagged_with" do
    let!(:a1) { TagArticle.create!(title: "a1", tag_list: "ruby, rails") }
    let!(:a2) { TagArticle.create!(title: "a2", tag_list: "ruby, go") }
    let!(:a3) { TagArticle.create!(title: "a3", tag_list: "rails") }

    it "matches ALL tags by default (AND)" do
      expect(TagArticle.tagged_with("ruby", "rails")).to contain_exactly(a1)
    end

    it "matches ANY tag with any: true (OR)" do
      expect(TagArticle.tagged_with("go", "rails", any: true)).to contain_exactly(a1, a2, a3)
    end

    it "matches a single tag" do
      expect(TagArticle.tagged_with("ruby")).to contain_exactly(a1, a2)
    end

    it "returns all records when given no tags" do
      expect(TagArticle.tagged_with).to contain_exactly(a1, a2, a3)
    end

    it "is chainable like a scope" do
      expect(TagArticle.tagged_with("ruby").where(title: "a1")).to contain_exactly(a1)
    end

    it "is boundary-safe (no substring matching)" do
      a4 = TagArticle.create!(title: "a4", tag_list: "rail")
      expect(TagArticle.tagged_with("rail")).to contain_exactly(a4)
      expect(TagArticle.tagged_with("rails")).to contain_exactly(a1, a3)
    end

    it "matches tags containing LIKE wildcard characters literally" do
      under = TagArticle.create!(title: "under", tag_list: "ruby_on_rails")
      expect(TagArticle.tagged_with("ruby_on_rails")).to contain_exactly(under)
      expect(TagArticle.tagged_with("ruby")).to contain_exactly(a1, a2)
    end

    it "matches a single-tag column case-insensitively (consistent with the LIKE branches)" do
      mixed = TagArticle.create!(title: "mixed", tag_list: "Elixir")
      expect(TagArticle.tagged_with("elixir")).to contain_exactly(mixed)
    end

    it "matches case-insensitively in every position of the column, on every adapter" do
      # LIKE folds case on SQLite and under MySQL's default _ci collation, but
      # NOT on PostgreSQL — so tagged_with silently meant two different things
      # until the predicate started asking Arel for a case-insensitive match
      # (which is ILIKE on PostgreSQL). All four boundary branches, not just
      # the whole-column one above.
      first = TagArticle.create!(title: "first", tag_list: "Elixir, ruby")
      middle = TagArticle.create!(title: "middle", tag_list: "ruby, Elixir, go")
      last = TagArticle.create!(title: "last", tag_list: "go, Elixir")

      expect(TagArticle.tagged_with("elixir")).to contain_exactly(first, middle, last)
      expect(TagArticle.tagged_with("ELIXIR", "RUBY")).to contain_exactly(first, middle)
    end

    it "quotes the LIKE ESCAPE character through the adapter" do
      # An inlined `ESCAPE '\'` parses on SQLite and PostgreSQL but is a syntax
      # error on MySQL, where the backslash escapes its own closing quote inside
      # a string literal. Comparing against the connection's own quoting pins
      # that the escape goes through the adapter, on whichever adapter is running.
      escape = ActiveRecord::Base.connection.quote("\\")

      expect(TagArticle.tagged_with("ruby").to_sql).to include("ESCAPE #{escape}")
    end
  end

  describe ".all_tags" do
    it "returns the sorted unique tags in use" do
      TagArticle.create!(title: "a", tag_list: "ruby, rails")
      TagArticle.create!(title: "b", tag_list: "ruby, go")
      expect(TagArticle.all_tags).to eq(%w[go rails ruby])
    end

    context "when the model carries an ordering default_scope" do
      # SELECT DISTINCT with an ORDER BY on a column that is not in the select
      # list is a hard error on PostgreSQL ("for SELECT DISTINCT, ORDER BY
      # expressions must appear in select list"). SQLite permits it, which is
      # why CI never caught this — and Models::Sortable installs exactly such
      # a default_scope, so Taggable + Sortable was broken on Postgres.
      before do
        class OrderedTagArticle < TestModel
          include ConcernsOnRails::Taggable

          self.table_name = "tag_articles"

          taggable_by :tags
          default_scope { order(:title) }
        end
      end

      after { Object.send(:remove_const, :OrderedTagArticle) if defined?(OrderedTagArticle) }

      def captured_sql
        queries = []
        sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
          queries << payload[:sql]
        end
        yield
        queries
      ensure
        ActiveSupport::Notifications.unsubscribe(sub)
      end

      it "does not carry the ORDER BY into the DISTINCT query" do
        distinct = captured_sql { OrderedTagArticle.all_tags }.grep(/DISTINCT/)

        expect(distinct).not_to be_empty
        expect(distinct.first).not_to include("ORDER BY")
      end

      it "still returns the sorted unique tags" do
        OrderedTagArticle.create!(title: "a", tag_list: "ruby, rails")
        OrderedTagArticle.create!(title: "b", tag_list: "ruby, go")

        expect(OrderedTagArticle.all_tags).to eq(%w[go rails ruby])
      end
    end
  end

  context "with downcase: true" do
    before do
      ActiveRecord::Schema.define do
        create_table :tag_skills, force: true do |t|
          t.string :name
          t.string :tag_names
        end
      end

      class TagSkill < TestModel
        include ConcernsOnRails::Taggable

        taggable_by :tag_names, downcase: true
      end
    end

    after { Object.send(:remove_const, :TagSkill) if defined?(TagSkill) }

    it "case-folds on write and matches case-insensitively" do
      s = TagSkill.create!(name: "s", tag_list: "Ruby, RAILS")
      expect(s.tag_list).to eq(%w[ruby rails])
      expect(TagSkill.tagged_with("RUBY")).to contain_exactly(s)
      expect(s.tagged_with?("Rails")).to be(true)
    end
  end

  context "with a custom delimiter" do
    before do
      ActiveRecord::Schema.define do
        create_table :tag_posts, force: true do |t|
          t.string :keywords
        end
      end

      class TagPost < TestModel
        include ConcernsOnRails::Taggable

        taggable_by :keywords, delimiter: "|"
      end
    end

    after { Object.send(:remove_const, :TagPost) if defined?(TagPost) }

    it "splits and joins on the delimiter" do
      p = TagPost.create!(tag_list: "ruby|rails")
      expect(p.reload[:keywords]).to eq("ruby|rails")
      expect(p.tag_list).to eq(%w[ruby rails])
      expect(TagPost.tagged_with("rails")).to contain_exactly(p)
    end
  end

  context "with a LIKE-wildcard delimiter" do
    before do
      ActiveRecord::Schema.define do
        create_table :tag_docs, force: true do |t|
          t.string :labels
        end
      end

      class TagDoc < TestModel
        include ConcernsOnRails::Taggable

        taggable_by :labels, delimiter: "%"
      end
    end

    after { Object.send(:remove_const, :TagDoc) if defined?(TagDoc) }

    it "treats a wildcard delimiter literally (no false positives)" do
      hit = TagDoc.create!(tag_list: %w[ruby rails]) # stored "ruby%rails"
      TagDoc.create!(tag_list: ["rubyXrails"]) # single tag, must NOT match
      expect(TagDoc.tagged_with("ruby")).to contain_exactly(hit)
    end
  end
  describe ".tag_counts" do
    before do
      TagArticle.create!(title: "a", tag_list: "ruby, rails")
      TagArticle.create!(title: "b", tag_list: "ruby, go")
      TagArticle.create!(title: "c", tag_list: "ruby")
      TagArticle.create!(title: "d", tag_list: "go, api")
      TagArticle.create!(title: "e")
    end

    it "returns tag => record count, ordered by count desc then tag asc" do
      expect(TagArticle.tag_counts).to eq("ruby" => 3, "go" => 2, "api" => 1, "rails" => 1)
      expect(TagArticle.tag_counts.keys).to eq(%w[ruby go api rails])
    end

    it "counts a record once per tag even when the stored string repeats it" do
      TagArticle.create!(title: "f").update_column(:tags, "ruby,ruby, Ruby ")
      expect(TagArticle.tag_counts["ruby"]).to eq(4)
      expect(TagArticle.tag_counts["Ruby"]).to eq(1) # case-sensitive without downcase:
    end

    it "is relation-aware" do
      expect(TagArticle.where(title: %w[a b]).tag_counts).to eq("ruby" => 2, "go" => 1, "rails" => 1)
      expect(TagArticle.tagged_with("go").tag_counts).to eq("go" => 2, "api" => 1, "ruby" => 1)
      expect(TagArticle.order(:title).tag_counts.keys.first).to eq("ruby") # an ORDER BY on the relation is harmless
    end

    it "supports limit: for tag clouds" do
      expect(TagArticle.tag_counts(limit: 2)).to eq("ruby" => 3, "go" => 2)
      expect(TagArticle.tag_counts(limit: 0)).to eq({})
    end

    it "tallies a select/group-carrying relation instead of raising" do
      # COUNT(id, tags) is invalid SQL and an array GROUP BY key is meaningless,
      # so both clauses are stripped before the aggregate runs.
      expect(TagArticle.select(:id, :tags).tag_counts).to eq("ruby" => 3, "go" => 2, "api" => 1, "rails" => 1)
      expect(TagArticle.group(:title).tag_counts).to eq("ruby" => 3, "go" => 2, "api" => 1, "rails" => 1)
    end

    it "honours limit/offset on the relation instead of counting the whole table" do
      window = TagArticle.order(:title).limit(2)
      expect(window.tag_counts).to eq("ruby" => 2, "rails" => 1, "go" => 1) # rows a and b only
      expect(TagArticle.order(:title).offset(3).tag_counts).to eq("api" => 1, "go" => 1) # row d (and untagged e)
    end

    it "clamps a negative limit: instead of raising" do
      expect(TagArticle.tag_counts(limit: -1)).to eq({})
    end

    it "returns {} when nothing is tagged" do
      TagArticle.delete_all
      expect(TagArticle.tag_counts).to eq({})
    end

    it "groups identical tag strings in SQL rather than plucking every row" do
      sql = []
      callback = ->(*, payload) { sql << payload[:sql] if payload[:sql] =~ /\ASELECT/i }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        TagArticle.tag_counts
      end
      expect(sql.size).to eq(1)
      expect(sql.first).to match(/GROUP BY/i)
      expect(sql.first).to match(/COUNT\(/i)
    end

    it "case-folds with downcase: true so Ruby and ruby are one tag" do
      folded = Class.new(TestModel) do
        self.table_name = "tag_articles"
        include ConcernsOnRails::Taggable

        taggable_by :tags, downcase: true
      end
      folded.create!(title: "g", tag_list: "Ruby, RAILS")
      expect(folded.tag_counts).to include("ruby" => 4, "rails" => 2)
    end
  end
end
