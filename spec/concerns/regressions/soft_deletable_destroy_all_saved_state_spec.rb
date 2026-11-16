require "spec_helper"

# Audit 2026-11-15 (STATE-1 / STATE-2): the contextual destroy_all of a LOADED
# relation / association sorted live from trashed rows by the in-memory,
# overridable `deleted?` instead of the SAVED stamp, and raised FrozenError on
# an instance that was already destroyed.
describe "SoftDeletable contextual destroy_all decides on the saved state" do
  before do
    ActiveRecord::Schema.define do
      create_table :sds_posts, force: true do |t|
        t.string :title
      end
      create_table :sds_comments, force: true do |t|
        t.integer :sds_post_id
        t.string :body
        t.datetime :deleted_at
      end
    end
    stub_const("SdsComment", Class.new(TestModel) do
      self.table_name = "sds_comments"
      include ConcernsOnRails::SoftDeletable

      soft_deletable_by :deleted_at
    end)
    stub_const("SdsPost", Class.new(TestModel) do
      self.table_name = "sds_posts"
      has_many :comments, class_name: "SdsComment", foreign_key: :sds_post_id
      has_many :trash, -> { only_deleted }, class_name: "SdsComment", foreign_key: :sds_post_id
    end)
  end

  after do
    %i[sds_posts sds_comments].each { |t| ActiveRecord::Base.connection.drop_table(t, if_exists: true) }
  end

  let(:post) { SdsPost.create! }
  let!(:comment) { SdsComment.create!(sds_post_id: post.id, body: "a") }

  def row(record)
    SdsComment.unscoped.find_by(id: record.id)
  end

  it "soft-deletes a live row whose loaded instance carries an unsaved stamp (relation)" do
    relation = SdsComment.where(sds_post_id: post.id).load
    relation.first.deleted_at = Time.zone.now
    relation.destroy_all
    expect(row(comment).deleted_at).not_to be_nil
  end

  it "soft-deletes a live row whose loaded instance carries an unsaved stamp (association)" do
    post.comments.load
    post.comments.first.deleted_at = Time.zone.now
    post.comments.destroy_all
    expect(row(comment).deleted_at).not_to be_nil
  end

  it "soft-deletes a live row whose instance overrides deleted? to true" do
    SdsComment.send(:define_method, :deleted?) { true }
    SdsComment.where(sds_post_id: post.id).load.destroy_all
    expect(row(comment).deleted_at).not_to be_nil
  end

  it "purges a trashed row whose loaded instance had its stamp cleared (relation)" do
    comment.soft_delete!
    relation = SdsComment.only_deleted.where(sds_post_id: post.id).load
    relation.first.deleted_at = nil
    relation.destroy_all
    expect(row(comment)).to be_nil
  end

  it "purges a trashed row whose loaded instance had its stamp cleared (trash association)" do
    comment.soft_delete!
    post.trash.load
    post.trash.first.deleted_at = nil
    post.trash.destroy_all
    expect(row(comment)).to be_nil
  end

  it "still leaves a trashed row alone for a non-trash relation, even with the stamp cleared in memory" do
    comment.soft_delete!
    relation = SdsComment.unscoped.where(sds_post_id: post.id).load
    relation.first.deleted_at = nil
    relation.destroy_all
    expect(row(comment).deleted_at).not_to be_nil
  end

  it "skips an already-destroyed instance in a loaded relation and soft-deletes the rest" do
    other = SdsComment.create!(sds_post_id: post.id, body: "b")
    relation = SdsComment.where(sds_post_id: post.id).order(:id).load
    relation.first.destroy
    expect { relation.destroy_all }.not_to raise_error
    expect(row(other).deleted_at).not_to be_nil
    expect(row(comment)).to be_nil
  end

  it "skips an already-destroyed instance in a loaded association and soft-deletes the rest" do
    other = SdsComment.create!(sds_post_id: post.id, body: "b")
    post.comments.load
    post.comments.min_by(&:id).destroy
    expect { post.comments.destroy_all }.not_to raise_error
    expect(row(other).deleted_at).not_to be_nil
    expect(row(comment)).to be_nil
  end
end
