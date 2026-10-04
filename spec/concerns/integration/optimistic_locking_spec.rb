require "spec_helper"

# Optimistic locking (`lock_version`) across the concerns that write with raw
# SQL — update_all / Relation#update_counters bump the locking column in the
# ROW only, so without a mirror the gem's own instance goes stale and the next
# ordinary save raises StaleObjectError. Rails' own Locking::Optimistic#increment!
# (identical on 6.0–8.1) mirrors the bump in memory; these specs hold the gem
# to the same contract. Every scenario is also run on a table WITHOUT a locking
# column, where nothing may change.
describe "optimistic locking across raw writes" do
  def drop_ol_tables
    connection = ActiveRecord::Base.connection
    connection.tables.grep(/\Aol_/).each { |table| connection.drop_table(table) }
  end

  # Each scenario runs against the same table name with AND without a
  # lock_version column. SQLite's prepared statements are pooled per SQL text
  # and the sqlite3 driver memoizes a statement's column list, so a find_by
  # repeated against the recreated (narrower) table would read the previous
  # table's columns — a phantom `lock_version => nil` attribute.
  before { ActiveRecord::Base.connection.clear_cache! }
  after { drop_ol_tables }

  def db_value(klass, id, column)
    klass.unscoped.where(klass.primary_key => id).pick(column)
  end

  # ---------------------------------------------------------------------------
  # Lockable (RA-01)
  # ---------------------------------------------------------------------------
  describe "Lockable" do
    def create_users_table(lock_version:)
      ActiveRecord::Schema.define do
        create_table :ol_users, force: true do |t|
          t.string :email
          t.integer :failed_attempts, default: 0, null: false
          t.datetime :locked_at
          t.string :unlock_token
          t.integer :lock_version, default: 0, null: false if lock_version
        end
      end
    end

    def lockable_model(max_attempts: 3, **options, &body)
      Class.new(TestModel) do
        self.table_name = "ol_users"
        include ConcernsOnRails::Lockable

        lockable_by(max_attempts: max_attempts, **options)
        class_eval(&body) if body
      end
    end

    context "with a lock_version column" do
      before { create_users_table(lock_version: true) }

      it "register_failed_attempt! mirrors the row's lock_version bump, so the instance saves" do
        klass = lockable_model
        user = klass.create!(email: "a@example.com")

        user.register_failed_attempt!

        expect(user.lock_version).to eq(db_value(klass, user.id, :lock_version))
        expect(user).not_to be_changed
        expect { user.update!(email: "b@example.com") }.not_to raise_error
        expect(klass.find(user.id).email).to eq("b@example.com")
      end

      it "register_failed_attempt! crossing the threshold (increment + lock claim) stays in sync" do
        klass = lockable_model(max_attempts: 2)
        user = klass.create!(email: "a@example.com")

        2.times { user.register_failed_attempt! }

        expect(user.access_locked?).to be(true)
        expect(user.lock_version).to eq(db_value(klass, user.id, :lock_version))
        expect { user.update!(email: "b@example.com") }.not_to raise_error
      end

      it "lock_access! mirrors the claim UPDATE's bump" do
        klass = lockable_model
        user = klass.create!(email: "a@example.com")

        expect(user.lock_access!).to be(true)

        expect(user.lock_version).to eq(db_value(klass, user.id, :lock_version))
        expect(user).not_to be_changed
        expect { user.update!(email: "b@example.com") }.not_to raise_error
        expect(klass.find(user.id).locked_at).to be_present
      end

      it "clearing a lapsed lock on a failed attempt mirrors both raw writes" do
        klass = lockable_model(unlock_in: 15.minutes)
        user = klass.create!(email: "a@example.com")
        user.update_columns(locked_at: 1.hour.ago, failed_attempts: 3)

        expect(user.register_failed_attempt!).to eq(1)

        expect(user.lock_version).to eq(db_value(klass, user.id, :lock_version))
        expect { user.update!(email: "b@example.com") }.not_to raise_error
      end

      it "unlock_by_token hands back an unlocked record that saves" do
        klass = lockable_model(unlock_in: 15.minutes, unlock_token: :unlock_token)
        user = klass.create!(email: "a@example.com")
        user.lock_access!

        unlocked = klass.unlock_by_token(user.unlock_token)

        expect(unlocked).to be_present
        # The claim bumped the row; on Rails 7.0+ update_columns is constrained
        # on lock_version, so a stale instance's unlock matched no row at all.
        expect(db_value(klass, user.id, :locked_at)).to be_nil
        expect(db_value(klass, user.id, :unlock_token)).to be_nil
        expect(unlocked.lock_version).to eq(db_value(klass, user.id, :lock_version))
        expect { unlocked.update!(email: "b@example.com") }.not_to raise_error
      end

      it "a vetoed unlock_by_token puts the in-memory lock_version back with the token" do
        klass = lockable_model(unlock_token: :unlock_token) do
          def before_unlock = raise(ActiveRecord::Rollback)
        end
        user = klass.create!(email: "a@example.com")
        user.lock_access!
        token = user.unlock_token
        record = klass.find(user.id)
        allow(klass).to receive(:find_by).and_return(record)

        expect(klass.unlock_by_token(token)).to be_nil

        expect(db_value(klass, user.id, :unlock_token)).to eq(token)
        expect(record.lock_version).to eq(db_value(klass, user.id, :lock_version))
        expect(record.unlock_token).to eq(token)
        expect { record.update!(email: "b@example.com") }.not_to raise_error
      end

      it "a raising after_lock restores the in-memory lock_version with the rolled-back claim" do
        klass = lockable_model { def after_lock = raise("mailer down") }
        user = klass.create!(email: "a@example.com")

        expect { user.lock_access! }.to raise_error("mailer down")

        expect(db_value(klass, user.id, :locked_at)).to be_nil
        expect(user.lock_version).to eq(db_value(klass, user.id, :lock_version))
        expect { user.update!(email: "b@example.com") }.not_to raise_error
      end

      it "mirrors the bump (+1, as increment! does) rather than adopting the row: a stale instance stays stale" do
        klass = lockable_model
        user = klass.create!(email: "a@example.com")
        klass.find(user.id).update!(email: "edited elsewhere")

        user.register_failed_attempt!

        expect { user.update!(email: "b@example.com") }.to raise_error(ActiveRecord::StaleObjectError)
        expect(klass.find(user.id).email).to eq("edited elsewhere")
      end
    end

    context "without a lock_version column" do
      before { create_users_table(lock_version: false) }

      it "runs every raw-write path exactly as before" do
        klass = lockable_model(max_attempts: 2, unlock_in: 15.minutes, unlock_token: :unlock_token)
        user = klass.create!(email: "a@example.com")

        2.times { user.register_failed_attempt! }
        expect(user.access_locked?).to be(true)
        unlocked = klass.unlock_by_token(user.unlock_token)

        expect(unlocked).to be_present
        expect(unlocked).not_to be_changed
        expect(unlocked.attributes).not_to have_key("lock_version")
        expect(db_value(klass, user.id, :locked_at)).to be_nil
        expect { unlocked.update!(email: "b@example.com") }.not_to raise_error
      end
    end
  end

  # ---------------------------------------------------------------------------
  # CounterCacheable (RA-02)
  # ---------------------------------------------------------------------------
  describe "CounterCacheable" do
    def create_tables(lock_version:)
      ActiveRecord::Schema.define do
        create_table :ol_posts, force: true do |t|
          t.string :title
          t.integer :ol_comments_count, default: 0, null: false
          t.integer :approved_count, default: 0, null: false
          t.integer :lock_version, default: 0, null: false if lock_version
          t.timestamps
        end
        create_table :ol_comments, force: true do |t|
          t.integer :ol_post_id
          t.string :body
          t.boolean :approved, default: false, null: false
        end
      end
    end

    def define_models(touch: false)
      stub_const("OlPost", Class.new(TestModel) do
        self.table_name = "ol_posts"
        has_many :ol_comments, class_name: "OlComment", foreign_key: :ol_post_id, inverse_of: :ol_post
      end)
      stub_const("OlComment", Class.new(TestModel) do
        self.table_name = "ol_comments"
        include ConcernsOnRails::CounterCacheable

        belongs_to :ol_post, class_name: "OlPost", optional: true, inverse_of: :ol_comments
        counter_cacheable_by :ol_post, touch: touch
        counter_cacheable_by :ol_post, count: :approved_count, if: -> { approved? }
        after_create { raise "boom" if body == "boom" }
      end)
    end

    def in_sync?(post)
      row = OlPost.where(id: post.id).pick(:lock_version, :ol_comments_count, :approved_count)
      [post.lock_version, post.ol_comments_count, post.approved_count] == row
    end

    context "with a lock_version column on the parent" do
      before do
        create_tables(lock_version: true)
        define_models
      end

      it "post.comments.create! leaves the loaded parent saveable, counter and lock_version mirrored" do
        post = OlPost.create!(title: "t")

        post.ol_comments.create!(body: "first", approved: true)

        expect(OlPost.find(post.id).ol_comments_count).to eq(1)
        expect(in_sync?(post)).to be(true)
        expect(post).not_to be_changed
        expect { post.update!(title: "edited") }.not_to raise_error
        expect(OlPost.find(post.id).attributes.slice("title", "ol_comments_count"))
          .to eq("title" => "edited", "ol_comments_count" => 1)
      end

      it "bumps lock_version ONCE for sibling counters that ride one UPDATE" do
        post = OlPost.create!(title: "t")

        post.ol_comments.create!(body: "first", approved: true)

        expect(post.lock_version).to eq(1)
        expect([post.ol_comments_count, post.approved_count]).to eq([1, 1])
      end

      it "Comment.create!(post: post) syncs the target it was handed" do
        post = OlPost.create!(title: "t")

        OlComment.create!(ol_post: post, body: "first")

        expect(in_sync?(post)).to be(true)
        expect { post.update!(title: "edited") }.not_to raise_error
      end

      it "destroy syncs the loaded parent" do
        post = OlPost.create!(title: "t")
        comment = post.ol_comments.create!(body: "first")

        comment.destroy!

        expect(OlPost.find(post.id).ol_comments_count).to eq(0)
        expect(in_sync?(post)).to be(true)
        expect { post.update!(title: "edited") }.not_to raise_error
      end

      it "a condition flip syncs the loaded parent" do
        post = OlPost.create!(title: "t")
        comment = post.ol_comments.create!(body: "first")

        comment.update!(approved: true)

        expect(post.approved_count).to eq(1)
        expect(in_sync?(post)).to be(true)
        expect { post.update!(title: "edited") }.not_to raise_error
      end

      it "a reparent through the writer syncs the new parent it holds" do
        old_post = OlPost.create!(title: "old")
        new_post = OlPost.create!(title: "new")
        comment = OlComment.create!(ol_post: old_post, body: "c")

        comment.update!(ol_post: new_post)

        expect(in_sync?(new_post)).to be(true)
        expect { new_post.update!(title: "edited") }.not_to raise_error
        expect(OlPost.find(old_post.id).ol_comments_count).to eq(0)
      end

      it "a reparent through the foreign key syncs the OLD parent the association still holds" do
        old_post = OlPost.create!(title: "old")
        new_post = OlPost.create!(title: "new")
        comment = OlComment.create!(ol_post: old_post, body: "c")

        comment.update!(ol_post_id: new_post.id)

        expect(in_sync?(old_post)).to be(true)
        expect { old_post.update!(title: "edited") }.not_to raise_error
        expect(OlPost.find(new_post.id).ol_comments_count).to eq(1)
      end

      it "leaves an unrelated stale instance of the parent stale (it did not see the write)" do
        post = OlPost.create!(title: "t")
        elsewhere = OlPost.find(post.id)

        post.ol_comments.create!(body: "first")

        expect { elsewhere.update!(title: "edited") }.to raise_error(ActiveRecord::StaleObjectError)
      end

      it "mirrors the counter too, so a full-row save (partial updates off) cannot write a stale count back" do
        setting = OlPost.respond_to?(:partial_updates=) ? :partial_updates : :partial_writes
        OlPost.public_send(:"#{setting}=", false)
        post = OlPost.create!(title: "t")

        post.ol_comments.create!(body: "first")
        post.update!(title: "edited")

        expect(OlPost.find(post.id).ol_comments_count).to eq(1)
      end

      it "keeps a counter the caller changed in memory (still pending, written by their save)" do
        post = OlPost.create!(title: "t")
        post.ol_comments_count = 42

        post.ol_comments.create!(body: "first")

        expect(post.ol_comments_count).to eq(42)
        expect(post.ol_comments_count_changed?).to be(true)
        expect(post.lock_version).to eq(OlPost.where(id: post.id).pick(:lock_version))
      end

      # PR #124 review (R124-01/01b): the mirror is undone when the database
      # change is — a rolled-back transaction or savepoint of the CHILD's
      # save rolls the parent row back, and the parent instance with it.
      it "a rolled-back transaction takes the mirrored delta and bump back off the parent" do
        post = OlPost.create!(title: "t")

        ActiveRecord::Base.transaction do
          post.ol_comments.create!(body: "x", approved: true)
          raise ActiveRecord::Rollback
        end

        expect(OlPost.where(id: post.id).pick(:lock_version, :ol_comments_count)).to eq([0, 0])
        expect([post.lock_version, post.ol_comments_count, post.approved_count]).to eq([0, 0, 0])
        expect(post).not_to be_changed
        expect { post.update!(title: "edited") }.not_to raise_error
      end

      it "a child whose later after_create raises leaves the parent in sync" do
        post = OlPost.create!(title: "t")

        expect { post.ol_comments.create!(body: "boom") }.to raise_error(RuntimeError, "boom")

        expect(in_sync?(post)).to be(true)
        expect { post.update!(title: "edited") }.not_to raise_error
      end

      it "a rolled-back savepoint undoes only its own adjustment" do
        post = OlPost.create!(title: "t")

        ActiveRecord::Base.transaction do
          post.ol_comments.create!(body: "kept")
          ActiveRecord::Base.transaction(requires_new: true) do
            post.ol_comments.create!(body: "dropped")
            raise ActiveRecord::Rollback
          end
        end

        expect(OlPost.find(post.id).ol_comments_count).to eq(1)
        expect(in_sync?(post)).to be(true)
        expect { post.update!(title: "edited") }.not_to raise_error
      end

      it "the same child saved in an outer transaction and a rolled-back savepoint keeps the outer adjustment" do
        post = OlPost.create!(title: "t")
        comment = nil

        ActiveRecord::Base.transaction do
          comment = post.ol_comments.create!(body: "c")
          ActiveRecord::Base.transaction(requires_new: true) do
            comment.update!(approved: true)
            raise ActiveRecord::Rollback
          end
        end

        expect(OlPost.where(id: post.id).pick(:ol_comments_count, :approved_count)).to eq([1, 0])
        expect(in_sync?(post)).to be(true)
      end

      it "a released savepoint's adjustment is undone when the outer transaction rolls back" do
        post = OlPost.create!(title: "t")

        ActiveRecord::Base.transaction do
          ActiveRecord::Base.transaction(requires_new: true) { post.ol_comments.create!(body: "c") }
          raise ActiveRecord::Rollback
        end

        expect([post.lock_version, post.ol_comments_count]).to eq([0, 0])
        expect(in_sync?(post)).to be(true)
      end

      it "a rolled-back destroy puts the parent's count and version back" do
        post = OlPost.create!(title: "t")
        comment = post.ol_comments.create!(body: "c")

        ActiveRecord::Base.transaction do
          comment.destroy!
          raise ActiveRecord::Rollback
        end

        expect([post.lock_version, post.ol_comments_count]).to eq([1, 1])
        expect(in_sync?(post)).to be(true)
        expect { post.update!(title: "edited") }.not_to raise_error
      end

      it "a committed adjustment is never undone by a later rollback of the same child" do
        post = OlPost.create!(title: "t")
        comment = post.ol_comments.create!(body: "c")

        ActiveRecord::Base.transaction do
          comment.update!(body: "edited")
          raise ActiveRecord::Rollback
        end

        expect([post.lock_version, post.ol_comments_count]).to eq([1, 1])
        expect(in_sync?(post)).to be(true)
      end

      # PR #124 review round 2 (R124-08): a savepoint released into a
      # joinable: false transaction is committed at once, but its UPDATE is
      # still rolled back with that transaction.
      it "a joinable: false transaction rolled back undoes the mirror made in its savepoint" do
        post = OlPost.create!(title: "t")

        ActiveRecord::Base.transaction(joinable: false) do
          post.ol_comments.create!(body: "c")
          raise ActiveRecord::Rollback
        end

        expect([post.lock_version, post.ol_comments_count]).to eq([0, 0])
        expect(in_sync?(post)).to be(true)
        expect { post.update!(title: "edited") }.not_to raise_error
      end

      # R124-09: the undo holds the parent, never the child — Rails keeps a
      # callback-less child only weakly while its transaction is open.
      it "does not keep every child created in a long transaction alive until it ends" do
        post = OlPost.create!(title: "t")
        count = 1000
        live = nil

        ActiveRecord::Base.transaction do
          count.times { |i| OlComment.create!(ol_post: post, body: "c#{i}") }
          GC.start(full_mark: true, immediate_sweep: true)
          live = ObjectSpace.each_object(OlComment).count
        end

        expect(live).to be < count / 2
        expect(in_sync?(post)).to be(true)
      end

      # R124-11: Rails restores a parent with after_commit callbacks before
      # the undo runs, which turns the mirrored count into an unsaved change.
      it "a parent with after_commit, created in a rolled-back transaction, saves the true count on retry" do
        OlPost.after_commit { nil }
        post = OlPost.new(title: "t")

        ActiveRecord::Base.transaction do
          post.save!
          post.ol_comments.create!(body: "c")
          raise ActiveRecord::Rollback
        end

        expect([post.lock_version, post.ol_comments_count]).to eq([0, 0])
        post.save! # autosave re-inserts the restored comment
        expect(OlPost.where(id: post.id).pick(:ol_comments_count)).to eq(OlComment.where(ol_post_id: post.id).count)
        expect(in_sync?(post)).to be(true)
      end

      it "a rollback leaves a counter the caller assigned after the mirror alone" do
        post = OlPost.create!(title: "t")

        ActiveRecord::Base.transaction do
          post.ol_comments.create!(body: "c")
          post.ol_comments_count = 42
          raise ActiveRecord::Rollback
        end

        expect(post.ol_comments_count).to eq(42)
        expect(post.ol_comments_count_changed?).to be(true)
        expect(post.lock_version).to eq(OlPost.where(id: post.id).pick(:lock_version))
      end

      # PR #124 review round 3. The undo holds its parent weakly and there is
      # one per (transaction, parent), so neither a batch over many parents
      # nor the outer transaction transactional tests open holds O(n).
      def undo_records(connection = ActiveRecord::Base.connection)
        connection.current_transaction.records.to_a.count { |r| r.is_a?(ConcernsOnRails::Models::CounterCacheable::MirrorUndo) }
      end

      # Up to 7.0 Rails itself keeps every record saved in an open
      # transaction alive (the release base without any mirror does too).
      it "a batch over many parents in one transaction keeps neither the parents nor their new children alive", min_rails: "7.1" do
        count = 600
        count.times { |i| OlPost.create!(title: "p#{i}") }
        live = nil

        ActiveRecord::Base.transaction do
          OlPost.find_each { |post| post.ol_comments.create!(body: "c") }
          GC.start(full_mark: true, immediate_sweep: true)
          live = ObjectSpace.each_object(OlComment).count
        end

        expect(live).to be < count / 2
      end

      it "keeps one undo per parent however many children a transaction creates" do
        post = OlPost.create!(title: "t")

        ActiveRecord::Base.transaction do
          300.times { post.ol_comments.create!(body: "c", approved: true) }
          expect(undo_records).to eq(1)
          raise ActiveRecord::Rollback
        end

        expect([post.lock_version, post.ol_comments_count, post.approved_count]).to eq([0, 0, 0])
        expect(in_sync?(post)).to be(true)
      end

      it "merges released savepoints' undos inside an outer joinable: false transaction (transactional tests)" do
        post = OlPost.create!(title: "t")
        connection = ActiveRecord::Base.connection
        connection.begin_transaction(joinable: false)
        begin
          300.times { |i| OlComment.create!(ol_post: post, body: "c#{i}") }
          expect(undo_records(connection)).to eq(1)
        ensure
          connection.rollback_transaction
        end

        expect([post.lock_version, post.ol_comments_count]).to eq([0, 0])
        expect(in_sync?(post)).to be(true)
      end

      it "undoes mirrors made through a becomes copy that shares the parent's attributes" do
        post = OlPost.create!(title: "t")
        view = post.becomes(OlPost)

        ActiveRecord::Base.transaction do
          post.ol_comments.create!(body: "a")
          view.ol_comments.create!(body: "b")
          raise ActiveRecord::Rollback
        end

        expect(in_sync?(post)).to be(true)
        expect { post.update!(title: "edited") }.not_to raise_error
      end

      it "a rollback leaves a lock_version the caller assigned after the mirror alone, like a counter" do
        post = OlPost.create!(title: "t")

        ActiveRecord::Base.transaction do
          post.ol_comments.create!(body: "c")
          post.lock_version = 0 # a form's hidden field
          raise ActiveRecord::Rollback
        end

        expect(post.lock_version).to eq(0)
        expect { post.update!(title: "edited") }.not_to raise_error
      end

      it "leaves an attr_readonly counter unmirrored instead of raising", min_rails: "7.1" do
        previous = ActiveRecord.raise_on_assign_to_attr_readonly
        ActiveRecord.raise_on_assign_to_attr_readonly = true
        OlPost.attr_readonly :ol_comments_count
        post = OlPost.create!(title: "t")

        expect { post.ol_comments.create!(body: "c") }.not_to raise_error
        expect(OlPost.where(id: post.id).pick(:ol_comments_count)).to eq(1)
        expect(post.lock_version).to eq(OlPost.where(id: post.id).pick(:lock_version))
      ensure
        ActiveRecord.raise_on_assign_to_attr_readonly = previous
      end

      it "parent saved with built children (autosave) is in sync" do
        post = OlPost.new(title: "t")
        post.ol_comments.build(body: "a")
        post.ol_comments.build(body: "b")
        post.save!

        expect(in_sync?(post)).to be(true)
        expect { post.update!(title: "edited") }.not_to raise_error
      end

      it "accepts_nested_attributes_for on an existing parent is in sync" do
        OlPost.accepts_nested_attributes_for :ol_comments
        post = OlPost.create!(title: "t")

        post.update!(title: "x", ol_comments_attributes: [{ body: "a" }, { body: "b" }])

        expect(in_sync?(post)).to be(true)
        expect { post.update!(title: "edited") }.not_to raise_error
      end

      it "with touch: true still mirrors the bump" do
        define_models(touch: true)
        post = OlPost.create!(title: "t")

        post.ol_comments.create!(body: "first")

        expect(in_sync?(post)).to be(true)
        expect { post.update!(title: "edited") }.not_to raise_error
      end
    end

    context "without a lock_version column" do
      before do
        create_tables(lock_version: false)
        define_models
      end

      it "leaves the loaded parent untouched in memory, as before" do
        post = OlPost.create!(title: "t")

        post.ol_comments.create!(body: "first", approved: true)

        expect(post.ol_comments_count).to eq(0) # documented: reload to read it
        expect(post).not_to be_changed
        expect(post.reload.ol_comments_count).to eq(1)
      end
    end
  end

  # PR #124 review (R124-01c): the gem's own veto path — a Stateable child
  # whose after_transition vetoes with ActiveRecord::Rollback — rolls the
  # counter UPDATE back, and must roll the parent instance back with it.
  describe "CounterCacheable x Stateable veto" do
    before do
      ActiveRecord::Schema.define do
        create_table :ol_vposts, force: true do |t|
          t.string :title
          t.integer :approved_count, default: 0, null: false
          t.integer :lock_version, default: 0, null: false
        end
        create_table :ol_vcomments, force: true do |t|
          t.integer :ol_vpost_id
          t.string :status
        end
      end
      stub_const("OlVpost", Class.new(TestModel) do
        self.table_name = "ol_vposts"
        has_many :ol_vcomments, class_name: "OlVcomment", foreign_key: :ol_vpost_id, inverse_of: :ol_vpost
      end)
      stub_const("OlVcomment", Class.new(TestModel) do
        self.table_name = "ol_vcomments"
        include ConcernsOnRails::CounterCacheable
        include ConcernsOnRails::Stateable

        belongs_to :ol_vpost, class_name: "OlVpost", optional: true, inverse_of: :ol_vcomments
        counter_cacheable_by :ol_vpost, count: :approved_count, if: -> { status == "approved" }
        stateable_by :status, states: %i[pending approved], default: :pending,
                              transitions: { approve: { from: :pending, to: :approved } }
        attr_accessor :veto

        def after_transition(*)
          raise ActiveRecord::Rollback if veto
        end
      end)
    end

    it "a vetoed transition leaves the loaded parent in sync and saveable" do
      post = OlVpost.create!(title: "t")
      comment = post.ol_vcomments.create!
      comment.veto = true

      expect(comment.approve!).to be(false)

      expect(OlVpost.where(id: post.id).pick(:lock_version, :approved_count)).to eq([0, 0])
      expect([post.lock_version, post.approved_count]).to eq([0, 0])
      expect { post.update!(title: "edited") }.not_to raise_error
    end

    it "an approved transition still mirrors onto the parent" do
      post = OlVpost.create!(title: "t")
      comment = post.ol_vcomments.create!

      expect(comment.approve!).to be(true)

      expect([post.lock_version, post.approved_count]).to eq(OlVpost.where(id: post.id).pick(:lock_version, :approved_count))
      expect(post.approved_count).to eq(1)
    end
  end

  # ---------------------------------------------------------------------------
  # Anonymizable (RA-04)
  # ---------------------------------------------------------------------------
  describe "Anonymizable" do
    def create_people_table(lock_version:)
      ActiveRecord::Schema.define do
        create_table :ol_people, force: true do |t|
          t.string :name
          t.string :email
          t.string :note
          t.text :secret
          t.string :slug
          t.datetime :anonymized_at
          t.integer :lock_version, default: 0, null: false if lock_version
        end
      end
    end

    def person_model(&body)
      Class.new(TestModel) do
        self.table_name = "ol_people"
        include ConcernsOnRails::Anonymizable

        anonymizable :name, :email, with: :redact
        class_eval(&body) if body
      end
    end

    context "with a lock_version column" do
      before { create_people_table(lock_version: true) }

      it "invalidates instances loaded before the erasure (an admin form cannot write PII back)" do
        klass = person_model
        person = klass.create!(name: "Jane Smith", email: "jane@example.com")
        admin_form = klass.find(person.id)

        person.anonymize!
        admin_form.email = "jane.smith@example.org"

        expect { admin_form.save! }.to raise_error(ActiveRecord::StaleObjectError)
        expect(klass.find(person.id).email).not_to eq("jane.smith@example.org")
        expect(person.lock_version).to eq(db_value(klass, person.id, :lock_version))
        expect { person.update!(note: "erased on request") }.not_to raise_error
      end

      it "bumps the ROW's value, so a stale anonymizing instance still erases and still invalidates" do
        klass = person_model
        person = klass.create!(name: "Jane Smith", email: "jane@example.com")
        stale = klass.find(person.id)
        person.update!(email: "jane.new@example.com") # lock_version 0 -> 1
        admin_form = klass.find(person.id)            # holds lock_version 1

        expect(stale.anonymize!).to be(true)

        row = klass.find(person.id)
        expect(row.email).not_to include("jane")
        expect(row.anonymized_at).to be_present
        expect(row.lock_version).to eq(2)
        expect { admin_form.update!(note: "x") }.to raise_error(ActiveRecord::StaleObjectError)
      end

      it "keeps the instance in sync for an after_anonymize that saves it" do
        klass = person_model { def after_anonymize = update!(note: "erased on request") }
        person = klass.create!(name: "Jane Smith", email: "jane@example.com")

        expect(person.anonymize!).to be(true)

        expect(klass.find(person.id).note).to eq("erased on request")
      end

      it "puts the in-memory lock_version back with everything else when a hook aborts" do
        klass = person_model { def after_anonymize = raise(ActiveRecord::Rollback) }
        person = klass.create!(name: "Jane Smith", email: "jane@example.com")

        expect(person.anonymize!).to be(false)

        expect(klass.find(person.id).email).to eq("jane@example.com")
        expect(person.lock_version).to eq(db_value(klass, person.id, :lock_version))
        expect { person.update!(note: "x") }.not_to raise_error
      end

      it "anonymize_all! invalidates every open instance too" do
        klass = person_model
        ids = Array.new(2) { |i| klass.create!(name: "P#{i}", email: "p#{i}@example.com").id }
        forms = ids.map { |id| klass.find(id) }

        expect(klass.anonymize_all!).to eq(2)

        forms.each { |form| expect { form.update!(note: "x") }.to raise_error(ActiveRecord::StaleObjectError) }
      end

      it "refuses a readonly record" do
        klass = person_model
        person = klass.create!(name: "Jane Smith", email: "jane@example.com")
        person.readonly!

        expect { person.anonymize! }.to raise_error(ActiveRecord::ReadOnlyRecord)
        expect(klass.find(person.id).email).to eq("jane@example.com")
      end

      it "refuses an attr_readonly column, as update_columns does" do
        klass = person_model { attr_readonly :email }
        person = klass.create!(name: "Jane Smith", email: "jane@example.com")

        expect { person.anonymize! }.to raise_error(ActiveRecord::ActiveRecordError, /email is marked as readonly/)
        expect(klass.find(person.id).email).to eq("jane@example.com")
      end

      it "still stores an encrypted field's erased value as ciphertext (values serialize through the types)" do
        klass = Class.new(TestModel) do
          self.table_name = "ol_people"
          include ConcernsOnRails::Models::Encryptable
          include ConcernsOnRails::Anonymizable

          encryptable :secret, key: "ol-anonymizable-passphrase"
          anonymizable :secret, with: :redact
        end
        person = klass.create!(secret: "top secret")

        expect(person.anonymize!).to be(true)

        raw = ActiveRecord::Base.connection.select_value(klass.unscoped.where(id: person.id).select(:secret).to_sql)
        expect(raw).to be_present
        expect(raw).not_to include("REDACTED")
        expect(klass.find(person.id).secret).to eq("[REDACTED]")
        expect(person.secret_encrypted?).to be(true)
      end

      it "retries a colliding rewritten slug, bumping lock_version once for the write that landed" do
        ActiveRecord::Base.connection.add_index :ol_people, :slug, unique: true
        klass = Class.new(TestModel) do
          self.table_name = "ol_people"
          include ConcernsOnRails::Models::Sluggable
          include ConcernsOnRails::Anonymizable
        end
        stub_const("OlSluggedPerson", klass)
        klass.sluggable_by :name
        klass.anonymizable :name, with: :redact
        klass.create!(name: "Taken", slug: "anon-collide")
        person = klass.create!(name: "Jane Smith")
        candidates = %w[anon-collide anon-fresh]
        allow(klass).to receive(:anonymizable_random_slug) { candidates.shift }

        expect(person.anonymize!).to be(true)

        expect(candidates).to be_empty # the first draw collided
        expect(klass.find(person.id).attributes.slice("slug", "lock_version"))
          .to eq("slug" => "anon-fresh", "lock_version" => 1)
        expect(person.lock_version).to eq(1)
      end
    end

    context "without a lock_version column" do
      before { create_people_table(lock_version: false) }

      it "erases through update_columns, as before" do
        klass = person_model
        person = klass.create!(name: "Jane Smith", email: "jane@example.com")
        expect(person).to receive(:update_columns).and_call_original

        expect(person.anonymize!).to be(true)
        expect(klass.find(person.id).email).not_to include("jane")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Encryptable key rotation (RA-05)
  # ---------------------------------------------------------------------------
  describe "Encryptable rotation" do
    def create_patients_table(lock_version:)
      ActiveRecord::Schema.define do
        create_table :ol_patients, force: true do |t|
          t.string :name
          t.text :ssn
          t.integer :lock_version, default: 0, null: false if lock_version
        end
      end
    end

    let(:patient_class) do
      Class.new(TestModel) do
        self.table_name = "ol_patients"
        include ConcernsOnRails::Models::Encryptable

        encryptable :ssn
      end
    end

    before { ConcernsOnRails.encryption.key = "ol-old-key" }

    after do
      ConcernsOnRails.encryption.key = nil
      ConcernsOnRails.encryption.key_id = 0
      ConcernsOnRails.encryption.previous_keys = {}
    end

    def rotate_key!
      ConcernsOnRails.encryption.key = "ol-new-key"
      ConcernsOnRails.encryption.key_id = 1
      ConcernsOnRails.encryption.previous_keys = { 0 => "ol-old-key" }
    end

    context "with a lock_version column" do
      before { create_patients_table(lock_version: true) }

      it "reencrypt_all! changes no value, so it leaves lock_version (and every open form) alone" do
        patient = patient_class.create!(name: "Pat", ssn: "111-22-3333")
        editor = patient_class.find(patient.id)
        rotate_key!

        expect(patient_class.reencrypt_all!).to eq(1)

        expect(db_value(patient_class, patient.id, :lock_version)).to eq(0)
        expect(patient_class.needs_reencryption.count).to eq(0)
        expect { editor.update!(name: "Patricia") }.not_to raise_error
        expect(patient_class.find(patient.id).ssn).to eq("111-22-3333")
      end

      it "reencrypt! leaves lock_version alone, so other open instances still save" do
        patient = patient_class.create!(name: "Pat", ssn: "111-22-3333")
        editor = patient_class.find(patient.id)
        rotate_key!

        expect(patient.reencrypt!).to be(true)

        expect(patient.lock_version).to eq(0)
        expect(db_value(patient_class, patient.id, :lock_version)).to eq(0)
        expect { editor.update!(name: "Q") }.not_to raise_error
      end

      it "still skips a row written since it was read (the ciphertext guard is untouched)" do
        patient = patient_class.create!(name: "Pat", ssn: "111-22-3333")
        rotate_key!
        stale = patient_class.find(patient.id)
        patient_class.find(patient.id).update!(ssn: "999-88-7777") # rewritten under the new key

        expect(stale.reencrypt!).to be(false)
        expect(patient_class.find(patient.id).ssn).to eq("999-88-7777")
      end
    end

    context "without a lock_version column" do
      before { create_patients_table(lock_version: false) }

      it "rotates as before" do
        patient = patient_class.create!(name: "Pat", ssn: "111-22-3333")
        rotate_key!

        expect(patient_class.reencrypt_all!).to eq(1)
        expect(patient_class.needs_reencryption.count).to eq(0)
        expect(patient_class.find(patient.id).ssn).to eq("111-22-3333")
      end
    end
  end
end
