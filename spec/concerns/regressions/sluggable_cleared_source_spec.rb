# Regression (audit 2026-10-10, SCOPE-7): a source change alone triggered
# regeneration, even when the new source was blank or normalized to nothing.
# friendly_id then found no usable candidate and fell back to a bare random
# UUID, so clearing an optional title silently replaced "about" with
# "968f1b14-..." and broke every existing URL.
RSpec.describe "Sluggable when the slug source is cleared" do
  before do
    ActiveRecord::Schema.define do
      create_table :cleared_source_pages, force: true do |t|
        t.string :title
        t.string :slug
        t.integer :account_id
      end
    end
    stub_const("ClearedSourcePage", Class.new(TestModel) do
      self.table_name = "cleared_source_pages"
      include ConcernsOnRails::Models::Sluggable

      sluggable_by :title
    end)
  end

  after do
    ActiveRecord::Base.connection.drop_table(:cleared_source_pages, if_exists: true)
  end

  it "keeps the existing slug when the source is set to nil" do
    page = ClearedSourcePage.create!(title: "About")
    page.update!(title: nil)
    expect(page.reload.slug).to eq("about")
  end

  it "keeps the existing slug when the source is set to blank" do
    page = ClearedSourcePage.create!(title: "About")
    page.update!(title: "   ")
    expect(page.reload.slug).to eq("about")
  end

  it "keeps the existing slug when the new source normalizes to nothing" do
    page = ClearedSourcePage.create!(title: "About")
    page.update!(title: "!!!")
    expect(page.reload.slug).to eq("about")
  end

  it "still regenerates when the new source is usable" do
    page = ClearedSourcePage.create!(title: "About")
    page.update!(title: "Contact Us")
    expect(page.reload.slug).to eq("contact-us")
  end

  it "still falls back to a uuid on create when no slug exists and the source normalizes to nothing" do
    page = ClearedSourcePage.create!(title: "!!!")
    expect(page.reload.slug).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
  end

  it "still rebuilds through regenerate_slug!" do
    page = ClearedSourcePage.create!(title: "About")
    page.update_columns(slug: "custom")
    page.regenerate_slug!
    expect(page.reload.slug).to eq("about")
  end

  context "with scope:" do
    before do
      stub_const("ClearedSourcePage", Class.new(TestModel) do
        self.table_name = "cleared_source_pages"
        include ConcernsOnRails::Models::Sluggable

        sluggable_by :title, scope: :account_id
      end)
    end

    it "keeps the slug when the source is cleared within the same scope" do
      page = ClearedSourcePage.create!(title: "About", account_id: 1)
      page.update!(title: nil)
      expect(page.reload.slug).to eq("about")
    end

    # A blank source cannot build a slug, but a record moved into a scope that
    # already holds its slug still must not duplicate it there.
    it "still gives a moved record a unique slug when its slug is taken in the new scope" do
      ClearedSourcePage.create!(title: "About", account_id: 2)
      page = ClearedSourcePage.create!(title: "About", account_id: 1)
      page.update!(title: nil, account_id: 2)
      expect(page.reload.slug).not_to eq("about")
      expect(ClearedSourcePage.where(account_id: 2, slug: page.slug).count).to eq(1)
    end
  end
end
