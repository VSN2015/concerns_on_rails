# Regression (audit 2026-10-10, SCOPE-4): `ranked:` search on a DISTINCT
# relation ordered by the rank CASE expression, which is not in the SELECT
# list. PostgreSQL ("for SELECT DISTINCT, ORDER BY expressions must appear in
# select list") and MySQL 5.7.5+ reject that; SQLite accepts it, so the SQL is
# asserted on directly.
RSpec.describe "Searchable ranked search on a DISTINCT relation" do
  before do
    ActiveRecord::Schema.define do
      create_table :ranked_distinct_articles, force: true do |t|
        t.string :title
      end
    end
    stub_const("RankedDistinctArticle", Class.new(TestModel) do
      self.table_name = "ranked_distinct_articles"
      include ConcernsOnRails::Models::Searchable

      searchable_by :title, ranked: true
    end)
    RankedDistinctArticle.create!(title: "Introduction to ruby")
    RankedDistinctArticle.create!(title: "ruby")
    RankedDistinctArticle.create!(title: "Python")
  end

  after do
    ActiveRecord::Base.connection.drop_table(:ranked_distinct_articles, if_exists: true)
  end

  let(:rank_order) { "ORDER BY CASE WHEN #{TestDatabase.qualified('ranked_distinct_articles', 'title')}" }

  it "returns a DISTINCT relation unranked (no ORDER BY outside the SELECT list)" do
    sql = RankedDistinctArticle.distinct.search("ruby").to_sql
    expect(sql).to start_with("SELECT DISTINCT")
    expect(sql).not_to include("CASE")
    expect(RankedDistinctArticle.distinct.search("ruby").map(&:title))
      .to contain_exactly("Introduction to ruby", "ruby")
  end

  it "keeps a DISTINCT relation's own ORDER BY" do
    sql = RankedDistinctArticle.distinct.order(:title).search("ruby").to_sql
    expect(sql).not_to include("CASE")
    expect(sql).to include("ORDER BY #{TestDatabase.qualified('ranked_distinct_articles', 'title')} ASC")
  end

  it "still ranks a plain relation" do
    relation = RankedDistinctArticle.search("ruby")
    expect(relation.to_sql).to include(rank_order)
    expect(relation.map(&:title)).to eq(["ruby", "Introduction to ruby"])
  end

  it "still ranks when distinct is turned back off" do
    expect(RankedDistinctArticle.distinct.distinct(false).search("ruby").to_sql).to include(rank_order)
  end
end
