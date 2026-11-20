require "spec_helper"

# Audit 2026-11-21, B-1. With lock_version on the parent, a child create
# mirrors the counter delta + lock_version bump onto the loaded parent and
# MirrorUndo moves them back on rollback. When the parent was ALSO saved in
# that transaction after the mirror, Rails restored its own start-of-
# transaction snapshot (which already held the mirrored values) after the undo
# ran: the counter read as a pending change from the mirrored value and
# lock_version looked clean at a value the row never held.
describe ConcernsOnRails::Models::CounterCacheable do
  before do
    ActiveRecord::Schema.define do
      create_table :bm_posts, force: true do |t|
        t.string :title
        t.integer :bm_comments_count, default: 0, null: false
        t.integer :lock_version, default: 0, null: false
      end
      create_table :bm_comments, force: true do |t|
        t.integer :bm_post_id
        t.string :body
      end
    end
    stub_const("BmPost", Class.new(TestModel) do
      self.table_name = "bm_posts"
      has_many :bm_comments, class_name: "BmComment", foreign_key: :bm_post_id, inverse_of: :bm_post
    end)
    stub_const("BmComment", Class.new(TestModel) do
      self.table_name = "bm_comments"
      include ConcernsOnRails::CounterCacheable
      belongs_to :bm_post, class_name: "BmPost", optional: true, inverse_of: :bm_comments
      counter_cacheable_by :bm_post
    end)
  end

  after do
    ActiveRecord::Base.connection.drop_table(:bm_comments, if_exists: true)
    ActiveRecord::Base.connection.drop_table(:bm_posts, if_exists: true)
  end

  let!(:post) { BmPost.create!(title: "t") }
  let!(:control) { BmPost.create!(title: "t") }

  def row(record)
    BmPost.connection.select_one("SELECT bm_comments_count, lock_version FROM bm_posts WHERE id = #{record.id}")
  end

  # The parent's OWN save in a rolled-back transaction leaves a pending
  # lock_version in plain Rails too, so the child create must change nothing
  # on top of that: same in-memory state as a parent that only saved.
  def expect_like_control(&work)
    ActiveRecord::Base.transaction do
      work.call(post, true)
      raise ActiveRecord::Rollback
    end
    ActiveRecord::Base.transaction do
      work.call(control, false)
      raise ActiveRecord::Rollback
    end

    expect(post.bm_comments_count).to eq(0)
    expect([post.lock_version, post.changes]).to eq([control.lock_version, control.changes])
    expect(row(post)).to eq(row(control))
  end

  it "leaves no trace when the parent is saved after the mirror and the transaction rolls back" do
    expect_like_control do |parent, child|
      parent.bm_comments.create!(body: "c") if child
      parent.update!(title: "edited")
    end
  end

  it "leaves no trace when the parent is saved before the mirror" do
    expect_like_control do |parent, child|
      parent.update!(title: "edited")
      parent.bm_comments.create!(body: "c") if child
    end
  end

  it "leaves no trace when the parent is saved around the mirror" do
    expect_like_control do |parent, child|
      parent.update!(title: "one")
      parent.bm_comments.create!(body: "c") if child
      parent.update!(title: "two")
    end
  end

  it "leaves no trace through a savepoint rolled back with the parent saved after the mirror" do
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.transaction(requires_new: true) do
        post.bm_comments.create!(body: "c")
        post.update!(title: "edited")
        raise ActiveRecord::Rollback
      end
    end
    ActiveRecord::Base.transaction do
      ActiveRecord::Base.transaction(requires_new: true) do
        control.update!(title: "edited")
        raise ActiveRecord::Rollback
      end
    end

    expect(post.bm_comments_count).to eq(0)
    expect([post.lock_version, post.changes]).to eq([control.lock_version, control.changes])
  end

  it "stays in step with its row when only the mirror rolls back" do
    ActiveRecord::Base.transaction do
      post.bm_comments.create!(body: "c")
      raise ActiveRecord::Rollback
    end

    expect([post.bm_comments_count, post.lock_version, post.changed?]).to eq([0, 0, false])
    expect { post.update!(title: "again") }.not_to raise_error
  end

  it "keeps the mirror and the parent's save when the transaction commits" do
    ActiveRecord::Base.transaction do
      post.bm_comments.create!(body: "c")
      post.update!(title: "edited")
    end

    expect(row(post)).to include("bm_comments_count" => 1)
    expect(post.changed?).to be(false)
    expect { post.update!(title: "again") }.not_to raise_error
  end
end
