require "spec_helper"

# Audit 2026-10-10 (STATE-10): SoftDeletable's default scope opened with
# `unscope(where: :deleted_at)`. ActiveRecord records an unscope on the
# relation and Relation#merge replays it on the RECEIVER, where it matches the
# column by name on any table. So `Comment.joins(:post).merge(Post.where(...))`
# stripped the comments' own `deleted_at IS NULL` and soft-deleted comments
# came back. The named scopes (`with_deleted`, `soft_deleted`, ...) and
# Publishable's `unpublished` / `scheduled` / `draft` leaked the same way.
describe "SoftDeletable and Publishable scopes merged into another model's relation" do
  before do
    ActiveRecord::Schema.define do
      create_table :smu_posts, force: true do |t|
        t.string :title
        t.datetime :deleted_at
        t.datetime :published_at
      end
      create_table :smu_comments, force: true do |t|
        t.integer :smu_post_id
        t.string :body
        t.datetime :deleted_at
        t.datetime :published_at
      end
    end
  end

  after do
    %i[smu_posts smu_comments].each do |table|
      ActiveRecord::Base.connection.drop_table(table, if_exists: true)
    end
  end

  describe "SoftDeletable" do
    before do
      stub_const("SmuComment", Class.new(TestModel) do
        self.table_name = "smu_comments"
        include ConcernsOnRails::Models::SoftDeletable

        belongs_to :smu_post, optional: true
      end)
      stub_const("SmuPost", Class.new(TestModel) do
        self.table_name = "smu_posts"
        include ConcernsOnRails::Models::SoftDeletable

        has_many :smu_comments
        has_many :all_comments, -> { with_deleted }, class_name: "SmuComment"
        has_many :trashed_comments, -> { only_deleted }, class_name: "SmuComment"
      end)
    end

    let!(:post) { SmuPost.create!(title: "a") }

    before do
      SmuComment.create!(smu_post: post, body: "live")
      SmuComment.create!(smu_post: post, body: "gone").soft_delete!
    end

    it "keeps the outer model's default scope when a relation of the model is merged in" do
      merged = SmuComment.joins(:smu_post).merge(SmuPost.where(title: "a"))

      expect(merged.pluck(:body)).to eq(["live"])
    end

    it "keeps the caller's own predicate on a same-named column of the outer model" do
      merged = SmuComment.with_deleted.where(deleted_at: nil).joins(:smu_post).merge(SmuPost.where(title: "a"))

      expect(merged.pluck(:body)).to eq(["live"])
    end

    it "records no unscope in the default scope, so a merge has nothing to replay" do
      expect(SmuPost.all.unscope_values).to eq([])
      expect(SmuPost.where(title: "a").unscope_values).to eq([])
    end

    # Rails 6.0 can unscope by column NAME only (any table), so there the named
    # scopes still peel by name and still leak through a merge.
    it "keeps the outer model's default scope when a with_deleted relation is merged in", min_rails: "6.1" do
      merged = SmuComment.joins(:smu_post).merge(SmuPost.with_deleted)

      expect(merged.pluck(:body)).to eq(["live"])
    end

    it "keeps the outer model's default scope when without_deleted / active are merged in", min_rails: "6.1" do
      expect(SmuComment.joins(:smu_post).merge(SmuPost.without_deleted).pluck(:body)).to eq(["live"])
      expect(SmuComment.joins(:smu_post).merge(SmuPost.active).pluck(:body)).to eq(["live"])
    end

    it "still peels the merged model's own default scope through with_deleted" do
      post.soft_delete!

      expect(SmuPost.where(title: "a").merge(SmuPost.with_deleted).count).to eq(1)
      expect(SmuPost.only_deleted.pluck(:title)).to eq(["a"])
      expect(SmuPost.only_deleted.without_deleted.count).to eq(0)
    end

    describe "has_many -> { with_deleted } (the association lambda is merged over the target's default scope)" do
      it "returns deleted and live children through the reader" do
        expect(post.all_comments.pluck(:body)).to match_array(%w[live gone])
        expect(post.trashed_comments.pluck(:body)).to eq(["gone"])
      end

      it "returns them through preload and eager_load" do
        expect(SmuPost.preload(:all_comments).first.all_comments.map(&:body)).to match_array(%w[live gone])
        expect(SmuPost.eager_load(:all_comments).first.all_comments.map(&:body)).to match_array(%w[live gone])
      end

      it "joins them" do
        expect(SmuPost.joins(:all_comments).count).to eq(2)
        expect(SmuPost.joins(:trashed_comments).count).to eq(1)
      end

      it "reaches them from a plain association with with_deleted" do
        expect(post.smu_comments.pluck(:body)).to eq(["live"])
        expect(post.smu_comments.with_deleted.pluck(:body)).to match_array(%w[live gone])
      end
    end
  end

  describe "Publishable" do
    before do
      stub_const("SmuComment", Class.new(TestModel) do
        self.table_name = "smu_comments"
        include ConcernsOnRails::Models::Publishable

        belongs_to :smu_post, optional: true
      end)
      stub_const("SmuPost", Class.new(TestModel) do
        self.table_name = "smu_posts"
        include ConcernsOnRails::Models::Publishable

        has_many :smu_comments
        publishable_by :published_at
      end)
    end

    let!(:post) { SmuPost.create!(title: "a") }

    before do
      SmuComment.create!(smu_post: post, body: "pub", published_at: 1.day.ago)
      SmuComment.create!(smu_post: post, body: "draft")
    end

    it "keeps the outer model's predicate on its own published_at when a negative scope is merged in", min_rails: "6.1" do
      base = SmuComment.where.not(published_at: nil).joins(:smu_post)

      expect(base.merge(SmuPost.draft).pluck(:body)).to eq(["pub"])
      expect(base.merge(SmuPost.unpublished).pluck(:body)).to eq(["pub"])
      SmuPost.update_all(published_at: 1.day.from_now)
      expect(base.merge(SmuPost.scheduled).pluck(:body)).to eq(["pub"])
    end

    it "still lets an association lambda reach drafts hidden by the target's default_scope: true" do
      SmuComment.publishable_by :published_at, default_scope: true
      SmuPost.has_many :draft_comments, -> { draft }, class_name: "SmuComment"

      expect(post.smu_comments.pluck(:body)).to eq(["pub"])
      expect(post.draft_comments.pluck(:body)).to eq(["draft"])
      expect(SmuPost.joins(:draft_comments).count).to eq(1)
    end
  end
end
