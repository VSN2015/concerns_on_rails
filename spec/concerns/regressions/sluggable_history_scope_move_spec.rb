# Regression (audit 2026-10-29, GRAPH-5): with `history: true` + `scope:`, moving a record
# into a scope whose OTHER record's history holds its slug kept the slug (the taken-check
# read only the live slug column), so friendly_id's history after_save inserted a second
# (slug, sluggable_type, scope) row: RecordNotUnique under the generator's unique index,
# or the old record's URL silently resolving to the mover.
RSpec.describe "Sluggable history: + scope: moving a record between scopes" do
  before do
    ActiveRecord::Schema.define do
      create_table :hs_pages, force: true do |t|
        t.string :title
        t.string :slug
        t.integer :account_id
      end
      create_table :friendly_id_slugs, force: true do |t|
        t.string :slug, null: false
        t.integer :sluggable_id, null: false
        t.string :sluggable_type, limit: 50
        t.string :scope
        t.datetime :created_at
      end
      add_index :friendly_id_slugs, %i[slug sluggable_type scope], unique: true
    end
    stub_const("HsPage", Class.new(TestModel) do
      self.table_name = "hs_pages"
      include ConcernsOnRails::Models::Sluggable

      sluggable_by :title, history: true, scope: :account_id
    end)
  end

  after do
    %i[hs_pages friendly_id_slugs].each { |table| ActiveRecord::Base.connection.drop_table(table, if_exists: true) }
  end

  it "regenerates the slug when another record's history holds it in the new scope" do
    other = HsPage.create!(title: "Foo", account_id: 2)
    other.update!(title: "Bar") # "foo" is now other's history slug in account 2
    mover = HsPage.create!(title: "Foo", account_id: 1)
    expect(mover.slug).to eq("foo")

    expect { mover.update!(account_id: 2) }.not_to raise_error
    expect(mover.reload.slug).not_to eq("foo")
    # the old record keeps its retired slug in account 2's history; the mover has its own new one
    holder = FriendlyId::Slug.find_by!(slug: "foo", scope: "account_id:2")
    expect(holder.sluggable_id).to eq(other.id)
    expect(FriendlyId::Slug.where(slug: mover.slug, scope: "account_id:2").pluck(:sluggable_id)).to eq([mover.id])
  end

  it "keeps the slug when the new scope holds it nowhere (live or history)" do
    other = HsPage.create!(title: "Foo", account_id: 2)
    other.update!(title: "Bar")
    mover = HsPage.create!(title: "Baz", account_id: 1)

    mover.update!(account_id: 2)
    expect(mover.reload.slug).to eq("baz")
  end

  it "does not treat the record's own history as taken" do
    page = HsPage.create!(title: "Foo", account_id: 2)
    page.update!(title: "Bar")
    page.update!(account_id: 3)
    page.update!(account_id: 2)
    expect(page.reload.slug).to eq("bar")
  end

  it "still regenerates on a live-slug clash" do
    HsPage.create!(title: "Foo", account_id: 2)
    mover = HsPage.create!(title: "Foo", account_id: 1)
    mover.update!(account_id: 2)
    expect(mover.reload.slug).not_to eq("foo")
  end
end
