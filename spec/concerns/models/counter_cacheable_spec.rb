# frozen_string_literal: true

require "spec_helper"

describe ConcernsOnRails::Models::CounterCacheable do
  # ActiveRecord#values_at (ActiveModel::Access) only exists from Rails 6.1;
  # read the two counters directly so the assertion means the same thing on
  # every line in the matrix.
  def reload_counts(record)
    fresh = record.reload
    [fresh.comments_count, fresh.approved_comments_count]
  end

  before(:each) do
    ActiveRecord::Schema.define do
      create_table :posts, force: true do |t|
        t.integer :comments_count, default: 0
        t.integer :approved_comments_count, default: 0
        t.timestamps
      end

      create_table :users, force: true do |t|
        t.integer :posts_count, default: 0
        t.timestamps
      end

      create_table :comments, force: true do |t|
        t.integer :post_id
        t.integer :author_id
        t.boolean :approved, default: false
        t.timestamps
      end
    end

    class Post < TestModel; end
    class User < TestModel; end

    class Comment < TestModel
      include ConcernsOnRails::CounterCacheable

      belongs_to :post, optional: true
      belongs_to :author, class_name: "User", optional: true

      counter_cacheable_by :post # posts.comments_count
      counter_cacheable_by :post, count: :approved_comments_count, if: -> { approved? }
      counter_cacheable_by :author, count: :posts_count, touch: true
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
    %i[Comment Post User].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
  end

  let(:post)  { Post.create! }
  let(:other) { Post.create! }

  describe "create / destroy" do
    it "increments on create and decrements on destroy" do
      comment = Comment.create!(post: post)
      expect(post.reload.comments_count).to eq(1)

      comment.destroy!
      expect(post.reload.comments_count).to eq(0)
    end

    it "does nothing when the foreign key is nil" do
      expect { Comment.create!(post: nil) }.not_to raise_error
      expect(post.reload.comments_count).to eq(0)
    end

    it "only counts toward the conditional column when the condition holds" do
      Comment.create!(post: post, approved: false)
      expect(post.reload.comments_count).to eq(1)
      expect(post.approved_comments_count).to eq(0)

      Comment.create!(post: post, approved: true)
      expect(post.reload.comments_count).to eq(2)
      expect(post.approved_comments_count).to eq(1)
    end
  end

  describe "update — condition flip" do
    it "increments the conditional counter when the condition turns true" do
      comment = Comment.create!(post: post, approved: false)
      expect(post.reload.approved_comments_count).to eq(0)

      comment.update!(approved: true)
      expect(post.reload.approved_comments_count).to eq(1)
      expect(post.comments_count).to eq(1) # unconditional counter untouched
    end

    it "decrements the conditional counter when the condition turns false" do
      comment = Comment.create!(post: post, approved: true)
      expect(post.reload.approved_comments_count).to eq(1)

      comment.update!(approved: false)
      expect(post.reload.approved_comments_count).to eq(0)
    end

    it "writes nothing on a no-op save" do
      comment = Comment.create!(post: post, approved: true)
      expect(post.reload.approved_comments_count).to eq(1)

      comment.update!(approved: true) # no change to the tracked attribute
      expect(post.reload.approved_comments_count).to eq(1)
    end
  end

  describe "update — foreign-key reparent" do
    it "moves the counter from the old parent to the new parent" do
      comment = Comment.create!(post: post, approved: true)
      expect(post.reload.comments_count).to eq(1)
      expect(post.approved_comments_count).to eq(1)

      comment.update!(post: other)

      expect(post.reload.comments_count).to eq(0)
      expect(post.approved_comments_count).to eq(0)
      expect(other.reload.comments_count).to eq(1)
      expect(other.approved_comments_count).to eq(1)
    end

    it "handles a simultaneous reparent + condition flip" do
      comment = Comment.create!(post: post, approved: true)
      expect(post.reload.approved_comments_count).to eq(1)

      comment.update!(post: other, approved: false)

      expect(post.reload.comments_count).to eq(0)
      expect(post.approved_comments_count).to eq(0) # was counted on the old parent, now removed
      expect(other.reload.comments_count).to eq(1)
      expect(other.approved_comments_count).to eq(0) # not approved on the new parent
    end
  end

  describe "touch:" do
    it "touches the parent only for counters declared with touch: true" do
      travel_to(Time.utc(2026, 1, 1, 12, 0, 0)) do
        @post = Post.create!
        @user = User.create!
      end

      travel_to(Time.utc(2026, 1, 1, 13, 0, 0)) do
        Comment.create!(post: @post, author: @user)
      end

      expect(@user.reload.posts_count).to eq(1)
      expect(@user.updated_at).to eq(Time.utc(2026, 1, 1, 13, 0, 0)) # touched
      expect(@post.reload.updated_at).to eq(Time.utc(2026, 1, 1, 12, 0, 0)) # not touched
    end
  end

  describe "transaction safety" do
    it "rolls the counter back when the surrounding transaction rolls back" do
      post # create it (committed)

      ActiveRecord::Base.transaction do
        Comment.create!(post: post)
        raise ActiveRecord::Rollback
      end

      expect(post.reload.comments_count).to eq(0)
      expect(Comment.count).to eq(0)
    end
  end

  describe ".recount_counter_caches!" do
    it "repairs drift for both unconditional and conditional counters" do
      Comment.create!(post: post, approved: true)
      Comment.create!(post: post, approved: false)
      Comment.create!(post: other, approved: true)

      # Corrupt the caches behind the callbacks' back.
      post.update_columns(comments_count: 99, approved_comments_count: 0)
      other.update_columns(comments_count: 0, approved_comments_count: 0)

      summary = Comment.recount_counter_caches!

      expect(post.reload.comments_count).to eq(2)
      expect(post.approved_comments_count).to eq(1)
      expect(other.reload.comments_count).to eq(1)
      expect(other.approved_comments_count).to eq(1)
      expect(summary).to include(comments_count: 2, approved_comments_count: 2)
    end

    it "zeroes parents that no longer have matching children" do
      comment = Comment.create!(post: post, approved: true)
      comment.delete # skips callbacks → leaves the cache stale
      expect(post.reload.comments_count).to eq(1)

      Comment.recount_counter_caches!(:post)
      expect(post.reload.comments_count).to eq(0)
    end

    it "raises on an association with no declared counter instead of reporting a silent success" do
      Comment.create!(post: post)
      post.update_columns(comments_count: 99)

      expect { Comment.recount_counter_caches!(:psot) }
        .to raise_error(ArgumentError, /no counter declared for association `psot` \(declared: post, author\)/)
      expect { Comment.recount_counter_caches!(:psot, parents: post) }
        .to raise_error(ArgumentError, /no counter declared for association `psot`/)

      expect(post.reload.comments_count).to eq(99) # neither call touched a row
    end
  end

  describe "argument validation" do
    def child_class(table: "comments", &declaration)
      Class.new(TestModel) do
        self.table_name = table
        include ConcernsOnRails::CounterCacheable

        class_eval(&declaration)
      end
    end

    it "raises when the association is undeclared" do
      expect do
        child_class { counter_cacheable_by :ghost }
      end.to raise_error(ArgumentError, /declare `belongs_to :ghost`/)
    end

    it "raises when the association is not a belongs_to" do
      expect do
        child_class(table: "posts") do
          has_many :comments
          counter_cacheable_by :comments
        end
      end.to raise_error(ArgumentError, /must be a belongs_to/)
    end

    it "rejects polymorphic associations" do
      expect do
        child_class do
          belongs_to :subject, polymorphic: true, optional: true
          counter_cacheable_by :subject, count: :comments_count
        end
      end.to raise_error(ArgumentError, /polymorphic/)
    end

    it "raises when the counter column does not exist on the parent table" do
      # Needs a NAMED class so ActiveRecord can resolve the belongs_to's parent
      # class (anonymous classes can't be name-resolved, and the check then
      # defers — load-order tolerance).
      expect do
        Object.const_set(:BadCounterChild, Class.new(TestModel) do
          self.table_name = "comments"
          include ConcernsOnRails::CounterCacheable

          belongs_to :post, optional: true
        end)
        BadCounterChild.counter_cacheable_by :post, count: :nope_count
      end.to raise_error(ArgumentError, /does not exist/)
    ensure
      Object.send(:remove_const, :BadCounterChild) if Object.const_defined?(:BadCounterChild)
    end

    it "rejects a non-callable :if" do
      expect do
        child_class do
          belongs_to :post, optional: true
          counter_cacheable_by :post, if: "approved"
        end
      end.to raise_error(ArgumentError, /:if must be callable/)
    end

    it "rejects a non-boolean :touch" do
      expect do
        child_class do
          belongs_to :post, optional: true
          counter_cacheable_by :post, touch: "yes"
        end
      end.to raise_error(ArgumentError, /:touch/)
    end

    it "rejects unknown options" do
      expect do
        child_class do
          belongs_to :post, optional: true
          counter_cacheable_by :post, bogus: 1
        end
      end.to raise_error(ArgumentError, /unknown option/)
    end
  end

  # A rule is keyed by (association, count column): re-declaring the same
  # counter replaces it rather than appending a second rule that double-counts.
  describe "re-declaring the same counter" do
    before do
      ActiveRecord::Schema.define do
        create_table :replies, force: true do |t|
          t.string :type
          t.integer :post_id
          t.boolean :approved, default: false
        end
      end
    end

    let(:reply_class) do
      Class.new(TestModel) do
        self.table_name = "replies"
        include ConcernsOnRails::CounterCacheable

        belongs_to :post, optional: true
        counter_cacheable_by :post, count: :comments_count
      end
    end

    it "lets an STI subclass narrow an inherited counter without double-counting" do
      stub_const("Reply", reply_class)
      stub_const("ModeratedReply", Class.new(reply_class) do
        counter_cacheable_by :post, count: :comments_count, if: -> { approved? }
      end)

      ModeratedReply.create!(post: post, approved: true)
      ModeratedReply.create!(post: post, approved: false)
      Reply.create!(post: post)

      expect(post.reload.comments_count).to eq(2)
      expect(ModeratedReply.counter_cacheable_rules.size).to eq(1)
      expect(Reply.counter_cacheable_rules.first[:condition]).to be_nil # parent untouched
    end

    context "when recounting an STI-narrowed counter" do
      before do
        stub_const("Reply", reply_class)
        stub_const("ModeratedReply", Class.new(reply_class) do
          counter_cacheable_by :post, count: :comments_count, if: -> { approved? }
        end)
      end

      it "agrees with the live count when called on the parent class" do
        Reply.create!(post: post)
        ModeratedReply.create!(post: post, approved: false) # not counted by its own rule
        expect(post.reload.comments_count).to eq(1)

        Reply.recount_counter_caches!
        expect(post.reload.comments_count).to eq(1)
      end

      it "keeps the parent class's rows when called on the subclass" do
        Reply.create!(post: post)
        ModeratedReply.create!(post: post, approved: true)
        expect(post.reload.comments_count).to eq(2)

        ModeratedReply.recount_counter_caches!
        expect(post.reload.comments_count).to eq(2)
      end

      it "repairs drift the same way, with parents:, from either class" do
        Reply.create!(post: post)
        ModeratedReply.create!(post: post, approved: true)
        ModeratedReply.create!(post: post, approved: false)
        Post.where(id: post.id).update_all(comments_count: 99)

        expect(ModeratedReply.recount_counter_caches!(parents: [post])).to eq(comments_count: 1)
        expect(post.reload.comments_count).to eq(2)
        Post.where(id: post.id).update_all(comments_count: 0)
        Reply.recount_counter_caches!(parents: [post])
        expect(post.reload.comments_count).to eq(2)
      end
    end

    it "replaces the earlier rule, in place, when the same class re-declares it" do
      stub_const("Reply", reply_class) # the `type` column needs a named class
      reply_class.counter_cacheable_by :post, count: :approved_comments_count, if: -> { approved? }
      reply_class.counter_cacheable_by :post, count: :comments_count, touch: true

      rules = reply_class.counter_cacheable_rules
      expect(rules.map { |rule| rule[:count_column] }).to eq(%i[comments_count approved_comments_count])
      expect(rules.first[:touch]).to be(true)

      reply_class.create!(post: post)
      expect(reload_counts(post)).to eq([1, 0])
    end
  end

  describe "statement batching (1.26)" do
    def capture_post_updates
      updates = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
        sql = args.last[:sql].to_s
        updates << sql if sql.start_with?("UPDATE") && sql.include?("posts")
      end
      yield
      updates
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "adjusts sibling counters on the same parent in ONE UPDATE" do
      updates = capture_post_updates { Comment.create!(post: post, approved: true) }

      post.reload
      expect(post.comments_count).to eq(1)
      expect(post.approved_comments_count).to eq(1)
      expect(updates.length).to eq(1)
    end

    it "keeps a reparent as one UPDATE per parent" do
      comment = Comment.create!(post: post, approved: true)

      updates = capture_post_updates { comment.update!(post: other) }

      expect(post.reload.comments_count).to eq(0)
      expect(other.reload.comments_count).to eq(1)
      expect(other.reload.approved_comments_count).to eq(1)
      expect(updates.length).to eq(2) # old parent −, new parent + (both counters batched)
    end
  end

  describe ".recount_counter_caches! with parents:" do
    let(:third) { Post.create! }

    before do
      Comment.create!(post: post, approved: true)
      Comment.create!(post: post)
      Comment.create!(post: other)
      3.times { Comment.create!(post: third) }
      Post.update_all(comments_count: 99, approved_comments_count: 99) # drift everywhere
    end

    it "repairs only the given parents — ids, records or a relation — and leaves the rest alone" do
      result = Comment.recount_counter_caches!(:post, parents: [post.id, other])
      expect(result).to eq(comments_count: 2, approved_comments_count: 1)
      expect(reload_counts(post)).to eq([2, 1])
      expect(reload_counts(other)).to eq([1, 0])
      expect(reload_counts(third)).to eq([99, 99])

      Comment.recount_counter_caches!(:post, parents: Post.where(id: third.id))
      expect(reload_counts(third)).to eq([3, 0])
      expect(post.reload.comments_count).to eq(2)
    end

    it "zeroes a listed parent that has no children and treats an empty parents: as a no-op" do
      lonely = Post.create!
      Post.where(id: lonely.id).update_all(comments_count: 5)

      expect(Comment.recount_counter_caches!(:post, parents: lonely)).to eq(comments_count: 0, approved_comments_count: 0)
      expect(lonely.reload.comments_count).to eq(0)

      expect(Comment.recount_counter_caches!(:post, parents: Post.none)).to eq(comments_count: 0, approved_comments_count: 0)
      expect(Comment.recount_counter_caches!(:post, parents: [])).to eq(comments_count: 0, approved_comments_count: 0)
      expect(third.reload.comments_count).to eq(99)
    end

    it "requires the association when parents: would be ambiguous" do
      expect { Comment.recount_counter_caches!(parents: [post.id]) }
        .to raise_error(ArgumentError, /parents: needs the association when more than one is declared \(post, author\)/)

      author = User.create!
      Comment.create!(author: author)
      User.update_all(posts_count: 42)
      expect(Comment.recount_counter_caches!(:author, parents: author)).to eq(posts_count: 1)
      expect(author.reload.posts_count).to eq(1)
    end

    it "refuses parents: from the wrong class instead of rewriting whatever shares those ids" do
      author = User.create!
      expect { Comment.recount_counter_caches!(:post, parents: author) }
        .to raise_error(ArgumentError, /parents: must contain Post records \(got User\)/)
      expect { Comment.recount_counter_caches!(:post, parents: User.where(id: author.id)) }
        .to raise_error(ArgumentError, /parents: must contain Post records \(got User\)/)

      # Still the drifted 99 the before block wrote: the refused calls neither
      # zeroed nor rewrote anything.
      expect(post.reload.comments_count).to eq(99)
    end

    it "refuses an explicit parents: nil rather than widening into a full-table rewrite" do
      expect { Comment.recount_counter_caches!(:post, parents: nil) }
        .to raise_error(ArgumentError, /parents: cannot be nil/)
      expect { Comment.recount_counter_caches!(:post, parents: Post.find_by(id: -1)) }
        .to raise_error(ArgumentError, /parents: cannot be nil/)

      expect(third.reload.comments_count).to eq(99) # nothing zeroed, nothing rewritten
      expect(Comment.recount_counter_caches!(:post)).to eq(comments_count: 3, approved_comments_count: 1)
    end

    it "locks the listed parents inside the transaction, before the children are tallied" do
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
        statements << args.last[:sql].to_s
      end
      begin
        Comment.recount_counter_caches!(:post, parents: post)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      posts    = TestDatabase.quoted_table("posts")
      comments = TestDatabase.quoted_table("comments")

      # Rails 7.1 emits "begin transaction"; 7.2+ switched SQLite to IMMEDIATE
      # transactions and upcased it ("BEGIN IMMEDIATE TRANSACTION"), so match loosely.
      opened  = statements.index { |sql| sql.match?(/\Abegin\b/i) }
      locked  = statements.index { |sql| sql.start_with?("SELECT #{TestDatabase.qualified('posts', 'id')} FROM #{posts}") }
      tallied = statements.index { |sql| sql.include?("FROM #{comments}") }
      zeroed  = statements.index { |sql| sql.start_with?("UPDATE #{posts}") }

      expect([opened, locked, tallied, zeroed]).to all(be_a(Integer))
      expect(opened).to be < locked  # the lock is taken inside the transaction
      expect(locked).to be < tallied # ...and before the tally the rewrite depends on
      expect(tallied).to be < zeroed
    end
  end

  describe "destroy uses the persisted row (1.29 audit)" do
    it "decrements once when two stale instances of the same row are both destroyed" do
      comment = Comment.create!(post: post, approved: true)
      Comment.create!(post: post, approved: true)
      stale = Comment.find(comment.id)

      comment.destroy!
      stale.destroy # the DELETE matches 0 rows — nothing was removed

      expect(reload_counts(post)).to eq([1, 1])
    end

    it "does not decrement when a new (never-saved) record is destroyed" do
      Comment.create!(post: post, approved: true)
      Comment.new(post: post, approved: true).destroy

      expect(reload_counts(post)).to eq([1, 1])
    end

    it "decrements the PERSISTED parent, not an unsaved in-memory reparent" do
      comment = Comment.create!(post: post)
      comment.post = other # assigned but never saved

      comment.destroy!

      expect(post.reload.comments_count).to eq(0)
      expect(other.reload.comments_count).to eq(0)
    end

    it "evaluates if: against the persisted state, not an unsaved condition flip" do
      comment = Comment.create!(post: post, approved: true)
      comment.approved = false # unsaved flip

      comment.destroy!

      expect(reload_counts(post)).to eq([0, 0])
    end

    it "leaves the in-memory unsaved values in place after evaluating the persisted ones" do
      comment = Comment.create!(post: post, approved: true)
      comment.approved = false
      comment.destroy!

      expect(comment.approved).to be(false)
    end
  end

  describe "belongs_to primary_key: (1.29 audit)" do
    before(:each) do
      ActiveRecord::Schema.define do
        create_table :boards, force: true do |t|
          t.integer :code
          t.integer :pins_count, default: 0
          t.integer :hot_pins_count, default: 0
        end

        create_table :pins, force: true do |t|
          t.integer :board_code
          t.boolean :hot, default: false
        end
      end

      class Board < TestModel; end

      class Pin < TestModel
        include ConcernsOnRails::CounterCacheable

        belongs_to :board, primary_key: :code, foreign_key: :board_code, optional: true
        counter_cacheable_by :board
        counter_cacheable_by :board, count: :hot_pins_count, if: -> { hot? }
      end
    end

    after(:each) do
      %i[Pin Board].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    end

    # decoy.id == target.code, so a lookup by `id` would hit the wrong row.
    let!(:target) { Board.create!(code: 2) }
    let!(:decoy)  { Board.create!(code: 99) }

    def board_counts(board)
      fresh = board.reload
      [fresh.pins_count, fresh.hot_pins_count]
    end

    it "adjusts the parent addressed by the association key on create / update / destroy" do
      expect(decoy.id).to eq(target.code)

      pin = Pin.create!(board: target, hot: true)
      expect(board_counts(target)).to eq([1, 1])
      expect(board_counts(decoy)).to eq([0, 0])

      pin.update!(hot: false)
      expect(board_counts(target)).to eq([1, 0])

      pin.update!(board: decoy)
      expect(board_counts(target)).to eq([0, 0])
      expect(board_counts(decoy)).to eq([1, 0])

      pin.destroy!
      expect(board_counts(decoy)).to eq([0, 0])
    end

    it "recounts by the association key" do
      Pin.create!(board: target, hot: true)
      Pin.create!(board: target)
      Board.update_all(pins_count: 7, hot_pins_count: 7)

      Pin.recount_counter_caches!

      expect(board_counts(target)).to eq([2, 1])
      expect(board_counts(decoy)).to eq([0, 0])
    end

    it "recounts only the given parents: (records, relations and ids) by the association key" do
      Pin.create!(board: target, hot: true)
      Board.update_all(pins_count: 7, hot_pins_count: 7)

      Pin.recount_counter_caches!(parents: target)
      expect(board_counts(target)).to eq([1, 1])
      expect(board_counts(decoy)).to eq([7, 7])

      Board.update_all(pins_count: 7, hot_pins_count: 7)
      Pin.recount_counter_caches!(parents: Board.where(id: target.id))
      expect(board_counts(target)).to eq([1, 1])
      expect(board_counts(decoy)).to eq([7, 7])

      # Bare values are the parent's primary-key ids, as documented.
      Board.update_all(pins_count: 7, hot_pins_count: 7)
      Pin.recount_counter_caches!(parents: [target.id])
      expect(board_counts(target)).to eq([1, 1])
      expect(board_counts(decoy)).to eq([7, 7])
    end
  end

  describe "destroyed by the parent's dependent: :destroy (review of #111)" do
    before(:each) do
      ActiveRecord::Schema.define do
        create_table :lk_posts, force: true do |t|
          t.integer :lock_version, default: 0
          t.integer :lk_notes_count, default: 0
        end
        create_table :lk_users, force: true do |t|
          t.integer :lk_notes_count, default: 0
        end
        create_table :lk_notes, force: true do |t|
          t.integer :lk_post_id
          t.integer :lk_user_id
        end
      end

      Object.const_set(:LkPost, Class.new(TestModel) { self.table_name = "lk_posts" })
      Object.const_set(:LkUser, Class.new(TestModel) { self.table_name = "lk_users" })
      Object.const_set(:LkNote, Class.new(TestModel) { self.table_name = "lk_notes" })
      LkPost.has_many :lk_notes, dependent: :destroy
      LkNote.class_eval do
        include ConcernsOnRails::CounterCacheable

        belongs_to :lk_post
        belongs_to :lk_user, optional: true
        counter_cacheable_by :lk_post
        counter_cacheable_by :lk_user
      end
    end

    after(:each) do
      %i[LkNote LkPost LkUser].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    end

    it "skips the decrement on the parent being destroyed (no StaleObjectError under lock_version)" do
      post = LkPost.create!
      user = LkUser.create!
      2.times { LkNote.create!(lk_post: post, lk_user: user) }

      expect { post.reload.destroy! }.not_to raise_error
      expect(LkPost.count).to eq(0)
      expect(LkNote.count).to eq(0)
      # Only the counter on the association doing the destroying is skipped.
      expect(user.reload.lk_notes_count).to eq(0)
    end

    it "still decrements when the child is destroyed on its own" do
      post = LkPost.create!
      note = LkNote.create!(lk_post: post)
      note.destroy!
      expect(post.reload.lk_notes_count).to eq(0)
    end
  end

  describe "has_one replacement with dependent: :destroy (re-review of #111)" do
    before(:each) do
      ActiveRecord::Schema.define do
        create_table :ho_profiles, force: true do |t|
          t.integer :ho_avatars_count, default: 0
        end
        create_table :ho_avatars, force: true do |t|
          t.integer :ho_profile_id
        end
      end

      Object.const_set(:HoProfile, Class.new(TestModel) { self.table_name = "ho_profiles" })
      Object.const_set(:HoAvatar, Class.new(TestModel) { self.table_name = "ho_avatars" })
      HoProfile.has_one :ho_avatar, dependent: :destroy
      HoAvatar.class_eval do
        include ConcernsOnRails::CounterCacheable

        belongs_to :ho_profile
        counter_cacheable_by :ho_profile
      end
    end

    after(:each) do
      %i[HoAvatar HoProfile].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    end

    it "decrements for the replaced record — the parent survives" do
      profile = HoProfile.create!
      profile.create_ho_avatar!
      profile.create_ho_avatar! # destroys the old one through the has_one

      expect(HoAvatar.count).to eq(1)
      expect(profile.reload.ho_avatars_count).to eq(1)
    end
  end
end
