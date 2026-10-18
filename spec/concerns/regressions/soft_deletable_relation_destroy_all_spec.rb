require "spec_helper"

# Audit 2026-10-10 (STATE-2): SoftDeletable documents `destroy_all` as
# soft-deleting, but only the bare class method was overridden.
# ActiveRecord::Relation defines its own destroy_all, so the usual scoped
# forms — `Post.where(...).destroy_all`, `post.comments.destroy_all`,
# `Post.destroy_by(...)` — destroyed each row: a HARD delete of the rows the
# caller meant to put in the trash. They now soft-delete too ("contextual soft
# delete"): app-initiated relation / association destroy_all soft-deletes live
# rows and hard-deletes already-trashed ones; Rails' OWN association
# maintenance (has_many :through removing links) keeps hard-deleting; and
# `relation_destroy_all: :hard` opts a model out.
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
      # Real foreign keys (SQLite enforces them, as do PostgreSQL and MySQL), so a
      # join row that is soft-deleted instead of removed blocks its owner's delete.
      create_table :srd_memberships, force: true do |t|
        t.references :srd_user, foreign_key: true
        t.references :srd_group, foreign_key: true
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
    %i[srd_memberships srd_posts srd_comments srd_users srd_groups].each do |table|
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

  it "returns the records it acted on, as ActiveRecord's Relation#destroy_all returns its records" do
    first = SrdPost.create!(title: "a")
    second = SrdPost.create!(title: "b")

    result = SrdPost.where(id: [first.id, second.id]).destroy_all

    expect(result).to eq([first, second])
    expect(result).to all(be_deleted)
    expect(result).to all(satisfy { |record| !record.destroyed? })
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

  describe "contextual soft delete: already-trashed rows are hard-deleted" do
    it "purges the trash through only_deleted.destroy_all (no longer a silent no-op)" do
      SrdPost.create!(title: "live")
      SrdPost.create!(title: "trash").soft_delete!

      SrdPost.only_deleted.destroy_all

      expect(SrdPost.unscoped.pluck(:title)).to eq(["live"])
    end

    it "purges only the trash inside deleted_within" do
      SrdPost.create!(title: "live")
      SrdPost.create!(title: "recent").soft_delete!
      SrdPost.create!(title: "old").soft_delete!(at: 40.days.ago)

      SrdPost.deleted_within(7.days).destroy_all

      expect(SrdPost.unscoped.pluck(:title)).to contain_exactly("live", "old")
    end

    it "soft-deletes the live rows and hard-deletes the trashed rows of a mixed relation" do
      live = SrdPost.create!(title: "live")
      trash = SrdPost.create!(title: "trash")
      trash.soft_delete!

      result = SrdPost.with_deleted.destroy_all

      expect(SrdPost.unscoped.pluck(:title)).to eq(["live"])
      expect(SrdPost.only_deleted.pluck(:title)).to eq(["live"])
      expect(result.map(&:id)).to contain_exactly(live.id, trash.id)
      expect(result.find { |r| r.id == trash.id }).to be_destroyed
    end

    it "runs Rails' own destroy (dependent: :destroy children included) on a trashed row it purges" do
      stub_const("SrdOwner", Class.new(TestModel) do
        self.table_name = "srd_posts"
        include ConcernsOnRails::SoftDeletable

        has_many :srd_comments, foreign_key: :srd_post_id, dependent: :destroy
      end)
      owner = SrdOwner.create!(title: "a")
      SrdComment.create!(srd_post_id: owner.id)
      owner.soft_delete!

      SrdOwner.only_deleted.destroy_all

      expect(SrdOwner.unscoped.count).to eq(0)
      expect(SrdComment.unscoped.count).to eq(0)
    end

    it "leaves a vetoed hard delete in place, as ActiveRecord's destroy_all does, and returns the rest" do
      stub_const("SrdPicky", Class.new(TestModel) do
        self.table_name = "srd_posts"
        include ConcernsOnRails::SoftDeletable

        before_destroy { throw :abort if title == "keep" }
      end)
      SrdPicky.create!(title: "keep").soft_delete!
      SrdPicky.create!(title: "purge").soft_delete!

      result = SrdPicky.only_deleted.destroy_all

      expect(SrdPicky.unscoped.pluck(:title)).to eq(["keep"])
      expect(result.map(&:title)).to eq(["purge"])
    end

    it "leaves instance destroy as Rails' own hard delete" do
      post = SrdPost.create!(title: "a")

      post.destroy

      expect(SrdPost.unscoped.count).to eq(0)
    end
  end

  describe "an association's destroy_all" do
    before do
      stub_const("SrdCommentTracked", Class.new(TestModel) do
        self.table_name = "srd_comments"
        include ConcernsOnRails::SoftDeletable

        belongs_to :srd_post, optional: true
      end)
      stub_const("SrdTracker", Class.new(TestModel) do
        self.table_name = "srd_posts"
        include ConcernsOnRails::SoftDeletable

        attr_reader :log

        has_many :srd_comments, class_name: "SrdCommentTracked", foreign_key: :srd_post_id,
                                before_remove: ->(owner, c) { owner.note("before #{c.body}") },
                                after_remove: ->(owner, c) { owner.note("after #{c.body}") }

        def note(entry)
          (@log ||= []) << entry
        end
      end)
    end

    it "runs before_remove / after_remove for each record, as Rails' proxy destroy_all does" do
      tracker = SrdTracker.create!(title: "t")
      tracker.srd_comments.create!(body: "x")
      tracker.srd_comments.create!(body: "y")

      tracker.srd_comments.destroy_all

      expect(tracker.log).to eq(["before x", "before y", "after x", "after y"])
      expect(SrdCommentTracked.only_deleted.count).to eq(2)
    end

    it "marks the loaded instances deleted: they are the objects it acts on" do
      tracker = SrdTracker.create!(title: "t")
      tracker.srd_comments.create!(body: "x")
      loaded = tracker.srd_comments.to_a

      tracker.srd_comments.destroy_all

      expect(loaded).to all(be_deleted)
      expect(tracker.srd_comments.to_a).to eq([])
    end

    it "does nothing, as Rails does, when before_remove throws :abort" do
      stub_const("SrdVetoer", Class.new(TestModel) do
        self.table_name = "srd_posts"
        include ConcernsOnRails::SoftDeletable

        has_many :srd_comments, class_name: "SrdCommentTracked", foreign_key: :srd_post_id,
                                before_remove: ->(_owner, _c) { throw :abort }
      end)
      vetoer = SrdVetoer.create!(title: "t")
      vetoer.srd_comments.create!(body: "x")

      vetoer.srd_comments.destroy_all

      expect(SrdCommentTracked.unscoped.where(deleted_at: nil).count).to eq(1)
    end

    it "rolls the batch back when a record cannot be soft-deleted" do
      stub_const("SrdStrictComment", Class.new(TestModel) do
        self.table_name = "srd_comments"
        include ConcernsOnRails::SoftDeletable

        validates :body, exclusion: { in: ["bad"] }
      end)
      stub_const("SrdStrictPost", Class.new(TestModel) do
        self.table_name = "srd_posts"
        has_many :srd_comments, class_name: "SrdStrictComment", foreign_key: :srd_post_id
      end)
      post = SrdStrictPost.create!(title: "t")
      SrdStrictComment.create!(srd_post_id: post.id, body: "ok")
      SrdStrictComment.where(srd_post_id: post.id).update_all(body: "bad")
      SrdStrictComment.create!(srd_post_id: post.id, body: "fine")

      expect { post.srd_comments.destroy_all }.to raise_error(ActiveRecord::RecordNotSaved)
      expect(SrdStrictComment.unscoped.where.not(deleted_at: nil).count).to eq(0)
    end
  end

  describe "a loaded relation's destroy_all" do
    it "marks the loaded instances (they are the objects it acts on)" do
      SrdPost.create!(title: "a")
      relation = SrdPost.where(title: "a")
      loaded = relation.to_a

      relation.destroy_all

      expect(loaded.first).to be_deleted
    end
  end

  describe "soft_deletable_by relation_destroy_all: :hard (the escape hatch)" do
    before do
      stub_const("SrdHardComment", Class.new(TestModel) do
        self.table_name = "srd_comments"
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :deleted_at, relation_destroy_all: :hard
      end)
      stub_const("SrdHardPost", Class.new(TestModel) do
        self.table_name = "srd_posts"
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :deleted_at, relation_destroy_all: :hard
        has_many :srd_comments, class_name: "SrdHardComment", foreign_key: :srd_post_id
      end)
    end

    it "hard-deletes through a relation's destroy_all, as before the fix" do
      SrdHardPost.create!(title: "a")
      SrdHardPost.create!(title: "b")

      SrdHardPost.where(title: "a").destroy_all

      expect(SrdHardPost.unscoped.pluck(:title)).to eq(["b"])
    end

    it "hard-deletes through an association's destroy_all" do
      post = SrdHardPost.create!(title: "a")
      post.srd_comments.create!(body: "x")

      post.srd_comments.destroy_all

      expect(SrdHardComment.unscoped.count).to eq(0)
    end

    it "keeps the class-level destroy_all and soft_delete_all soft" do
      SrdHardPost.create!(title: "a")

      expect(SrdHardPost.destroy_all).to eq(1)
      expect(SrdHardPost.unscoped.count).to eq(1)
      expect(SrdHardPost.only_deleted.count).to eq(1)
    end

    it "is inherited by an STI subclass and overridable there" do
      stub_const("SrdHardPage", Class.new(SrdHardPost))
      stub_const("SrdSoftPage", Class.new(SrdHardPost) { soft_deletable_by :deleted_at })
      SrdHardPage.create!(title: "hard")
      SrdSoftPage.create!(title: "soft")

      SrdHardPage.where(title: "hard").destroy_all
      SrdSoftPage.where(title: "soft").destroy_all

      expect(SrdHardPost.unscoped.pluck(:title)).to eq(["soft"])
      expect(SrdHardPost.only_deleted.pluck(:title)).to eq(["soft"])
    end

    it "defaults to :soft and rejects anything but :soft / :hard at macro time" do
      expect(SrdPost.soft_delete_relation_destroy_all).to eq(:soft)
      expect(SrdHardPost.soft_delete_relation_destroy_all).to eq(:hard)
      expect { SrdPost.soft_deletable_by :deleted_at, relation_destroy_all: :nope }
        .to raise_error(ArgumentError, /relation_destroy_all/)
      expect { SrdPost.soft_deletable_by :deleted_at, relation_destroy_all: "hard" }
        .to raise_error(ArgumentError, /relation_destroy_all/)
    end
  end

  describe "has_many :through (Rails' own association maintenance keeps Rails semantics)" do
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
        has_many :srd_groups, through: :srd_memberships, dependent: :destroy
      end)
    end

    def member!(user, group = SrdGroup.create!)
      SrdMembership.create!(srd_user: user, srd_group: group)
      group
    end

    it "hard-deletes the join rows when the owner is destroyed (through:, dependent: :destroy)" do
      user = SrdUser.create!
      2.times { member!(user) }

      expect { user.destroy }.not_to raise_error

      expect(SrdUser.count).to eq(0)
      expect(SrdMembership.unscoped.count).to eq(0)
      expect(SrdGroup.count).to eq(2)
    end

    it "hard-deletes the join row on user.groups.destroy(group)" do
      user = SrdUser.create!
      group = member!(user)
      member!(user)

      user.srd_groups.destroy(group)

      expect(SrdMembership.unscoped.count).to eq(1)
      expect(user.reload.srd_groups.to_a.size).to eq(1)
      expect(SrdGroup.count).to eq(2)
    end

    it "hard-deletes the join rows on the through association's destroy_all, never the targets" do
      user = SrdUser.create!
      2.times { member!(user) }

      user.srd_groups.destroy_all

      expect(SrdGroup.count).to eq(2)
      expect(SrdMembership.unscoped.count).to eq(0)
      expect(user.reload.srd_groups.to_a).to eq([])
    end

    it "soft-deletes join rows again for an app-initiated destroy_all outside Rails' association maintenance" do
      user = SrdUser.create!
      member!(user)

      SrdMembership.where(srd_user_id: user.id).destroy_all

      expect(SrdMembership.only_deleted.count).to eq(1)
    end

    it "does not leak the hard context out of the maintenance call (even when it raises)" do
      user = SrdUser.create!
      member!(user)
      allow_any_instance_of(ActiveRecord::Associations::HasManyThroughAssociation)
        .to receive(:delete_through_records).and_raise("boom")

      expect { user.srd_groups.destroy_all }.to raise_error("boom")

      expect(ConcernsOnRails::Support::ContextualDestroy.hard?(SrdMembership)).to be(false)
      SrdMembership.create!(srd_user: user, srd_group: SrdGroup.create!)
      SrdMembership.where(srd_user_id: user.id).destroy_all
      expect(SrdMembership.only_deleted.count).to be >= 1
    end
  end

  describe "a soft-deleted parent does not trigger dependent: :destroy (documented: use cascade:)" do
    it "leaves the children of a relation-form-deleted parent live" do
      stub_const("SrdOwner", Class.new(TestModel) do
        self.table_name = "srd_posts"
        include ConcernsOnRails::SoftDeletable

        has_many :srd_comments, foreign_key: :srd_post_id, dependent: :destroy
      end)
      owner = SrdOwner.create!(title: "a")
      SrdComment.create!(srd_post_id: owner.id)

      SrdOwner.where(id: owner.id).destroy_all

      expect(SrdOwner.only_deleted.count).to eq(1)
      expect(SrdComment.count).to eq(1)
    end
  end
end
