require "spec_helper"

# STATE slice audit probes (v1.33.0). Each example asserts the CORRECT
# behaviour; a failure demonstrates the bug.
describe "STATE audit" do
  before do
    ActiveRecord::Schema.define do
      create_table :st_tokens, force: true do |t|
        t.date :expires_on
        t.datetime :expires_at
        t.string :note
      end
      create_table :st_posts, force: true do |t|
        t.string :type
        t.string :title
        t.datetime :deleted_at
        t.datetime :published_at
        t.boolean :active
        t.string :status
        t.integer :lock_version, default: 0, null: false
        t.timestamps
      end
      create_table :st_comments, force: true do |t|
        t.integer :st_post_id
        t.string :body
        t.datetime :deleted_at
      end
      create_table :st_orders, primary_key: %i[shop_id id], force: true do |t|
        t.integer :shop_id
        t.integer :id
        t.datetime :deleted_at
      end
    end
  end

  after do
    %i[st_tokens st_posts st_comments st_orders].each { |t| ActiveRecord::Base.connection.drop_table(t, if_exists: true) }
  end

  describe "Expirable on a date column" do
    let(:model) do
      Class.new(TestModel) do
        self.table_name = "st_tokens"
        include ConcernsOnRails::Expirable
        expirable_by :expires_on

        attr_accessor :fired
        def after_expire
          (self.fired ||= []) << :after_expire
        end
      end
    end

    it "time_until_expiry answers a Duration for a future date (does not crash)" do
      token = model.create!(expires_on: Date.current + 3)
      expect { token.time_until_expiry }.not_to raise_error
    end

    it "expire! (now) fires the expire hooks whatever the process TZ (ENV['TZ'] behind Time.zone)" do
      old_tz = ENV.fetch("TZ", nil)
      ENV["TZ"] = "America/Los_Angeles"
      travel_to Time.utc(2026, 10, 29, 1, 0, 0) do
        token = model.create!
        expect(token.expire!).to be(true)
        expect(token.expired?).to be(true)
        expect(token.fired).to eq([:after_expire])
      end
    ensure
      ENV["TZ"] = old_tz
    end
  end

  describe "SoftDeletable with a composite primary key", min_rails: "7.1" do
    let(:model) do
      Class.new(TestModel) do
        self.table_name = "st_orders"
        self.primary_key = %i[shop_id id]
        include ConcernsOnRails::SoftDeletable
      end
    end

    it "really_delete! hard-deletes the row" do
      order = model.create!(id: [1, 1])
      model.create!(id: [1, 2])
      expect { order.really_delete! }.not_to raise_error
      expect(model.unscoped.count).to eq(1)
    end
  end

  describe "SoftDeletable composite primary key, other paths", min_rails: "7.1" do
    let(:model) do
      Class.new(TestModel) do
        self.table_name = "st_orders"
        self.primary_key = %i[shop_id id]
        include ConcernsOnRails::SoftDeletable
      end
    end

    it "soft_delete!/restore!/is_really_deleted? work" do
      order = model.create!(id: [1, 1])
      model.create!(id: [1, 2])
      expect(order.soft_delete!).to be(true)
      expect(model.only_deleted.count).to eq(1)
      expect(order.restore!).to be(true)
      expect(order.is_really_deleted?).to be(false)
    end

    it "relation destroy_all soft-deletes and only_deleted.destroy_all purges" do
      model.create!(id: [1, 1])
      model.create!(id: [1, 2])
      model.where(id: 1).destroy_all
      expect(model.only_deleted.count).to eq(1)
      model.only_deleted.destroy_all
      expect(model.unscoped.count).to eq(1)
    end
  end

  describe "batch verbs over a relation with a partial select (per-record path)" do
    it "publish_all works as its fast path does" do
      model = Class.new(TestModel) do
        self.table_name = "st_posts"
        include ConcernsOnRails::Publishable
        validates :title, length: { maximum: 50 }
      end
      model.create!(title: "a")
      expect { model.select(:id, :title).publish_all }.not_to raise_error
    end
  end

  describe "Anonymizable when the row is gone before the UPDATE" do
    before do
      ActiveRecord::Schema.define do
        create_table :st_users, force: true do |t|
          t.string :email
          t.datetime :anonymized_at
        end
      end
    end

    after { ActiveRecord::Base.connection.drop_table(:st_users, if_exists: true) }

    it "anonymize_all! does not count a row its UPDATE never reached" do
      model = Class.new(TestModel) do
        self.table_name = "st_users"
        include ConcernsOnRails::Anonymizable
        anonymizable :email, with: :email
        def before_anonymize
          self.class.unscoped.where(id: id).delete_all # deleted concurrently
        end
      end
      model.create!(email: "a@x.io")
      expect(model.anonymize_all!).to eq(0)
    end
  end

  describe "HookedWrite restores forced changes after a veto" do
    it "keeps title_will_change! pending after a vetoed publish!" do
      model = Class.new(TestModel) do
        self.table_name = "st_posts"
        include ConcernsOnRails::Publishable
        def after_publish
          raise ActiveRecord::Rollback
        end
      end
      post = model.create!(title: "a")
      post.title_will_change!
      expect(post.publish!).to be(false)
      expect(post.title_changed?).to be(true)
    end
  end

  describe "Expirable#expire_in! argument checking" do
    it "raises the concern's ArgumentError for nil, as for a String" do
      model = Class.new(TestModel) do
        self.table_name = "st_tokens"
        include ConcernsOnRails::Expirable
        expirable_by :expires_at
      end
      token = model.create!
      expect { token.expire_in!(nil) }.to raise_error(ArgumentError)
    end
  end

  describe "HookedWrite on a NEW record" do
    let(:model) do
      Class.new(TestModel) do
        self.table_name = "st_posts"
        include ConcernsOnRails::Publishable
        attr_accessor :veto
        def after_publish
          raise ActiveRecord::Rollback if veto
        end
      end
    end

    it "a vetoed publish! leaves it new; the retry inserts exactly one row" do
      post = model.new(title: "a", veto: true)
      expect(post.publish!).to be(false)
      expect(post).to be_new_record
      expect(post.id).to be_nil
      post.veto = false
      expect(post.publish!).to be(true)
      expect(model.count).to eq(1)
    end

    it "the same inside a caller transaction" do
      post = model.new(title: "a", veto: true)
      model.transaction do
        expect(post.publish!).to be(false)
        post.veto = false
        expect(post.publish!).to be(true)
      end
      expect(model.count).to eq(1)
      expect(post).to be_persisted
    end
  end

  describe "HookedWrite on a NEW record without lock_version, inside a caller transaction" do
    before do
      ActiveRecord::Schema.define do
        create_table :st_articles, force: true do |t|
          t.string :title
          t.datetime :published_at
        end
      end
    end

    after { ActiveRecord::Base.connection.drop_table(:st_articles, if_exists: true) }

    it "is still a new record after the veto, so a later save! INSERTs it" do
      model = Class.new(TestModel) do
        self.table_name = "st_articles"
        include ConcernsOnRails::Publishable
        def after_publish
          raise ActiveRecord::Rollback
        end
      end
      post = model.new(title: "a")
      model.transaction do
        expect(post.publish!).to be(false)
        expect(post).to be_new_record
        expect(post.save!).to be(true)
      end
      expect(model.count).to eq(1)
    end

    it "save! after the veto either INSERTs or fails, never reports a phantom success" do
      model = Class.new(TestModel) do
        self.table_name = "st_articles"
        include ConcernsOnRails::Publishable
        def after_publish
          raise ActiveRecord::Rollback
        end
      end
      post = model.new(title: "a")
      saved = nil
      model.transaction do
        post.publish!
        saved = post.save
      end
      expect([saved, model.count]).not_to eq([true, 0])
    end
  end

  describe "SoftDeletable verbs read the in-memory (unsaved) stamp" do
    let(:model) do
      Class.new(TestModel) do
        self.table_name = "st_comments"
        include ConcernsOnRails::SoftDeletable
      end
    end

    it "soft_delete! on a record whose stamp was assigned but not saved really soft-deletes it" do
      c = model.create!(body: "a")
      c.deleted_at = Time.current
      expect(c.soft_delete!).to be(true)
      expect(model.unscoped.find(c.id).deleted_at).not_to be_nil
    end

    it "restore! on a record whose stamp was cleared but not saved really restores it" do
      c = model.create!(body: "a")
      c.soft_delete!
      c.deleted_at = nil
      expect(c.restore!).to be(true)
      expect(model.unscoped.find(c.id).deleted_at).to be_nil
    end
  end

  describe "Activatable#toggle_active! with unsaved changes" do
    it "keeps the pending changes and flips the stored flag" do
      model = Class.new(TestModel) do
        self.table_name = "st_posts"
        include ConcernsOnRails::Activatable
        activatable_by
      end
      rec = model.create!(active: true, title: "a")
      rec.title = "b"
      expect(rec.toggle_active!).to be(true)
      rec.reload
      expect([rec.active, rec.title]).to eq([false, "b"])
    end
  end

  describe "Stateable with an event named :transition" do
    it "fires transition! without an ArgumentError from the generic hook" do
      model = Class.new(TestModel) do
        self.table_name = "st_posts"
        include ConcernsOnRails::Stateable
        stateable_by :status, states: %i[draft moved], default: :draft,
                              transitions: { transition: { from: :draft, to: :moved } }
      end
      post = model.create!
      expect { post.transition! }.not_to raise_error
      expect(post.reload.status).to eq("moved")
    end
  end

  describe "Publishable#unpublish! on a draft" do
    it "is a no-op (no hooks), like publish!/activate!/deactivate!/restore!" do
      model = Class.new(TestModel) do
        self.table_name = "st_posts"
        include ConcernsOnRails::Publishable
        attr_accessor :fired
        def after_unpublish
          (self.fired ||= []) << :after_unpublish
        end
      end
      post = model.create!
      post.unpublish!
      expect(post.fired).to be_nil
    end
  end

  describe "SoftDeletable relation destroy_all with a partial select" do
    it "soft-deletes like Relation#destroy_all destroys" do
      model = Class.new(TestModel) do
        self.table_name = "st_comments"
        include ConcernsOnRails::SoftDeletable
      end
      model.create!(body: "a")
      expect { model.select(:id).where(body: "a").destroy_all }.not_to raise_error
      expect(model.only_deleted.count).to eq(1)
    end
  end

  describe "HookedWrite + optimistic locking" do
    it "a vetoed publish! leaves lock_version saveable" do
      model = Class.new(TestModel) do
        self.table_name = "st_posts"
        include ConcernsOnRails::Publishable
        def after_publish
          raise ActiveRecord::Rollback
        end
      end
      post = model.create!(title: "a")
      expect(post.publish!).to be(false)
      post.title = "b"
      expect { post.save! }.not_to raise_error
      expect(post.reload.title).to eq("b")
    end

    it "a vetoed publish! inside a caller transaction leaves lock_version saveable" do
      model = Class.new(TestModel) do
        self.table_name = "st_posts"
        include ConcernsOnRails::Publishable
        def after_publish
          raise ActiveRecord::Rollback
        end
      end
      post = model.create!(title: "a")
      model.transaction do
        expect(post.publish!).to be(false)
        post.title = "b"
        post.save!
      end
      expect(post.reload.title).to eq("b")
      expect(post.published_at).to be_nil
    end
  end

  describe "Stateable transition_all with a failing validation" do
    it "raises RecordNotSaved (the batch contract) and rolls back" do
      model = Class.new(TestModel) do
        self.table_name = "st_posts"
        include ConcernsOnRails::Stateable
        stateable_by :status, states: %i[draft done], default: :draft,
                              transitions: { finish: { from: :draft, to: :done } }
        validates :title, presence: true, if: -> { status == "done" }
      end
      model.create!(title: "x")
      model.create!(title: nil)
      expect { model.transition_all(:finish) }.to raise_error(ActiveRecord::RecordNotSaved)
    end
  end

  describe "association destroy_all on a model whose soft-deleted rows stay visible" do
    it "default_scope: false — the loaded association still lists the soft-deleted rows" do
      comment = Class.new(TestModel) do
        self.table_name = "st_comments"
        include ConcernsOnRails::SoftDeletable
        soft_deletable_by :deleted_at, default_scope: false
      end
      stub_const("StComment", comment)
      post_model = Class.new(TestModel) do
        self.table_name = "st_posts"
        has_many :st_comments, class_name: "StComment", foreign_key: :st_post_id
      end
      stub_const("StPost", post_model)
      post = StPost.create!
      post.st_comments.create!(body: "x")
      post.st_comments.create!(body: "y")

      post.st_comments.destroy_all

      expect(StComment.where(st_post_id: post.id).count).to eq(2)
      expect(post.st_comments.to_a.size).to eq(StPost.find(post.id).st_comments.to_a.size)
    end

    it "a with_deleted association — live rows soft-deleted stay in it" do
      comment = Class.new(TestModel) do
        self.table_name = "st_comments"
        include ConcernsOnRails::SoftDeletable
      end
      stub_const("StComment", comment)
      post_model = Class.new(TestModel) do
        self.table_name = "st_posts"
        has_many :all_comments, -> { with_deleted }, class_name: "StComment", foreign_key: :st_post_id
      end
      stub_const("StPost", post_model)
      post = StPost.create!
      post.all_comments.create!(body: "x")

      post.all_comments.destroy_all

      expect(StComment.with_deleted.count).to eq(1)
      expect(post.all_comments.to_a.size).to eq(StPost.find(post.id).all_comments.to_a.size)
    end
  end
end
