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

  it "leaves an unselected relation alone" do
    publishable.create!(title: "a")

    expect(publishable.all.publish_all).to eq(1)
  end
end
