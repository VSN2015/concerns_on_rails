require "spec_helper"

describe ConcernsOnRails::Publishable do
  before do
    ActiveRecord::Schema.define do
      create_table :articles, force: true do |t|
        t.string :title
        t.datetime :published_at
        t.boolean :is_published
      end
    end

    class Article < TestModel
      include ConcernsOnRails::Publishable

      publishable_by :published_at
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  it "defaults to unpublished" do
    article = Article.create!(title: "Draft")
    expect(article.published?).to be false
    expect(article.unpublished?).to be true
  end

  it "publishes and unpublishes the article" do
    article = Article.create!(title: "News")
    article.publish!
    expect(article.published?).to be true

    article.unpublish!
    expect(article.published?).to be false
    expect(article.unpublished?).to be true
  end

  it "returns only published articles" do
    Article.create!(title: "Visible Article", published_at: Time.now)
    Article.create!(title: "Hidden Article", published_at: nil)
    expect(Article.published.map(&:title)).to eq(["Visible Article"])
  end

  it "returns only unpublished articles" do
    Article.create!(title: "Visible Article", published_at: Time.now)
    Article.create!(title: "Hidden Article", published_at: nil)
    expect(Article.unpublished.map(&:title)).to eq(["Hidden Article"])
  end

  it "allows dynamic field configuration" do
    ActiveRecord::Schema.define do
      create_table :custom_articles, force: true do |t|
        t.string :title
        t.boolean :is_published
      end
    end

    class CustomArticle < TestModel
      include ConcernsOnRails::Publishable

      publishable_by :is_published
    end

    article = CustomArticle.create!(title: "Custom")
    expect(article.published?).to be false

    article.publish!
    expect(article.published?).to be true

    article.unpublish!
    expect(article.unpublished?).to be true
  end

  it "raises error if field does not exist" do
    ActiveRecord::Schema.define do
      create_table :invalid_articles, force: true do |t|
        t.string :title
        t.datetime :published_at
        t.boolean :is_published
      end
    end

    expect do
      class InvalidArticle < TestModel
        include ConcernsOnRails::Publishable

        publishable_by :non_existing_field
      end
    end.to raise_error(ArgumentError)
  end

  it "supports custom publish time" do
    article = Article.create!(title: "Timed")
    time = Time.now - 1.day
    article.update(published_at: time)
    expect(article.published?).to be true
    expect(article.published_at.to_i).to eq(time.to_i)
  end

  it "allows multiple reconfigurations with different fields" do
    ActiveRecord::Schema.define do
      create_table :reconfig_articles, force: true do |t|
        t.string :title
        t.datetime :published_at
        t.boolean :is_published
      end
    end

    class ReconfigArticle < TestModel
      include ConcernsOnRails::Publishable
    end

    ReconfigArticle.publishable_by :is_published
    expect(ReconfigArticle.publishable_field).to eq(:is_published)

    ReconfigArticle.publishable_by :published_at
    expect(ReconfigArticle.publishable_field).to eq(:published_at)
  end

  describe "scheduling helpers (1.9)" do
    it ".scheduled returns only future-dated records" do
      Article.create!(title: "past",   published_at: 1.day.ago)
      Article.create!(title: "future", published_at: 1.day.from_now)
      Article.create!(title: "draft",  published_at: nil)
      expect(Article.scheduled.map(&:title)).to eq(["future"])
    end

    it ".draft returns only records with no timestamp" do
      Article.create!(title: "pub",   published_at: 1.day.ago)
      Article.create!(title: "draft", published_at: nil)
      expect(Article.draft.map(&:title)).to eq(["draft"])
    end

    it "#scheduled? / #draft? reflect the record state" do
      expect(Article.new(published_at: 1.day.from_now).scheduled?).to be true
      expect(Article.new(published_at: 1.day.ago).scheduled?).to be false
      expect(Article.new(published_at: nil).draft?).to be true
      expect(Article.new(published_at: 1.day.ago).draft?).to be false
    end

    it "#publish_at! schedules a future publish" do
      article = Article.create!(title: "t")
      article.publish_at!(1.day.from_now)
      expect(article.reload.scheduled?).to be true
      expect(article.published?).to be false
    end
  end

  describe "default_scope: true" do
    before do
      ActiveRecord::Schema.define do
        create_table :scoped_posts, force: true do |t|
          t.string :title
          t.datetime :published_at
        end
      end

      class ScopedPost < TestModel
        include ConcernsOnRails::Publishable

        publishable_by :published_at, default_scope: true
      end
    end

    it "hides unpublished records by default but keeps them reachable" do
      ScopedPost.create!(title: "live",   published_at: 1.day.ago)
      ScopedPost.create!(title: "draft",  published_at: nil)
      ScopedPost.create!(title: "future", published_at: 1.day.from_now)

      expect(ScopedPost.all.map(&:title)).to eq(["live"])
      expect(ScopedPost.draft.map(&:title)).to eq(["draft"])
      expect(ScopedPost.scheduled.map(&:title)).to eq(["future"])
      expect(ScopedPost.unscoped.count).to eq(3)
    end
  end
end
