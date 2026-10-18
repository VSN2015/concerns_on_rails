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

# Review follow-up: only the ROOT copy was re-read. A Duplicable child copied
# through its own rules is bumped the same way by ITS copied children (its
# counter UPDATE also bumps its lock_version), so the nested copy raised
# StaleObjectError on its next save one level down.
describe "Duplicable: duplicate! of an optimistically locked graph, nested copies" do
  before do
    ActiveRecord::Schema.define do
      create_table :dup_nest_posts, force: true do |t|
        t.string :title
      end
      create_table :dup_nest_comments, force: true do |t|
        t.integer :dup_nest_post_id
        t.string :body
        t.integer :replies_count, default: 0
        t.integer :lock_version
      end
      create_table :dup_nest_replies, force: true do |t|
        t.integer :dup_nest_comment_id
        t.string :body
      end
    end
    stub_const("DupNestReply", Class.new(TestModel) do
      self.table_name = "dup_nest_replies"
      include ConcernsOnRails::Models::CounterCacheable

      belongs_to :dup_nest_comment
      counter_cacheable_by :dup_nest_comment, count: :replies_count
    end)
    stub_const("DupNestComment", Class.new(TestModel) do
      self.table_name = "dup_nest_comments"
      include ConcernsOnRails::Models::Duplicable

      belongs_to :dup_nest_post, optional: true
      has_many :dup_nest_replies, -> { order(:id) } # a scope defeats inverse detection
      duplicable_by associations: %i[dup_nest_replies]
    end)
    stub_const("DupNestPost", Class.new(TestModel) do
      self.table_name = "dup_nest_posts"
      include ConcernsOnRails::Models::Duplicable

      has_many :dup_nest_comments, -> { order(:id) }
      duplicable_by associations: %i[dup_nest_comments]
    end)
    post = DupNestPost.create!(title: "t")
    2.times do |i|
      comment = DupNestComment.create!(dup_nest_post: post, body: "c#{i}")
      2.times { |j| DupNestReply.create!(dup_nest_comment: comment, body: "r#{j}") }
    end
    @post = DupNestPost.find(post.id)
  end

  after(:each) do
    %i[dup_nest_posts dup_nest_comments dup_nest_replies].each do |table|
      ActiveRecord::Base.connection.drop_table(table, if_exists: true)
    end
  end

  it "returns nested copies whose lock_version and counters match their rows" do
    copy = @post.duplicate!

    expect(copy.dup_nest_comments.size).to eq(2)
    copy.dup_nest_comments.each do |comment|
      row = DupNestComment.find(comment.id)
      expect(comment.replies_count).to eq(2)
      expect(comment.lock_version).to eq(row.lock_version)
      expect(comment.changed?).to be(false)
    end
  end

  it "lets a nested copy save again without StaleObjectError" do
    copy = @post.duplicate!

    expect { copy.dup_nest_comments.first.update!(body: "x") }.not_to raise_error
    expect(DupNestComment.find(copy.dup_nest_comments.first.id).body).to eq("x")
  end

  it "does not touch the original graph" do
    versions = DupNestComment.where(dup_nest_post_id: @post.id).order(:id).pluck(:lock_version, :replies_count)
    @post.duplicate!

    expect(DupNestComment.where(dup_nest_post_id: @post.id).order(:id).pluck(:lock_version, :replies_count)).to eq(versions)
  end
end

# Review follow-up: the refresh ran one SELECT per copied record (a post with
# 5,000 Duplicable comments: ~5,001 SELECTs inside the transaction). It is one
# SELECT per CLASS now, whatever the number of copied children.
describe "Duplicable: duplicate! refresh cost" do
  before do
    ActiveRecord::Schema.define do
      create_table :dup_cost_posts, force: true do |t|
        t.string :title
        t.integer :lock_version
      end
      create_table :dup_cost_comments, force: true do |t|
        t.integer :dup_cost_post_id
        t.string :body
        t.integer :replies_count, default: 0
        t.integer :lock_version
      end
      create_table :dup_cost_replies, force: true do |t|
        t.integer :dup_cost_comment_id
      end
      create_table :dup_cost_plains, force: true do |t|
        t.integer :dup_cost_post_id
      end
    end
    stub_const("DupCostReply", Class.new(TestModel) do
      self.table_name = "dup_cost_replies"
      include ConcernsOnRails::Models::CounterCacheable

      belongs_to :dup_cost_comment
      counter_cacheable_by :dup_cost_comment, count: :replies_count
    end)
    stub_const("DupCostComment", Class.new(TestModel) do
      self.table_name = "dup_cost_comments"
      include ConcernsOnRails::Models::Duplicable

      has_many :dup_cost_replies, -> { order(:id) }
      duplicable_by associations: %i[dup_cost_replies]
    end)
    stub_const("DupCostPlain", Class.new(TestModel) do
      self.table_name = "dup_cost_plains"
      include ConcernsOnRails::Models::Duplicable
    end)
    stub_const("DupCostPost", Class.new(TestModel) do
      self.table_name = "dup_cost_posts"
      include ConcernsOnRails::Models::Duplicable

      has_many :dup_cost_comments, -> { order(:id) }
      has_many :dup_cost_plains
      duplicable_by associations: %i[dup_cost_comments dup_cost_plains]
    end)
  end

  after(:each) do
    %i[dup_cost_posts dup_cost_comments dup_cost_replies dup_cost_plains].each do |table|
      ActiveRecord::Base.connection.drop_table(table, if_exists: true)
    end
  end

  def build_post(comments)
    post = DupCostPost.create!(title: "t")
    comments.times do |i|
      comment = DupCostComment.create!(dup_cost_post_id: post.id, body: "c#{i}")
      DupCostReply.create!(dup_cost_comment: comment)
    end
    DupCostPlain.create!(dup_cost_post_id: post.id)
    DupCostPost.find(post.id)
  end

  # SELECTs `duplicate!` runs against the given tables.
  def selects_during(*tables)
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload[:sql].to_s
      queries << sql if sql =~ /\A\s*SELECT/i && tables.any? { |t| sql.include?(t) }
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  it "reads each copied class once, however many children were copied" do
    counts = [2, 12].map do |n|
      post = build_post(n)
      selects_during("dup_cost_comments") { post.duplicate! }.size
    end

    # the copy's children are read once by the original-graph walk
    # (`duplicate` loads them) and once by the refresh, never once per child
    expect(counts.first).to eq(counts.last)
  end

  it "still refreshes every nested copy" do
    copy = build_post(6).duplicate!

    copy.dup_cost_comments.each do |comment|
      expect(comment.lock_version).to eq(DupCostComment.find(comment.id).lock_version)
      expect(comment.replies_count).to eq(1)
      expect(comment.changed?).to be(false)
    end
    expect(copy.lock_version).to eq(DupCostPost.find(copy.id).lock_version)
  end

  it "runs no refresh query for a class without lock or counter columns" do
    post = build_post(2)

    # `duplicate` (no save, no refresh) loads the plains; the refresh adds none
    loading = selects_during("dup_cost_plains") { DupCostPost.find(post.id).duplicate }.size

    expect(selects_during("dup_cost_plains") { post.duplicate! }.size).to eq(loading)
  end
end
