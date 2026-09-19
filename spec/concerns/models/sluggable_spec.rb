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

  it "backfills a NULL slug on save even when the source field did not change" do
    page = Page.create!(title: "Backfill Me")
    page.update_column(:slug, nil) # legacy/imported row with no slug
    page.update!(updated_at: Time.now)
    expect(page.reload.slug).to eq("backfill-me")
  end

  it "does not overwrite an explicitly-assigned slug when the source also changes" do
    page = Page.create!(title: "Original")
    page.update!(title: "Brand New Title", slug: "custom-slug")
    expect(page.reload.slug).to eq("custom-slug")
  end

  describe "scoped slugs (1.9)" do
    before do
      ActiveRecord::Schema.define do
        create_table :scoped_pages, force: true do |t|
          t.string :title
          t.string :slug
          t.integer :account_id
        end
      end

      class ScopedPage < TestModel
        include ConcernsOnRails::Sluggable

        sluggable_by :title, scope: :account_id
      end
    end

    it "allows the same slug under different scopes" do
      a = ScopedPage.create!(title: "Hello", account_id: 1)
      b = ScopedPage.create!(title: "Hello", account_id: 2)
      expect(a.slug).to eq("hello")
      expect(b.slug).to eq("hello")
    end

    it "accepts an association name as the scope (1.26 — no missing-column error)" do
      ActiveRecord::Schema.define do
        create_table :slug_accounts, force: true do |t|
          t.string :name
        end
        create_table :assoc_scoped_pages, force: true do |t|
          t.string :title
          t.string :slug
          t.integer :slug_account_id
        end
      end

      class SlugAccount < TestModel; end

      # ColumnGuard used to reject this: `scope: :slug_account` is an
      # association, not a column, and friendly_id resolves it itself.
      class AssocScopedPage < TestModel
        include ConcernsOnRails::Sluggable

        belongs_to :slug_account, optional: true
        sluggable_by :title, scope: :slug_account
      end

      one = SlugAccount.create!(name: "one")
      two = SlugAccount.create!(name: "two")
      a = AssocScopedPage.create!(title: "Hello", slug_account: one)
      b = AssocScopedPage.create!(title: "Hello", slug_account: two)
      expect(a.slug).to eq("hello")
      expect(b.slug).to eq("hello")
    ensure
      %i[AssocScopedPage SlugAccount].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    end
  end

  describe "slug history (1.9)" do
    before do
      ActiveRecord::Schema.define do
        create_table :versioned_pages, force: true do |t|
          t.string :title
          t.string :slug
        end
        create_table :friendly_id_slugs, force: true do |t|
          t.string   :slug, null: false
          t.integer  :sluggable_id, null: false
          t.string   :sluggable_type, limit: 50
          t.string   :scope
          t.datetime :created_at
        end
      end

      class VersionedPage < TestModel
        include ConcernsOnRails::Sluggable

        sluggable_by :title, history: true
      end
    end

    it "keeps resolving an old slug after the title changes" do
      page = VersionedPage.create!(title: "First Title")
      old_slug = page.slug
      page.update!(title: "Second Title")

      expect(page.reload.slug).to eq("second-title")
      expect(VersionedPage.friendly.find(old_slug)).to eq(page)
    end
  end

  describe "reserved words (1.12)" do
    before do
      ActiveRecord::Schema.define do
        create_table :reserved_pages, force: true do |t|
          t.string :title
          t.string :slug
        end
      end

      class ReservedPage < TestModel
        include ConcernsOnRails::Sluggable

        sluggable_by :title, reserved_words: %w[new edit]
      end
    end

    it "rejects a reserved slug with a validation error" do
      expect { ReservedPage.create!(title: "new") }.to raise_error(ActiveRecord::RecordInvalid, /reserved/i)
    end

    it "still slugs a non-reserved title normally" do
      page = ReservedPage.create!(title: "Hello World")
      expect(page.slug).to eq("hello-world")
    end
  end

  describe "finders (1.12)" do
    before do
      ActiveRecord::Schema.define do
        create_table :findable_pages, force: true do |t|
          t.string :title
          t.string :slug
        end
      end

      class FindablePage < TestModel
        include ConcernsOnRails::Sluggable

        sluggable_by :title, finders: true
      end
    end

    it "finds a record by its slug via .find" do
      page = FindablePage.create!(title: "Hello World")
      expect(FindablePage.find("hello-world")).to eq(page)
    end
  end

  describe "candidates:, max_length: and regenerate_slug!" do
    before do
      ActiveRecord::Schema.define do
        create_table :candidate_pages, force: true do |t|
          t.string :title
          t.string :subtitle
          t.string :slug
          t.timestamps
        end
      end
    end

    def candidate_class(**opts)
      stub_const("CandidatePage", Class.new(TestModel) do
        self.table_name = "candidate_pages"
        include ConcernsOnRails::Sluggable

        sluggable_by :title, **opts
      end)
      CandidatePage
    end

    it "tries the candidates in order before falling back to friendly_id's uuid suffix" do
      klass = candidate_class(candidates: [:title, %i[title subtitle]])
      expect(klass.create!(title: "Hello", subtitle: "one").slug).to eq("hello")
      expect(klass.create!(title: "Hello", subtitle: "two").slug).to eq("hello-two")
      # friendly_id resolves a total conflict by suffixing the FIRST candidate with a uuid
      expect(klass.create!(title: "Hello", subtitle: "two").slug).to match(/\Ahello-[0-9a-f-]{36}\z/)
      expect(klass.sluggable_candidates).to eq([:title, %i[title subtitle]])
    end

    it "keeps regenerating from the primary field only, and backfills through the candidates" do
      klass = candidate_class(candidates: [:title, %i[title subtitle]])
      page = klass.create!(title: "Hello", subtitle: "one")
      page.update!(subtitle: "changed")
      expect(page.slug).to eq("hello") # a candidate-only field change does not churn the URL
      page.update!(title: "Bye")
      expect(page.slug).to eq("bye")

      page.update_column(:slug, nil)
      page.reload.save!
      expect(page.slug).to eq("bye")
    end

    it "max_length: truncates the slug at a word boundary (the uniqueness suffix is added after)" do
      klass = candidate_class(max_length: 12)
      first = klass.create!(title: "The quick brown fox jumps")
      expect(first.slug).to eq("the-quick")
      second = klass.create!(title: "The quick brown fox jumps")
      expect(second.slug).to match(/\Athe-quick-[0-9a-f-]{36}\z/)
      expect(klass.create!(title: "Short").slug).to eq("short")
    end

    it "regenerate_slug! rebuilds the slug from the current source, even over a manually assigned one" do
      page = Page.create!(title: "First Post")
      page.update!(slug: "custom-handle")
      expect(page.reload.slug).to eq("custom-handle") # explicit assignment still wins on a normal save

      expect(page.regenerate_slug!).to be(true)
      expect(page.reload.slug).to eq("first-post")

      Page.create!(title: "Taken")
      other = Page.create!(title: "Other")
      other.update!(title: "Taken")
      other.regenerate_slug!
      expect(other.slug).to match(/\Ataken-[0-9a-f-]{36}\z/) # still unique
    end

    it "validates candidates: and max_length:" do
      expect { candidate_class(candidates: :title) }.to raise_error(ArgumentError, /candidates: must be an Array/)
      expect { candidate_class(max_length: 0) }.to raise_error(ArgumentError, /max_length: must be a positive Integer/)
    end
  end
end
