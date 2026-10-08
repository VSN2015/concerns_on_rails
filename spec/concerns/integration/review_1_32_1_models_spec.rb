require "spec_helper"

# Regressions caught by the adversarial review of the 1.32.1 audit fixes
# (model side), kept as permanent specs.
describe "1.32.1 review regressions: models" do
  REVIEW_1321_KEY = "concerns-on-rails-review-models-key".freeze

  before do
    ConcernsOnRails.encryption.key = REVIEW_1321_KEY
    ConcernsOnRails.encryption.on_missing_key = :raise
    ConcernsOnRails.encryption.raise_on_decrypt_error = true

    ActiveRecord::Schema.define do
      create_table :rm_articles, force: true do |t|
        t.string :title
        t.text :body
        t.string :tags
      end

      create_table :rm_places, force: true do |t|
        t.string :street
        t.string :city
        t.string :region
        t.string :zip
        t.string :country_code
      end

      create_table :rm_posts, force: true do |t|
        t.string :title
        t.datetime :deleted_at
      end

      create_table :rm_comments, force: true do |t|
        t.integer :rm_post_id
        t.boolean :approved, default: false
        t.datetime :deleted_at
      end

      create_table :rm_pages, force: true do |t|
        t.string :title
        t.string :slug
        t.integer :account_id
      end

      create_table :rm_parents, force: true do |t|
        t.integer :replies_count, default: 0, null: false
      end

      create_table :rm_replies, force: true do |t|
        t.string :type
        t.integer :rm_parent_id
        t.boolean :featured, default: false
      end

      create_table :rm_events, force: true do |t|
        t.text :starts_at
        t.string :starts_at_bidx
      end

      create_table :rm_people, force: true do |t|
        t.text :email
        t.string :email_bidx
        t.string :name
      end
    end
  end

  after(:each) do
    ConcernsOnRails.encryption.key = nil
    ConcernsOnRails.encryption.key_id = 0
    ConcernsOnRails.encryption.previous_keys = {}

    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  # --- Sanitizable before_save backstop ---------------------------------------

  it "RM-01: a write-mode Proc sanitizer runs ONCE in a validated save even when a later before_validation rewrites the field" do
    klass = Class.new(TestModel) do
      self.table_name = "rm_articles"
      include ConcernsOnRails::Models::Sanitizable
      include ConcernsOnRails::Models::Normalizable

      sanitizable :body, with: ->(v) { v.is_a?(String) ? ERB::Util.html_escape(v).to_str : v }, on: :write
      normalizable :body, with: :squish
    end

    record = klass.create!(body: "  Tom & Jerry  ")
    expect(record.reload.body).to eq("Tom &amp; Jerry")
  end

  # --- Addressable before_save backstop ---------------------------------------

  it "RM-02: a validated save keeps a later before_validation's rewrite of an address column (backstop must not undo it)" do
    klass = Class.new(TestModel) do
      self.table_name = "rm_places"
      include ConcernsOnRails::Models::Addressable

      addressable_by line1: :street, city: :city, state: :region, postal_code: :zip, country: :country_code,
                     required: []
      # The app's own rule, declared AFTER the concern: store the postcode compact.
      before_validation { self.zip = zip.delete(" ") if zip }
    end

    place = klass.new(street: "24 Sussex Dr", city: "Ottawa", zip: "k1a 0b1", country_code: "CA")
    place.valid?
    validated = place.zip
    place.save!
    expect(place.reload.zip).to eq(validated)
  end

  # --- SoftDeletable DefaultScopePredicate peel -------------------------------

  it "RM-03: really_destroy_all peels only its OWN default-scope predicate, not a merged soft-deletable model's" do
    stub_const("RmComment", Class.new(TestModel) do
      self.table_name = "rm_comments"
      include ConcernsOnRails::Models::SoftDeletable
    end)
    stub_const("RmPost", Class.new(TestModel) do
      self.table_name = "rm_posts"
      include ConcernsOnRails::Models::SoftDeletable
    end)

    live = RmPost.create!(title: "live-comment")
    trashed = RmPost.create!(title: "trashed-comment")
    RmComment.create!(rm_post_id: live.id, approved: true)
    RmComment.create!(rm_post_id: trashed.id, approved: true).soft_delete!

    relation = RmPost.joins("INNER JOIN rm_comments ON rm_comments.rm_post_id = rm_posts.id")
                     .merge(RmComment.where(approved: true))
    expect(relation.pluck(:id)).to eq([live.id])

    relation.really_destroy_all
    expect(RmPost.with_deleted.pluck(:id)).to eq([trashed.id])
  end

  # --- Encryptable finders vs the gem's own Normalizable -----------------------

  it "RM-04: find_by_<field> applies the gem's own Normalizable rule, as it now applies Rails' normalizes" do
    klass = Class.new(TestModel) do
      self.table_name = "rm_people"
      include ConcernsOnRails::Models::Normalizable
      include ConcernsOnRails::Models::Encryptable

      normalizable :email, with: :email
      encryptable :email, blind_index: true
    end

    person = klass.create!(email: "alice@example.com")
    expect(klass.find_by_email("  Alice@Example.COM ")).to eq(person)
  end

  # --- Sluggable scope change ---------------------------------------------------

  it "RM-05: moving a record to another scope keeps its (explicitly assigned) slug when the new scope has it free" do
    klass = Class.new(TestModel) do
      self.table_name = "rm_pages"
      include ConcernsOnRails::Models::Sluggable

      sluggable_by :title, scope: :account_id
    end

    page = klass.create!(title: "Hello World", account_id: 1)
    page.update!(slug: "launch-2026")
    page.update!(account_id: 2) # nothing in account 2 holds "launch-2026"
    expect(page.reload.slug).to eq("launch-2026")
  end

  # --- CounterCacheable STI type change ------------------------------------

  it "RM-06: a becomes! from a subclass with a subclass-only condition method to its base saves (and settles the counter)" do
    stub_const("RmParent", Class.new(TestModel) { self.table_name = "rm_parents" })
    stub_const("RmReply", Class.new(TestModel) do
      self.table_name = "rm_replies"
      include ConcernsOnRails::Models::CounterCacheable

      belongs_to :rm_parent, optional: true
      counter_cacheable_by :rm_parent, count: :replies_count
    end)
    stub_const("RmFeaturedReply", Class.new(RmReply) do
      def spotlight?
        featured?
      end
      counter_cacheable_by :rm_parent, count: :replies_count, if: -> { spotlight? }
    end)

    parent = RmParent.create!
    reply = RmFeaturedReply.create!(rm_parent: parent, featured: true)
    expect(parent.reload.replies_count).to eq(1)

    expect { reply.becomes!(RmReply).save! }.not_to raise_error
    expect(parent.reload.replies_count).to eq(1)
  end

  # --- Encryptable finders through Rails' normalizes on a :datetime -----------

  it "RM-07: find_by_<field> on a normalized zone-aware :datetime finds the record it fingerprinted", min_rails: "7.1" do
    Time.use_zone("Asia/Tokyo") do
      klass = Class.new(TestModel) do
        self.table_name = "rm_events"
        self.time_zone_aware_attributes = true
        include ConcernsOnRails::Models::Encryptable

        encryptable :starts_at, type: :datetime, blind_index: true
        normalizes :starts_at, with: ->(t) { t.change(sec: 0) }
      end

      event = klass.create!(starts_at: "2026-03-01 10:00:42")
      expect(klass.find_by_starts_at("2026-03-01 10:00:42")).to eq(event)
      expect(klass.where_starts_at(Time.zone.parse("2026-03-01 10:00:13")).to_a).to eq([event])
    end
  end

  # --- SoftDeletable DefaultScopePredicate: everyday relation algebra --------

  it "RM-08: the tagged default-scope node still renders, ORs, merges, unscopes and presets new records" do
    stub_const("RmPost", Class.new(TestModel) do
      self.table_name = "rm_posts"
      include ConcernsOnRails::Models::SoftDeletable
    end)
    a = RmPost.create!(title: "a")
    b = RmPost.create!(title: "b")
    gone = RmPost.create!(title: "a")
    gone.soft_delete!

    expect(RmPost.where(title: "a").or(RmPost.where(title: "b")).order(:id).pluck(:id)).to eq([a.id, b.id])
    expect(RmPost.where(title: "a").merge(RmPost.where(title: "a")).pluck(:id)).to eq([a.id])
    expect(RmPost.unscope(where: :deleted_at).where(title: "a").count).to eq(2)
    expect(RmPost.with_deleted.where(title: "a").count).to eq(2)
    expect(RmPost.where(title: "a").new.deleted_at).to be_nil
    expect(RmPost.where(title: "a").where_values_hash).to include("deleted_at" => nil, "title" => "a")
    expect(RmPost.find(a.id)).to eq(a)
    expect { RmPost.find(gone.id) }.to raise_error(ActiveRecord::RecordNotFound)
    # a restore_all scoped by the caller's own `deleted_at IS NULL` restores nothing
    expect(RmPost.without_deleted.restore_all).to eq(0)
    expect(RmPost.only_deleted.restore_all).to eq(1)
  end

  it "RM-09: restore_all over a relation merged with another soft-deletable model's keeps that model's predicate" do
    stub_const("RmComment", Class.new(TestModel) do
      self.table_name = "rm_comments"
      include ConcernsOnRails::Models::SoftDeletable
    end)
    stub_const("RmPost", Class.new(TestModel) do
      self.table_name = "rm_posts"
      include ConcernsOnRails::Models::SoftDeletable
    end)

    p1 = RmPost.create!(title: "p1")
    p2 = RmPost.create!(title: "p2")
    RmComment.create!(rm_post_id: p1.id, approved: true)
    RmComment.create!(rm_post_id: p2.id, approved: true).soft_delete!
    [p1, p2].each(&:soft_delete!)

    relation = RmPost.joins("INNER JOIN rm_comments ON rm_comments.rm_post_id = rm_posts.id")
                     .merge(RmComment.where(approved: true))
    expect(relation.restore_all).to eq(1)
    expect(RmPost.pluck(:id)).to eq([p1.id])
  end
end
