# Regression (audit 2026-10-10, SCOPE-3): an explicitly assigned blank slug —
# "" from an optional form field, or nil (friendly_id's documented way to ask
# for a fresh slug) — was stored as is instead of being built from the source,
# because the "explicit slug wins" guard ran before the blank-slug backfill.
RSpec.describe "Sluggable with a blank slug assigned" do
  before do
    ActiveRecord::Schema.define do
      create_table :blank_slug_pages, force: true do |t|
        t.string :title
        t.string :slug
        t.timestamps
      end
    end
    stub_const("BlankSlugPage", Class.new(TestModel) do
      self.table_name = "blank_slug_pages"
      include ConcernsOnRails::Models::Sluggable

      sluggable_by :title
    end)
  end

  after do
    ActiveRecord::Base.connection.drop_table(:blank_slug_pages, if_exists: true)
  end

  it "builds the slug from the source when a create passes an empty slug" do
    page = BlankSlugPage.create!(title: "Hello World", slug: "")
    expect(page.slug).to eq("hello-world")
    expect(page.reload.slug).to eq("hello-world")
  end

  it "does not trip the slug's unique index on a second blank-slug create" do
    ActiveRecord::Base.connection.add_index(:blank_slug_pages, :slug, unique: true)
    BlankSlugPage.create!(title: "One", slug: "")
    two = BlankSlugPage.create!(title: "Two", slug: "")
    expect(two.reload.slug).to eq("two")
  end

  it "rebuilds the slug from the source when an update passes an empty slug" do
    page = BlankSlugPage.create!(title: "Hello World")
    page.update!(title: "Hello World", slug: "")
    expect(page.reload.slug).to eq("hello-world")
  end

  it "regenerates the slug when it is set to nil (friendly_id's idiom)" do
    page = BlankSlugPage.create!(title: "Hello World")
    page.update!(title: "Hello Again")
    expect(page.slug).to eq("hello-again")

    page.slug = nil
    page.save!
    expect(page.reload.slug).to eq("hello-again")
  end

  it "keeps a non-blank explicitly assigned slug" do
    page = BlankSlugPage.create!(title: "Hello World", slug: "custom")
    expect(page.reload.slug).to eq("custom")

    page.update!(title: "Renamed", slug: "other")
    expect(page.reload.slug).to eq("other")
  end

  it "stores a blank slug when the source is blank too (nothing to build it from)" do
    page = BlankSlugPage.create!(title: "Hello World")
    page.update!(title: "", slug: nil)
    expect(page.reload.slug).to be_nil
  end
end
