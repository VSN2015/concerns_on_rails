require "spec_helper"

RSpec.describe "Sluggable candidates: with every candidate blank" do
  before do
    ActiveRecord::Schema.define do
      create_table :blank_candidate_pages, force: true do |t|
        t.string :title
        t.string :subtitle
        t.string :slug
      end
    end
  end
  after { ActiveRecord::Base.connection.drop_table(:blank_candidate_pages) }

  def page_class(**opts)
    stub_const("BlankCandidatePage", Class.new(TestModel) { self.table_name = "blank_candidate_pages" })
    BlankCandidatePage.include ConcernsOnRails::Models::Sluggable
    BlankCandidatePage.sluggable_by :title, **opts
    BlankCandidatePage
  end

  it "does not mint a bare-uuid slug, with or without candidates:" do
    expect(page_class.create!(title: nil).slug).to be_nil
    expect(page_class(candidates: [:title, %i[title subtitle]]).create!(title: nil).slug).to be_nil
  end

  it "still builds the slug when one candidate is usable" do
    klass = page_class(candidates: [:title, %i[title subtitle]])
    expect(klass.create!(title: "Hello", subtitle: "World").slug).to eq("hello")
  end
end
