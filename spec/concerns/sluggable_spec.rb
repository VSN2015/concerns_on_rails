describe ConcernsOnRails::Sluggable do
  before do
    ActiveRecord::Schema.define do
      create_table :pages, force: true do |t|
        t.string :title
        t.string :slug
        t.timestamps
      end
    end

    class Page < TestModel
      extend FriendlyId
      include ConcernsOnRails::Sluggable

      sluggable_by :title
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"
      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  it "generates slug from field" do
    page = Page.create!(title: "My First Page")
    expect(page.slug).to eq("my-first-page")
  end

  it "returns slug_source from field" do
    page = Page.new(title: "Nice Page")
    expect(page.slug_source).to eq("Nice Page")
  end

  it "updates slug if title changes" do
    page = Page.create!(title: "Initial Title")
    page.update(title: "Updated Title")
    expect(page.slug).to eq("updated-title")
  end

  it "falls back to to_s if sluggable_field is missing" do
    ActiveRecord::Schema.define do
      create_table :fallback_models, force: true do |t|
        t.string :slug
      end
    end

    class FallbackModel < TestModel
      def to_s
        "fallback-value"
      end

      def self.column_names
        []
      end

      include ConcernsOnRails::Sluggable
    end

    expect(FallbackModel.new.slug_source).to eq("fallback-value")
  end

  it "raises error if sluggable field is missing" do
    ActiveRecord::Schema.define do
      create_table :invalid_pages, force: true do |t|
        t.string :title
        t.string :slug
      end
    end

    expect do
      class InvalidPage < TestModel
        include ConcernsOnRails::Sluggable
        sluggable_by :nonexistent_field
      end
    end.to raise_error(ArgumentError)
  end

  it "supports dynamic sluggable field" do
    ActiveRecord::Schema.define do
      create_table :dynamic_pages, force: true do |t|
        t.string :custom_title
        t.string :slug
      end
    end

    class DynamicPage < TestModel
      extend FriendlyId
      include ConcernsOnRails::Sluggable
  
      sluggable_by :custom_title
    end
  
    page = DynamicPage.create!(custom_title: "Dynamic Slug")
    expect(page.slug).to eq("dynamic-slug")
  end

  it "ensures unique slugs for duplicate titles" do
    Page.create!(title: "Same")
    second = Page.create!(title: "Same")
    expect(second.slug).to match(/^same(-[-\w]+)?$/)
  end

  it "generates slug from unicode characters" do
    page = Page.create!(title: "Tiếng Việt có dấu")
    expect(page.slug).to eq("ti-ng-vi-t-co-d-u")
  end

  it "does not update slug if sluggable field did not change" do
    page = Page.create!(title: "Same Title")
    original_slug = page.slug
    page.update(updated_at: Time.now)
    expect(page.slug).to eq(original_slug)
  end
end
