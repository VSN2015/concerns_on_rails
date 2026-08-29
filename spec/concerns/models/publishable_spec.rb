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

  describe "boolean publishable column" do
    before do
      ActiveRecord::Schema.define do
        create_table :flag_articles, force: true do |t|
          t.string :title
          t.boolean :is_published
        end
      end

      class FlagArticle < TestModel
        include ConcernsOnRails::Publishable

        publishable_by :is_published
      end
    end

    it "uses equality predicates for the scopes (not a time comparison)" do
      FlagArticle.create!(title: "live",  is_published: true)
      FlagArticle.create!(title: "off",   is_published: false)
      FlagArticle.create!(title: "blank", is_published: nil)

      expect(FlagArticle.published.map(&:title)).to eq(["live"])
      expect(FlagArticle.unpublished.map(&:title)).to match_array(%w[off blank])
      expect(FlagArticle.draft.map(&:title)).to match_array(%w[off blank])
      expect(FlagArticle.scheduled.to_a).to be_empty
    end

    it "raises from publish_at! — a Time would cast to true and publish NOW (1.26)" do
      article = FlagArticle.create!(title: "soon")

      expect { article.publish_at!(1.day.from_now) }
        .to raise_error(ArgumentError, /publish_at! needs a timestamp column/)
      expect(article.reload.is_published).to be_falsey
    end
  end

  describe "lifecycle callbacks" do
    it "fires before/after_publish and before/after_unpublish" do
      klass = Class.new(TestModel) do
        self.table_name = "articles"
        include ConcernsOnRails::Publishable

        publishable_by :published_at

        attr_reader :log

        def before_publish = (@log ||= []) << :before_publish
        def after_publish = (@log ||= []) << :after_publish
        def before_unpublish = (@log ||= []) << :before_unpublish
        def after_unpublish = (@log ||= []) << :after_unpublish
      end

      article = klass.create!(title: "t")
      article.publish!
      article.unpublish!
      expect(article.log).to eq(%i[before_publish after_publish before_unpublish after_unpublish])
    end
  end

  describe "scope affixing" do
    before do
      ActiveRecord::Schema.define do
        create_table :affixed_articles, force: true do |t|
          t.datetime :published_at
        end
      end
    end

    it "keeps the default scope names when no affix is given" do
      klass = Class.new(TestModel) do
        self.table_name = "affixed_articles"
        include ConcernsOnRails::Publishable
        publishable_by
      end

      expect(klass).to respond_to(:published)
      expect(klass).to respond_to(:draft)
    end

    it "keeps the default scope names when the macro is never called" do
      klass = Class.new(TestModel) do
        self.table_name = "affixed_articles"
        include ConcernsOnRails::Publishable
      end

      expect(klass).to respond_to(:published)
    end

    it "defines affixed names and removes the defaults" do
      klass = Class.new(TestModel) do
        self.table_name = "affixed_articles"
        include ConcernsOnRails::Publishable
        publishable_by :published_at, prefix: :article
      end

      expect(klass).to respond_to(:article_published)
      expect(klass).to respond_to(:article_draft)
      expect(klass).not_to respond_to(:published)
      expect(klass).not_to respond_to(:draft)
    end

    it "accepts prefix: true, meaning the field name" do
      klass = Class.new(TestModel) do
        self.table_name = "affixed_articles"
        include ConcernsOnRails::Publishable
        publishable_by :published_at, prefix: true
      end

      expect(klass).to respond_to(:published_at_published)
    end

    it "returns the right rows through the affixed scopes" do
      klass = Class.new(TestModel) do
        self.table_name = "affixed_articles"
        include ConcernsOnRails::Publishable
        publishable_by :published_at, suffix: :posts
      end
      live = klass.create!(published_at: 1.day.ago)
      klass.create!(published_at: nil)

      expect(klass.published_posts.pluck(:id)).to eq([live.id])
      expect(klass.draft_posts.count).to eq(1)
    end

    it "keeps default_scope: true working under an affix" do
      klass = Class.new(TestModel) do
        self.table_name = "affixed_articles"
        include ConcernsOnRails::Publishable
        publishable_by :published_at, prefix: :article, default_scope: true
      end
      live = klass.create!(published_at: 1.day.ago)
      klass.create!(published_at: nil)

      expect(klass.all.pluck(:id)).to eq([live.id])
      expect(klass.article_draft.count).to eq(1)
    end

    it "raises when affixing on a subclass whose parent owns the scopes" do
      parent = Class.new(TestModel) do
        self.table_name = "affixed_articles"
        include ConcernsOnRails::Publishable
        publishable_by
      end
      stub_const("AffixedParentArticle", parent)

      expect do
        Class.new(parent) { publishable_by :published_at, prefix: :child }
      end.to raise_error(ArgumentError, /AffixedParentArticle/)
    end
  end

  describe "batch operations" do
    before do
      ActiveRecord::Schema.define do
        create_table :batch_articles, force: true do |t|
          t.datetime :published_at
          t.string :title
        end
      end

      stub_const("BatchArticle", Class.new(TestModel) do
        self.table_name = "batch_articles"
        include ConcernsOnRails::Publishable

        publishable_by
      end)
    end

    def capture_sql
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
        statements << args.last[:sql].to_s
      end
      yield
      statements
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "publishes every unpublished record and returns the count" do
      BatchArticle.create!(published_at: nil)
      BatchArticle.create!(published_at: nil)
      already = BatchArticle.create!(published_at: 2.days.ago)

      expect(BatchArticle.publish_all).to eq(2)
      expect(BatchArticle.where(published_at: nil).count).to eq(0)
      expect(already.reload.published_at).to be_within(1.second).of(2.days.ago)
    end

    it "is idempotent — a second call transitions nothing" do
      BatchArticle.create!(published_at: nil)
      BatchArticle.publish_all

      expect(BatchArticle.publish_all).to eq(0)
    end

    it "respects the relation" do
      keep = BatchArticle.create!(published_at: nil)
      BatchArticle.create!(published_at: nil)

      expect(BatchArticle.where.not(id: keep.id).publish_all).to eq(1)
      expect(keep.reload.published_at).to be_nil
    end

    it "issues exactly one UPDATE on the fast path" do
      2.times { BatchArticle.create!(published_at: nil) }

      statements = capture_sql { BatchArticle.publish_all }

      expect(statements.grep(/^UPDATE/).length).to eq(1)
    end

    it "unpublishes every published record" do
      BatchArticle.create!(published_at: 1.day.ago)
      BatchArticle.create!(published_at: nil)

      expect(BatchArticle.unpublish_all).to eq(1)
      expect(BatchArticle.where.not(published_at: nil).count).to eq(0)
    end

    it "runs the hooks once per record when they are overridden" do
      stub_const("HookedArticle", Class.new(TestModel) do
        self.table_name = "batch_articles"
        include ConcernsOnRails::Publishable

        publishable_by

        cattr_accessor :published_ids
        self.published_ids = []

        def after_publish
          self.class.published_ids << id
        end
      end)
      a = HookedArticle.create!(published_at: nil)
      b = HookedArticle.create!(published_at: nil)

      expect(HookedArticle.publish_all).to eq(2)
      expect(HookedArticle.published_ids).to match_array([a.id, b.id])
    end

    it "rolls the whole batch back when a record fails" do
      stub_const("FailingArticle", Class.new(TestModel) do
        self.table_name = "batch_articles"
        include ConcernsOnRails::Publishable

        publishable_by

        def publish!
          false
        end
      end)
      FailingArticle.create!(published_at: nil)

      expect { FailingArticle.publish_all }.to raise_error(ActiveRecord::RecordNotSaved)
      expect(FailingArticle.where(published_at: nil).count).to eq(1)
    end

    it "cannot take the fast path when the model has validations — an invalid record rolls the whole batch back" do
      stub_const("ValidatedArticle", Class.new(TestModel) do
        self.table_name = "batch_articles"
        include ConcernsOnRails::Publishable

        publishable_by
        validates :title, presence: true
      end)
      valid = ValidatedArticle.create!(title: "ok", published_at: nil)
      invalid = ValidatedArticle.create!(title: "temporary", published_at: nil)
      invalid.update_column(:title, nil)

      expect { ValidatedArticle.publish_all }.to raise_error(ActiveRecord::RecordNotSaved)
      expect(valid.reload.published_at).to be_nil
      expect(invalid.reload.published_at).to be_nil
    end
  end
end
