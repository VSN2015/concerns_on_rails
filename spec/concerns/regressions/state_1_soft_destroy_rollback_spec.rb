require "spec_helper"

describe "STATE-1: rolled-back soft destroy_all restores the caller's instances" do
  before do
    ActiveRecord::Schema.define do
      create_table :sa_posts, force: true do |t|
        t.string :title
        t.datetime :deleted_at
      end
      create_table :sa_comments, force: true do |t|
        t.integer :sa_post_id
        t.string :body
        t.string :note
        t.datetime :deleted_at
        t.timestamps
      end
    end
    stub_const("SaComment", Class.new(TestModel) do
      self.table_name = "sa_comments"
      include ConcernsOnRails::SoftDeletable

      soft_deletable_by :deleted_at
      # a legal hold vetoes the soft delete of one comment
      cattr_accessor :boom
      after_commit { raise "index down" if self.class.boom }

      def before_soft_delete
        raise ActiveRecord::Rollback if body == "hold"
      end
    end)
    stub_const("SaPost", Class.new(TestModel) do
      self.table_name = "sa_posts"
      include ConcernsOnRails::SoftDeletable

      has_many :comments, class_name: "SaComment", foreign_key: :sa_post_id
    end)
  end

  after do
    %i[sa_posts sa_comments].each { |t| ActiveRecord::Base.connection.drop_table(t, if_exists: true) }
  end

  it "association destroy_all (no caller transaction): the rolled-back instance is not left soft-deleted, a retry writes" do
    post = SaPost.create!(title: "p")
    ok = SaComment.create!(sa_post_id: post.id, body: "ok")
    SaComment.create!(sa_post_id: post.id, body: "hold")
    post.comments.load
    expect { post.comments.destroy_all }.to raise_error(ActiveRecord::RecordNotSaved)

    expect(SaComment.unscoped.find(ok.id).deleted_at).to be_nil # the DB rolled back
    instance = post.comments.target.find { |c| c.id == ok.id }
    expect(instance.deleted?).to be(false) # memory agrees with the row
    expect(instance.soft_delete!).to be(true)
    expect(SaComment.unscoped.find(ok.id).deleted_at).not_to be_nil
  end

  it "loaded relation destroy_all inside a caller transaction: a retry of the rolled-back instance writes" do
    post = SaPost.create!(title: "p")
    ok = SaComment.create!(sa_post_id: post.id, body: "ok")
    SaComment.create!(sa_post_id: post.id, body: "hold")
    relation = SaComment.where(sa_post_id: post.id).order(:id).load
    SaPost.transaction do
      expect { relation.destroy_all }.to raise_error(ActiveRecord::RecordNotSaved)
    end

    expect(SaComment.unscoped.find(ok.id).deleted_at).to be_nil
    instance = relation.to_a.first
    expect(instance.soft_delete!).to be(true)
    expect(SaComment.unscoped.find(ok.id).deleted_at).not_to be_nil
  end

  it "trash-scope destroy_all: a purged instance is not left destroyed when a later soft delete rolls the batch back" do
    post = SaPost.create!(title: "p")
    old = SaComment.create!(sa_post_id: post.id, body: "old")
    old.soft_delete!
    SaComment.create!(sa_post_id: post.id, body: "hold")
    relation = SaComment.only_deleted.or(SaComment.where(body: "hold")).where(sa_post_id: post.id).order(:id).load
    expect { relation.destroy_all }.to raise_error(ActiveRecord::RecordNotSaved)

    expect(SaComment.unscoped.where(id: old.id).count).to eq(1) # the purge rolled back
    expect(relation.to_a.first.destroyed?).to be(false)
  end

  it "an after_commit raising after the outermost commit leaves the instances as written (the rows are committed)" do
    post = SaPost.create!(title: "p")
    comment = SaComment.create!(sa_post_id: post.id, body: "ok")
    relation = SaComment.where(sa_post_id: post.id).load
    SaComment.boom = true
    expect { relation.destroy_all }.to raise_error(RuntimeError, "index down")
    SaComment.boom = false

    expect(SaComment.unscoped.find(comment.id).deleted_at).not_to be_nil
    expect(relation.to_a.first.deleted?).to be(true)
  end

  it "a purged instance already joined to the caller's transaction is not left destroyed or frozen" do
    post = SaPost.create!(title: "p")
    old = SaComment.create!(sa_post_id: post.id, body: "old")
    old.soft_delete!
    SaComment.create!(sa_post_id: post.id, body: "hold")
    relation = SaComment.with_deleted.where(sa_post_id: post.id).order(:id).load
    first = relation.to_a.first
    SaComment.transaction do
      first.update!(note: "x")
      expect { relation.destroy_all }.to raise_error(ActiveRecord::RecordNotSaved)
    end

    expect(SaComment.unscoped.where(id: old.id).exists?).to be(true)
    expect(first.destroyed?).to be(false)
    expect(first.frozen?).to be(false)
  end

  it "a live instance written earlier in the caller's transaction is restored too" do
    post = SaPost.create!(title: "p")
    ok = SaComment.create!(sa_post_id: post.id, body: "ok")
    SaComment.create!(sa_post_id: post.id, body: "hold")
    relation = SaComment.where(sa_post_id: post.id).order(:id).load
    first = relation.to_a.first
    SaComment.transaction do
      first.update!(note: "x")
      expect { relation.destroy_all }.to raise_error(ActiveRecord::RecordNotSaved)
    end

    expect(first.deleted?).to be(false)
    expect(first.soft_delete!).to be(true)
    expect(SaComment.unscoped.find(ok.id).deleted_at).not_to be_nil
  end
end
