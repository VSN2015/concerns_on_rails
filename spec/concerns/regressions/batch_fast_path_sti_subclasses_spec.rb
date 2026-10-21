require "spec_helper"

# Audit 2026-10-10 (STATE-8): the batch verbs decided on their single-UPDATE
# fast path by inspecting only the RECEIVING class. On an STI table its
# relation also holds every subclass's rows, so `Article.publish_all`
# published Press rows without Press's overridden after_publish and without
# Press's validations (the same for soft_delete_all, expire_all,
# activate_all/deactivate_all and Lockable's unlock_expired), and applied the
# receiver's configuration (`cascade:`, `touch:`, `timestamps:`, the column,
# the token column) to rows whose class re-declared the macro.
#
# The fast path is only an optimisation and the per-record path is always
# correct, so the rule is simply: a batch verb never takes the single UPDATE
# on an STI table (a present `inheritance_column` that is a real column).
describe "batch fast paths and STI subclasses" do
  after do
    %i[bfs_articles bfs_memos bfs_users bfs_things bfs_tokens].each { |table| ActiveRecord::Base.connection.drop_table(table, if_exists: true) }
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

    it "streams on an STI table even when no class in the hierarchy overrides anything" do
      stub_const("BfsNote", Class.new(BfsArticle))
      BfsArticle.create!
      BfsNote.create!

      expect(update_statements { expect(BfsArticle.publish_all).to eq(2) }.size).to eq(2)
      expect(update_statements { expect(BfsArticle.soft_delete_all).to eq(2) }.size).to eq(2)
    end

    # The conservative rule: the table is STI, whether or not a subclass exists
    # (or is loaded yet), so the answer never depends on config.eager_load.
    it "streams on an STI table that has no subclasses at all" do
      2.times { BfsArticle.create! }

      expect(BfsArticle.descendants).to be_empty
      expect(update_statements { expect(BfsArticle.publish_all).to eq(2) }.size).to eq(2)
    end

    it "runs the hook of a subclass that is only autoloaded when its rows are read" do
      Tempfile.create(["bfs_lazy_press", ".rb"]) do |file|
        file.write(<<~RUBY)
          class BfsLazyPress < BfsArticle
            cattr_accessor :published_hooks, default: 0
            def after_publish = (self.class.published_hooks += 1)
          end
        RUBY
        file.flush
        Object.autoload(:BfsLazyPress, file.path)
        begin
          expect(Object.autoload?(:BfsLazyPress)).to be_present # not loaded yet
          BfsArticle.create!.update_column(:type, "BfsLazyPress")
          BfsArticle.create!

          expect(BfsArticle.publish_all).to eq(2)
          expect(BfsLazyPress.published_hooks).to eq(1)
        ensure
          Object.send(:remove_const, :BfsLazyPress) if Object.const_defined?(:BfsLazyPress, false)
        end
      end
    end

    it "lets the per-record path raise for a row whose stored type names no class, as a read does" do
      BfsArticle.create!.update_column(:type, "NoSuchBfsClass")

      expect { BfsArticle.publish_all }.to raise_error(ActiveRecord::SubclassNotFound)
    end

    it "writes a subclass's own publish column, not the receiver's" do
      ActiveRecord::Base.connection.add_column(:bfs_articles, :live_at, :datetime)
      BfsArticle.reset_column_information
      stub_const("BfsPress", Class.new(BfsArticle) { publishable_by :live_at })
      BfsPress.create!

      expect(BfsArticle.publish_all).to eq(1)
      expect(BfsPress.first.live_at).to be_present
    end
  end

  describe "a subclass that re-declares the macro with other options" do
    describe "SoftDeletable" do
      before do
        ActiveRecord::Schema.define do
          create_table :bfs_articles, force: true do |t|
            t.string :type
            t.datetime :deleted_at
            t.timestamps
          end
          create_table :bfs_memos, force: true do |t|
            t.integer :bfs_article_id
            t.datetime :deleted_at
          end
        end
        stub_const("BfsMemo", Class.new(TestModel) do
          self.table_name = "bfs_memos"
          include ConcernsOnRails::SoftDeletable
        end)
        stub_const("BfsArticle", Class.new(TestModel) do
          self.table_name = "bfs_articles"
          include ConcernsOnRails::SoftDeletable

          has_many :bfs_memos
          soft_deletable_by :deleted_at, touch: false
        end)
      end

      it "cascades for a subclass that declares cascade: (the parent's does not)" do
        stub_const("BfsPress", Class.new(BfsArticle) { soft_deletable_by :deleted_at, touch: false, cascade: [:bfs_memos] })
        press = BfsPress.create!
        memo = BfsMemo.create!(bfs_article_id: press.id)

        expect(BfsArticle.soft_delete_all).to eq(1)
        expect(BfsMemo.unscoped.find(memo.id).deleted_at).to be_present

        expect(BfsArticle.restore_all).to eq(1)
        expect(BfsMemo.unscoped.find(memo.id).deleted_at).to be_nil
      end

      it "bumps updated_at for a subclass that declares touch: true" do
        stub_const("BfsPress", Class.new(BfsArticle) { soft_deletable_by :deleted_at, touch: true })
        press = BfsPress.create!
        press.update_column(:updated_at, 1.day.ago)

        expect(BfsArticle.soft_delete_all).to eq(1)
        expect(BfsPress.unscoped.find(press.id).updated_at).to be > 1.hour.ago
      end
    end

    describe "Activatable" do
      before do
        ActiveRecord::Schema.define do
          create_table :bfs_things, force: true do |t|
            t.string :type
            t.boolean :active, default: false
            t.datetime :activated_at
            t.datetime :deactivated_at
            t.timestamps
          end
        end
        stub_const("BfsThing", Class.new(TestModel) do
          self.table_name = "bfs_things"
          include ConcernsOnRails::Activatable

          activatable_by
        end)
      end

      it "stamps activated_at/deactivated_at for a subclass that declares timestamps: true" do
        stub_const("BfsGadget", Class.new(BfsThing) { activatable_by timestamps: true })
        gadget = BfsGadget.create!

        expect(BfsThing.activate_all).to eq(1)
        expect(BfsGadget.find(gadget.id).activated_at).to be_present

        expect(BfsThing.deactivate_all).to eq(1)
        expect(BfsGadget.find(gadget.id).deactivated_at).to be_present
      end
    end

    describe "Lockable" do
      before do
        ActiveRecord::Schema.define do
          create_table :bfs_users, force: true do |t|
            t.string :type
            t.integer :failed_attempts, default: 0
            t.datetime :locked_at
            t.string :unlock_token
          end
        end
        stub_const("BfsUser", Class.new(TestModel) do
          self.table_name = "bfs_users"
          include ConcernsOnRails::Lockable

          lockable_by max_attempts: 3, unlock_in: 10.minutes
        end)
      end

      it "clears the unlock token of a subclass that declares unlock_token:" do
        stub_const("BfsAdmin", Class.new(BfsUser) { lockable_by max_attempts: 3, unlock_in: 10.minutes, unlock_token: :unlock_token })
        admin = BfsAdmin.create!(locked_at: 1.hour.ago, failed_attempts: 3, unlock_token: "tok")

        expect(BfsUser.unlock_expired).to eq(1)
        expect(BfsAdmin.find(admin.id).unlock_token).to be_nil
      end
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

  describe "a table that is not STI" do
    def expirable_model(table_setup: nil)
      Class.new(TestModel) do
        self.table_name = "bfs_tokens"
        include ConcernsOnRails::Expirable

        table_setup&.call(self)
        expirable_by
      end
    end

    it "still takes the single UPDATE without a type column, subclass or not" do
      ActiveRecord::Schema.define do
        create_table :bfs_tokens, force: true do |t|
          t.datetime :expires_at
        end
      end
      parent = expirable_model
      Class.new(parent) { def after_expire = nil } # the parent's rows are never instances of it
      2.times { parent.create! }

      expect(update_statements { expect(parent.expire_all).to eq(2) }.size).to eq(1)
    end

    it "still takes the single UPDATE when STI is switched off on a table with a type column" do
      ActiveRecord::Schema.define do
        create_table :bfs_tokens, force: true do |t|
          t.string :type
          t.datetime :expires_at
        end
      end
      model = expirable_model(table_setup: ->(klass) { klass.inheritance_column = nil })
      2.times { model.create! }

      expect(update_statements { expect(model.expire_all).to eq(2) }.size).to eq(1)
    end

    it "still takes the single UPDATE when the inheritance column names no real column" do
      ActiveRecord::Schema.define do
        create_table :bfs_tokens, force: true do |t|
          t.datetime :expires_at
        end
      end
      model = expirable_model(table_setup: ->(klass) { klass.inheritance_column = "kind" })
      2.times { model.create! }

      expect(update_statements { expect(model.expire_all).to eq(2) }.size).to eq(1)
    end

    it "streams on an STI table that has a type column" do
      ActiveRecord::Schema.define do
        create_table :bfs_tokens, force: true do |t|
          t.string :type
          t.datetime :expires_at
        end
      end
      model = expirable_model
      2.times { model.create! }

      expect(update_statements { expect(model.expire_all).to eq(2) }.size).to eq(2)
    end
  end
end
