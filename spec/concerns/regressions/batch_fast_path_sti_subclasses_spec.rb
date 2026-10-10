require "spec_helper"

# Audit 2026-10-10 (STATE-8): the batch verbs decided on their single-UPDATE
# fast path by inspecting only the RECEIVING class. On an STI table its
# relation also holds every subclass's rows, so `Article.publish_all`
# published Press rows without Press's overridden after_publish and without
# Press's validations (the same for soft_delete_all, expire_all,
# activate_all/deactivate_all and Lockable's unlock_expired). The decision
# now covers the loaded subclasses too, and refuses the fast path on an STI
# table while subclasses may still be unloaded (no eager loading).
describe "batch fast paths and STI subclasses" do
  after do
    %i[bfs_articles bfs_users bfs_tokens].each { |table| ActiveRecord::Base.connection.drop_table(table, if_exists: true) }
  end

  def update_statements(&)
    sql = []
    callback = ->(*, payload) { sql << payload[:sql] if payload[:sql] =~ /\AUPDATE/i }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &)
    sql
  end

  describe "Publishable / SoftDeletable" do
    before do
      ActiveRecord::Schema.define do
        create_table :bfs_articles, force: true do |t|
          t.string :type
          t.string :title
          t.datetime :published_at
          t.datetime :deleted_at
          t.timestamps
        end
      end
      stub_const("BfsArticle", Class.new(TestModel) do
        self.table_name = "bfs_articles"
        include ConcernsOnRails::Publishable
        include ConcernsOnRails::SoftDeletable

        publishable_by :published_at
        soft_deletable_by :deleted_at, touch: false
      end)
    end

    it "runs a subclass's overridden after_publish for its rows" do
      stub_const("BfsPress", Class.new(BfsArticle) do
        cattr_accessor :published_hooks, default: 0
        def after_publish = (self.class.published_hooks += 1)
      end)
      BfsArticle.create!
      BfsPress.create!

      expect(BfsArticle.publish_all).to eq(2)
      expect(BfsPress.published_hooks).to eq(1)
    end

    it "honours a subclass's validation (RecordNotSaved, batch rolled back)" do
      stub_const("BfsPress", Class.new(BfsArticle) { validates :title, presence: true })
      BfsArticle.create!
      press = BfsPress.create!(title: "p")
      press.update_column(:title, nil) # now invalid under BfsPress's validator

      expect { BfsArticle.publish_all }.to raise_error(ActiveRecord::RecordNotSaved)
      expect(BfsArticle.where.not(published_at: nil).count).to eq(0)
    end

    it "runs a subclass's overridden after_soft_delete for its rows" do
      stub_const("BfsPress", Class.new(BfsArticle) do
        cattr_accessor :deleted_hooks, default: 0
        def after_soft_delete = (self.class.deleted_hooks += 1)
      end)
      BfsArticle.create!
      BfsPress.create!

      expect(BfsArticle.soft_delete_all).to eq(2)
      expect(BfsPress.deleted_hooks).to eq(1)
    end

    it "keeps the single UPDATE when no class in the hierarchy overrides anything" do
      stub_const("BfsNote", Class.new(BfsArticle))
      BfsArticle.create!
      BfsNote.create!

      expect(update_statements { expect(BfsArticle.publish_all).to eq(2) }.size).to eq(1)
      expect(update_statements { expect(BfsArticle.soft_delete_all).to eq(2) }.size).to eq(1)
    end

    it "refuses the single UPDATE on an STI table while subclasses may be unloaded" do
      allow(ConcernsOnRails::Support::BatchOps).to receive(:lazily_loaded?).and_return(true)
      BfsArticle.create!
      BfsArticle.create!

      expect(update_statements { expect(BfsArticle.publish_all).to eq(2) }.size).to eq(2)
    end
  end

  describe "Lockable#unlock_expired" do
    before do
      ActiveRecord::Schema.define do
        create_table :bfs_users, force: true do |t|
          t.string :type
          t.integer :failed_attempts, default: 0
          t.datetime :locked_at
        end
      end
    end

    it "fires a subclass's after_unlock for its rows" do
      stub_const("BfsUser", Class.new(TestModel) do
        self.table_name = "bfs_users"
        include ConcernsOnRails::Lockable

        lockable_by max_attempts: 3, unlock_in: 10.minutes
      end)
      stub_const("BfsAdmin", Class.new(BfsUser) do
        cattr_accessor :unlocks, default: 0
        def after_unlock = (self.class.unlocks += 1)
      end)
      BfsAdmin.create!(locked_at: 1.hour.ago, failed_attempts: 3)

      expect(BfsUser.unlock_expired).to eq(1)
      expect(BfsAdmin.unlocks).to eq(1)
    end
  end

  describe "a subclass of a non-STI model" do
    before do
      ActiveRecord::Schema.define do
        create_table :bfs_tokens, force: true do |t|
          t.datetime :expires_at
        end
      end
    end

    it "does not move its parent off the single UPDATE (the parent's rows are never instances of it)" do
      parent = Class.new(TestModel) do
        self.table_name = "bfs_tokens"
        include ConcernsOnRails::Expirable

        expirable_by
      end
      Class.new(parent) { def after_expire = nil }
      2.times { parent.create! }

      expect(update_statements { expect(parent.expire_all).to eq(2) }.size).to eq(1)
    end
  end
end
