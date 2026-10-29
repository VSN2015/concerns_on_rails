require "spec_helper"

# Regression (audit 2026-10-29, STATE-4): an association's soft `destroy_all` ended with
# `reset; loaded!` (ActiveRecord's bookkeeping for a hard delete). A soft-deleted row stays a
# member whenever the association's scope does not hide trash, so the cache claimed
# "loaded, empty" while a fresh read listed the rows.
RSpec.describe "SoftDeletable association destroy_all and the association cache" do
  before do
    ActiveRecord::Schema.define do
      create_table :ac_posts, force: true
      create_table :ac_comments, force: true do |t|
        t.integer :ac_post_id
        t.string :body
        t.datetime :deleted_at
      end
    end
  end

  after { %i[ac_posts ac_comments].each { |t| ActiveRecord::Base.connection.drop_table(t, if_exists: true) } }

  def comment_class(**options)
    Class.new(TestModel) do
      self.table_name = "ac_comments"
      include ConcernsOnRails::Models::SoftDeletable

      soft_deletable_by :deleted_at, **options
    end
  end

  def post_class
    Class.new(TestModel) do
      self.table_name = "ac_posts"
      has_many :ac_comments, class_name: "AcComment", foreign_key: :ac_post_id
    end
  end

  it "default_scope: false — keeps the soft-deleted rows as members of the association" do
    stub_const("AcComment", comment_class(default_scope: false))
    stub_const("AcPost", post_class)
    post = AcPost.create!
    post.ac_comments.create!(body: "x")
    post.ac_comments.create!(body: "y")

    post.ac_comments.destroy_all

    expect(AcComment.where(ac_post_id: post.id).count).to eq(2)
    expect(post.ac_comments.to_a.size).to eq(2)
    expect(post.ac_comments.size).to eq(AcPost.find(post.id).ac_comments.size)
    expect(post.ac_comments.map(&:deleted?)).to all(be(true))
  end

  it "a with_deleted association — a live row soft-deleted stays in it" do
    stub_const("AcComment", comment_class)
    stub_const("AcPost", Class.new(TestModel) do
      self.table_name = "ac_posts"
      has_many :all_comments, -> { with_deleted }, class_name: "AcComment", foreign_key: :ac_post_id
    end)
    post = AcPost.create!
    post.all_comments.create!(body: "x")

    post.all_comments.destroy_all

    expect(AcComment.with_deleted.count).to eq(1)
    expect(post.all_comments.to_a.size).to eq(1)
  end

  it "a hiding default scope — the cache still ends up empty (the rows left the association)" do
    stub_const("AcComment", comment_class)
    stub_const("AcPost", post_class)
    post = AcPost.create!
    post.ac_comments.create!(body: "x")
    post.ac_comments.create!(body: "y")

    expect(post.ac_comments.destroy_all.size).to eq(2)

    expect(post.ac_comments.to_a).to eq([])
    expect(post.ac_comments.size).to eq(0)
    expect(AcComment.with_deleted.count).to eq(2)
  end

  it "a trash association purge — the purged rows are gone from the association" do
    stub_const("AcComment", comment_class)
    stub_const("AcPost", Class.new(TestModel) do
      self.table_name = "ac_posts"
      has_many :trash, -> { only_deleted }, class_name: "AcComment", foreign_key: :ac_post_id
    end)
    post = AcPost.create!
    AcComment.create!(ac_post_id: post.id, body: "x").soft_delete!

    post.trash.destroy_all

    expect(post.trash.to_a).to eq([])
    expect(AcComment.with_deleted.count).to eq(0)
  end
end
