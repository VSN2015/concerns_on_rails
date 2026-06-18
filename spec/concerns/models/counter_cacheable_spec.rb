# frozen_string_literal: true

require "spec_helper"

describe ConcernsOnRails::Models::CounterCacheable do
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
end
