require "spec_helper"

# Regression (audit 2026-10-29, STATE-7): BatchOps.each_record and the relation destroy_all
# loaded records with the caller's partial `select`, so the per-record paths read a column
# the select left out (MissingAttributeError) — while the validator-free fast path and
# ActiveRecord's own Relation#destroy_all worked. Records are loaded in full now.
RSpec.describe "Batch verbs and relation destroy_all over a partial select" do
  before do
    ActiveRecord::Schema.define do
      create_table :ps_posts, force: true do |t|
        t.string :title
        t.integer :author_id
        t.datetime :published_at
        t.datetime :deleted_at
      end
      create_table :ps_authors, force: true do |t|
        t.string :name
      end
    end
  end

  after { %i[ps_posts ps_authors].each { |t| ActiveRecord::Base.connection.drop_table(t, if_exists: true) } }

  let(:publishable) do
    Class.new(TestModel) do
      self.table_name = "ps_posts"
      include ConcernsOnRails::Models::Publishable

      validates :title, length: { maximum: 50 } # keeps publish_all on the per-record path
    end
  end

  let(:deletable) do
    Class.new(TestModel) do
      self.table_name = "ps_posts"
      include ConcernsOnRails::Models::SoftDeletable
    end
  end

  it "publish_all works on the per-record path with select(:id, :title)" do
    publishable.create!(title: "a")
    publishable.create!(title: "b")

    expect(publishable.select(:id, :title).publish_all).to eq(2)
    expect(publishable.unscoped.where.not(published_at: nil).count).to eq(2)
  end

  it "soft_delete_all works with select(:id)" do
    deletable.create!(title: "a")

    expect(deletable.select(:id).soft_delete_all).to eq(1)
    expect(deletable.only_deleted.count).to eq(1)
  end

  it "relation destroy_all soft-deletes over select(:id)" do
    deletable.create!(title: "a")
    deletable.create!(title: "b")

    expect { deletable.select(:id).where(title: "a").destroy_all }.not_to raise_error
    expect(deletable.only_deleted.pluck(:title)).to eq(["a"])
    expect(deletable.pluck(:title)).to eq(["b"])
  end

  it "relation destroy_all purges trashed rows over select(:id)" do
    deletable.create!(title: "a").soft_delete!
    deletable.create!(title: "b")

    expect { deletable.only_deleted.select(:id).destroy_all }.not_to raise_error
    expect(deletable.unscoped.pluck(:title)).to eq(["b"])
  end

  it "relation destroy_all over a limited select(:id) relation (rows loaded up front)" do
    3.times { |i| deletable.create!(title: "t#{i}") }

    expect { deletable.select(:id).order(:id).limit(2).destroy_all }.not_to raise_error
    expect(deletable.only_deleted.count).to eq(2)
  end

  it "keeps the joins and wheres of the relation while loading whole rows" do
    stub_const("PsAuthor", Class.new(TestModel) { self.table_name = "ps_authors" })
    kept = PsAuthor.create!(name: "kept")
    other = PsAuthor.create!(name: "other")
    model = deletable
    model.create!(title: "a", author_id: kept.id)
    model.create!(title: "b", author_id: other.id)

    joined = model.joins("INNER JOIN ps_authors ON ps_authors.id = ps_posts.author_id")
                  .where(ps_authors: { name: "kept" }).select("ps_posts.id")
    expect(joined.soft_delete_all).to eq(1)
    expect(model.only_deleted.pluck(:title)).to eq(["a"])
  end

  it "keeps a computed alias a HAVING reads (the star is added, not substituted)" do
    skip "an alias in HAVING is invalid SQL on PostgreSQL" unless TestDatabase.sqlite?
    stub_const("PsAuthor", Class.new(TestModel) { self.table_name = "ps_authors" })
    busy = PsAuthor.create!(name: "busy")
    quiet = PsAuthor.create!(name: "quiet")
    model = publishable
    2.times { model.create!(title: "b", author_id: busy.id) }
    model.create!(title: "q", author_id: quiet.id)

    relation = model.joins("INNER JOIN ps_authors ON ps_authors.id = ps_posts.author_id")
                    .select("ps_posts.id, COUNT(ps_authors.id) AS n").group("ps_posts.id").having("n > 0")
    expect(relation.publish_all).to eq(3)
    expect(model.unscoped.where(published_at: nil).count).to eq(0)
  end

  it "does not add a second star when the select already carries one" do
    relation = ConcernsOnRails::Support::BatchOps.full_rows(publishable.select("ps_posts.*, 1 AS n"))
    expect(relation.select_values).to eq(["ps_posts.*, 1 AS n"])
    expect(ConcernsOnRails::Support::BatchOps.full_rows(publishable.select(Arel.star)).select_values.size).to eq(1)
    expect(ConcernsOnRails::Support::BatchOps.full_rows(publishable.select("COUNT(*) AS n")).select_values.size).to eq(2)
  end

  it "counts only the model's own star: a joined table's star still gets the model's columns" do
    stub_const("PsAuthor", Class.new(TestModel) { self.table_name = "ps_authors" })
    author = PsAuthor.create!(name: "a")
    publishable.create!(title: "a", author_id: author.id)
    joined = publishable.joins("INNER JOIN ps_authors ON ps_authors.id = ps_posts.author_id")

    expect(joined.select("ps_authors.*").publish_all).to eq(1)
    publishable.update_all(published_at: nil)
    expect(joined.select(PsAuthor.arel_table[Arel.star]).publish_all).to eq(1)
  end

  it "recognizes the model's own star in its quoted and schema-qualified spellings" do
    full = ->(sel) { ConcernsOnRails::Support::BatchOps.full_rows(publishable.select(sel)).select_values.size }
    expect(full.call("*")).to eq(1)
    expect(full.call('"ps_posts".*')).to eq(1)
    expect(full.call("`ps_posts`.*")).to eq(1)
    expect(full.call("main.ps_posts.*")).to eq(1)
    expect(full.call(publishable.arel_table[Arel.star])).to eq(1)
    expect(full.call("ps_authors.*")).to eq(2)
    expect(full.call("my_ps_posts.*")).to eq(2)
  end

  it "runs a limited DISTINCT select(:id) relation without repeating id in the key subquery" do
    3.times { |i| publishable.create!(title: "t#{i}") }
    relation = publishable.select(:id).distinct.order(:title).limit(2)
    sql = []
    callback = ->(*, payload) { sql << payload[:sql] }

    count = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { relation.publish_all }

    expect(count).to eq(2)
    derived = sql.find { |query| query =~ /FROM \(SELECT DISTINCT/ }
    expect(derived).to be_present
    expect(derived[/FROM \(SELECT DISTINCT(.*?) FROM/m, 1].strip).to match(/\A[`"]?ps_posts[`"]?\.\*\z/)
  end

  it "keeps a computed alias the ORDER BY names in the DISTINCT key subquery" do
    %w[c a b].each { |t| publishable.create!(title: t) }
    relation = publishable.select("ps_posts.*, LOWER(title) AS lt").order("lt").distinct.limit(2)

    expect(relation.publish_all).to eq(2)
    expect(publishable.unscoped.where.not(published_at: nil).order(:title).pluck(:title)).to eq(%w[a b])
  end

  it "drops only the plain columns beside a computed alias in the DISTINCT key subquery" do
    %w[c a b].each { |t| publishable.create!(title: t) }
    relation = publishable.select(:id, "LOWER(title) AS lt").order("lt").distinct.limit(2)
    sql = []
    callback = ->(*, payload) { sql << payload[:sql] }

    count = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { relation.publish_all }

    expect(count).to eq(2)
    expect(publishable.unscoped.where.not(published_at: nil).order(:title).pluck(:title)).to eq(%w[a b])
    derived = sql.find { |query| query =~ /FROM \(SELECT DISTINCT/ }
    expect(derived[/FROM \(SELECT DISTINCT(.*?) FROM/m, 1]).not_to match(/[`"]?ps_posts[`"]?\.[`"]?id[`"]?/)
  end

  describe "each_record directly (no full_rows) over a DISTINCT limited computed select" do
    def derived_select_for(relation)
      sql = []
      callback = ->(*, payload) { sql << payload[:sql] }
      records = []
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        ConcernsOnRails::Support::BatchOps.each_record(relation) { |record| records << record }
      end
      [records, sql.find { |query| query =~ /FROM \(SELECT DISTINCT/ }[/FROM \(SELECT DISTINCT(.*?) FROM/m, 1]]
    end

    before { %w[c a b].each { |t| publishable.create!(title: t) } }

    it "keeps the own-table star in front of an alias-only select" do
      skip "the outer load of a DISTINCT alias-only select cannot ORDER BY the primary key on PostgreSQL/MySQL" unless TestDatabase.sqlite?

      relation = publishable.select("LOWER(title) AS lt").order("lt").distinct.limit(2)

      records, derived = derived_select_for(relation)

      # The outer load keeps the caller's select, so no id is loaded (each_record then
      # dedupes the nil keys): only the key subquery is under test here. The outer
      # load reorders by the primary key, which only SQLite lets a DISTINCT alias-only
      # select do, hence the skip elsewhere.
      expect(records).not_to be_empty
      expect(records.map(&:lt) - %w[a b]).to be_empty
      expect(derived).to match(/[`"]?ps_posts[`"]?\.\*/)
    end

    it "keeps the own-table star when a plain column is dropped beside the alias" do
      relation = publishable.select(:id, "LOWER(title) AS lt").order("lt").distinct.limit(2)

      records, derived = derived_select_for(relation)

      expect(records.map(&:id)).to match_array(publishable.where(title: %w[a b]).pluck(:id))
      expect(derived).to match(/[`"]?ps_posts[`"]?\.\*/)
      expect(derived).not_to match(/[`"]?ps_posts[`"]?\.[`"]?id[`"]?/)
    end
  end

  it "leaves an unselected relation alone" do
    publishable.create!(title: "a")

    expect(publishable.all.publish_all).to eq(1)
  end
end
