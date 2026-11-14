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
        t.datetime :deleted_at
        t.timestamps
      end
    end
    stub_const("SaComment", Class.new(TestModel) do
      self.table_name = "sa_comments"
      include ConcernsOnRails::SoftDeletable

      soft_deletable_by :deleted_at
      # a legal hold vetoes the soft delete of one comment
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
    SaPost.has_many :trash, -> { with_deleted }, class_name: "SaComment", foreign_key: :sa_post_id
    old = SaComment.create!(sa_post_id: post.id, body: "old")
    old.soft_delete!
    SaComment.create!(sa_post_id: post.id, body: "hold")
    relation = SaComment.only_deleted.or(SaComment.where(body: "hold")).where(sa_post_id: post.id).order(:id).load
    expect { relation.destroy_all }.to raise_error(ActiveRecord::RecordNotSaved)

    expect(SaComment.unscoped.where(id: old.id).count).to eq(1) # the purge rolled back
    expect(relation.to_a.first.destroyed?).to be(false)
  end
end
