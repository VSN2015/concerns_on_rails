require "spec_helper"

# Audit 2026-10-10 (STATE-2): SoftDeletable documents `destroy_all` as
# soft-deleting, but only the bare class method was overridden.
# ActiveRecord::Relation defines its own destroy_all, so the usual scoped
# forms — `Post.where(...).destroy_all`, `post.comments.destroy_all`,
# `Post.destroy_by(...)` — destroyed each row: a HARD delete of the rows the
# caller meant to put in the trash. They now soft-delete too.
describe "SoftDeletable destroy_all on a relation or an association" do
  before do
    ActiveRecord::Schema.define do
      create_table :srd_posts, force: true do |t|
        t.string :type
        t.string :title
        t.datetime :deleted_at
      end
      create_table :srd_comments, force: true do |t|
        t.integer :srd_post_id
        t.string :body
        t.datetime :deleted_at
      end
      create_table :srd_users, force: true
      create_table :srd_groups, force: true do |t|
        t.datetime :deleted_at
      end
      create_table :srd_memberships, force: true do |t|
        t.integer :srd_user_id
        t.integer :srd_group_id
        t.datetime :deleted_at
      end
    end

    stub_const("SrdComment", Class.new(TestModel) do
      self.table_name = "srd_comments"
      include ConcernsOnRails::SoftDeletable

      belongs_to :srd_post, optional: true
    end)
    stub_const("SrdPost", Class.new(TestModel) do
      self.table_name = "srd_posts"
      include ConcernsOnRails::SoftDeletable

      has_many :srd_comments
    end)
  end

  after do
    %i[srd_posts srd_comments srd_users srd_groups srd_memberships].each do |table|
      ActiveRecord::Base.connection.drop_table(table, if_exists: true)
    end
  end

  it "soft-deletes through a relation's destroy_all" do
    SrdPost.create!(title: "a")
    SrdPost.create!(title: "b")

    SrdPost.where(title: "a").destroy_all

    expect(SrdPost.unscoped.count).to eq(2)
    expect(SrdPost.only_deleted.pluck(:title)).to eq(["a"])
    expect(SrdPost.pluck(:title)).to eq(["b"])
  end

  it "resets a loaded relation, as Relation#destroy_all does" do
    SrdPost.create!(title: "a")
    relation = SrdPost.where(title: "a")
    expect(relation.to_a.size).to eq(1)

    relation.destroy_all

    expect(relation.to_a).to eq([])
  end

  it "soft-deletes through an association's destroy_all and resets the loaded association" do
    post = SrdPost.create!(title: "a")
    post.srd_comments.create!(body: "x")
    post.srd_comments.create!(body: "y")
    expect(post.srd_comments.to_a.size).to eq(2)

    post.srd_comments.destroy_all

    expect(SrdComment.unscoped.count).to eq(2)
    expect(SrdComment.only_deleted.count).to eq(2)
    expect(post.srd_comments.to_a).to eq([])
  end

  it "soft-deletes through a scoped association relation and destroy_by" do
    post = SrdPost.create!(title: "a")
    post.srd_comments.create!(body: "x")
    post.srd_comments.create!(body: "y")
    SrdPost.create!(title: "gone")

    post.srd_comments.where(body: "x").destroy_all
    SrdPost.destroy_by(title: "gone")

    expect(SrdComment.only_deleted.pluck(:body)).to eq(["x"])
    expect(SrdPost.only_deleted.pluck(:title)).to eq(["gone"])
    expect(SrdPost.unscoped.count).to eq(2)
  end

  it "returns the records it soft-deleted, as ActiveRecord's Relation#destroy_all returns its records" do
    first = SrdPost.create!(title: "a")
    SrdPost.create!(title: "b").soft_delete!

    result = SrdPost.with_deleted.destroy_all

    expect(result).to eq([first])
    expect(result.first).to be_deleted
    expect(result.first).not_to be_destroyed
  end

  it "keeps in_batches.destroy_all working (and soft-deleting)" do
    3.times { |i| SrdPost.create!(title: "p#{i}") }

    expect { SrdPost.in_batches(of: 2).destroy_all }.not_to raise_error
    expect(SrdPost.unscoped.count).to eq(3)
    expect(SrdPost.count).to eq(0)
  end

  it "soft-deletes on an STI subclass's relation too" do
    stub_const("SrdPage", Class.new(SrdPost))
    SrdPage.create!(title: "page")

    SrdPage.where(title: "page").destroy_all

    expect(SrdPost.unscoped.count).to eq(1)
    expect(SrdPage.only_deleted.count).to eq(1)
  end

  it "keeps the class-level destroy_all returning the Integer count" do
    2.times { SrdPost.create!(title: "a") }

    expect(SrdPost.destroy_all).to eq(2)
  end

  it "still hard-deletes through really_destroy_all" do
    SrdPost.create!(title: "a")
    SrdPost.create!(title: "b")

    SrdPost.where(title: "a").really_destroy_all

    expect(SrdPost.unscoped.pluck(:title)).to eq(["b"])
  end

  it "leaves has_many dependent: :destroy as Rails does it (children hard-deleted)" do
    stub_const("SrdOwner", Class.new(TestModel) do
      self.table_name = "srd_posts"
      has_many :srd_comments, foreign_key: :srd_post_id, dependent: :destroy
    end)
    owner = SrdOwner.create!(title: "a")
    SrdComment.create!(srd_post_id: owner.id)

    owner.destroy

    expect(SrdComment.unscoped.count).to eq(0)
  end

  describe "has_many :through" do
    before do
      stub_const("SrdMembership", Class.new(TestModel) do
        self.table_name = "srd_memberships"
        include ConcernsOnRails::SoftDeletable

        belongs_to :srd_user
        belongs_to :srd_group
      end)
      stub_const("SrdGroup", Class.new(TestModel) do
        self.table_name = "srd_groups"
        include ConcernsOnRails::SoftDeletable
      end)
      stub_const("SrdUser", Class.new(TestModel) do
        self.table_name = "srd_users"
        has_many :srd_memberships
        has_many :srd_groups, through: :srd_memberships
      end)
    end

    it "removes the link (the join rows) on the through association's destroy_all, never the targets" do
      user = SrdUser.create!
      2.times { SrdMembership.create!(srd_user: user, srd_group: SrdGroup.create!) }

      user.srd_groups.destroy_all

      expect(SrdGroup.count).to eq(2)
      expect(SrdMembership.count).to eq(0)
      # The join model is soft-deletable, so its rows go to the trash.
      expect(SrdMembership.only_deleted.count).to eq(2)
      expect(user.reload.srd_groups.to_a).to eq([])
    end

    it "keeps the through association's destroy(record) working with a soft-deletable join model" do
      user = SrdUser.create!
      group = SrdGroup.create!
      SrdMembership.create!(srd_user: user, srd_group: group)

      expect { user.srd_groups.destroy(group) }.not_to raise_error
      expect(SrdGroup.count).to eq(1)
      expect(user.reload.srd_groups.to_a).to eq([])
    end
  end
end
