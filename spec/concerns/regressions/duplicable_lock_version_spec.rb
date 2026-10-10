require "spec_helper"

# Audit 2026-10-10 DATA-10: every copied child's create incremented the copy's
# counter with an UPDATE that also bumped the copy's lock_version row-side.
# The bump reached the in-memory copy only when the child's belongs_to target
# WAS the copy (inverse detection); through a scoped (inverse-less) has_many
# the copy `duplicate!` returned was a version behind its own row and raised
# StaleObjectError on its next save.
describe "Duplicable: duplicate! of an optimistically locked record" do
  before do
    ActiveRecord::Schema.define do
      create_table :dup_lock_posts, force: true do |t|
        t.string :title
        t.integer :comments_count, default: 0
        t.integer :notes_count, default: 0
        t.integer :lock_version
      end
      create_table :dup_lock_comments, force: true do |t|
        t.integer :dup_lock_post_id
        t.string :body
      end
      create_table :dup_lock_notes, force: true do |t|
        t.integer :dup_lock_post_id
      end
    end
  end

  after(:each) do
    %i[dup_lock_posts dup_lock_comments dup_lock_notes].each do |table|
      ActiveRecord::Base.connection.drop_table(table, if_exists: true)
    end
  end

  def define_comment
    stub_const("DupLockComment", Class.new(TestModel) do
      self.table_name = "dup_lock_comments"
      include ConcernsOnRails::Models::CounterCacheable

      belongs_to :dup_lock_post
      counter_cacheable_by :dup_lock_post, count: :comments_count
    end)
  end

  it "returns a copy that saves after children were copied through an inverse-less has_many" do
    stub_const("DupLockPost", Class.new(TestModel) do
      self.table_name = "dup_lock_posts"
      include ConcernsOnRails::Models::Duplicable

      has_many :dup_lock_comments, -> { order(:id) } # a scope defeats inverse detection
      duplicable_by associations: %i[dup_lock_comments]
    end)
    define_comment
    post = DupLockPost.create!(title: "t")
    2.times { |i| DupLockComment.create!(dup_lock_post: post, body: i.to_s) }
    copy = post.duplicate!

    expect(copy.comments_count).to eq(2)
    expect(copy.lock_version).to eq(DupLockPost.find(copy.id).lock_version)
    expect { copy.update!(title: "copy") }.not_to raise_error
    expect(DupLockPost.find(copy.id).title).to eq("copy")
  end

  it "does the same for a native `counter_cache:` child" do
    stub_const("DupLockPost", Class.new(TestModel) do
      self.table_name = "dup_lock_posts"
      include ConcernsOnRails::Models::Duplicable

      has_many :dup_lock_notes, -> { order(:id) }
      duplicable_by associations: %i[dup_lock_notes]
    end)
    stub_const("DupLockNote", Class.new(TestModel) do
      self.table_name = "dup_lock_notes"
      belongs_to :dup_lock_post, counter_cache: :notes_count
    end)
    post = DupLockPost.create!(title: "t")
    DupLockNote.create!(dup_lock_post: post)
    copy = post.duplicate!

    expect(copy.notes_count).to eq(1)
    expect { copy.update!(title: "copy") }.not_to raise_error
  end

  it "keeps the inverse-detected has_many (whose bump was already mirrored) working" do
    stub_const("DupLockPost", Class.new(TestModel) do
      self.table_name = "dup_lock_posts"
      include ConcernsOnRails::Models::Duplicable

      has_many :dup_lock_comments
      duplicable_by associations: %i[dup_lock_comments]
    end)
    define_comment
    post = DupLockPost.create!(title: "t")
    DupLockComment.create!(dup_lock_post: post, body: "b")
    copy = DupLockPost.find(post.id).duplicate!

    expect(copy.comments_count).to eq(1)
    expect { copy.update!(title: "copy") }.not_to raise_error
  end

  it "leaves the copy's own change tracking clean" do
    stub_const("DupLockPost", Class.new(TestModel) do
      self.table_name = "dup_lock_posts"
      include ConcernsOnRails::Models::Duplicable

      has_many :dup_lock_comments, -> { order(:id) }
      duplicable_by associations: %i[dup_lock_comments]
    end)
    define_comment
    post = DupLockPost.create!(title: "t")
    DupLockComment.create!(dup_lock_post: post, body: "b")
    copy = post.duplicate!

    expect(copy.changed?).to be(false)
  end
end
