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
      create_table :srd_nodes, force: true do |t|
        t.integer :parent_id
        t.string :title
        t.datetime :deleted_at
      end
      create_table :srd_parents, force: true do |t|
        t.datetime :deleted_at
      end
      # A real foreign key: a child row left behind blocks its parent's DELETE.
      create_table :srd_children, force: true do |t|
        t.references :srd_parent, foreign_key: true
        t.datetime :deleted_at
      end
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
    %i[srd_memberships srd_children srd_parents srd_nodes srd_posts srd_comments srd_users srd_groups
       srd_cyc_users srd_cyc_teams srd_replies].each do |table|
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

  # Review round 2 (PR #169): WHICH relations may purge the trash, and WHEN the
  # trashed set is decided.
  describe "purging is opt-in: only the gem's trash scopes reach the trash" do
    before do
      stub_const("SrdOpenComment", Class.new(TestModel) do
        self.table_name = "srd_comments"
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :deleted_at, default_scope: false
        belongs_to :srd_open_post, foreign_key: :srd_post_id, optional: true
      end)
      stub_const("SrdOpenPost", Class.new(TestModel) do
        self.table_name = "srd_posts"
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :deleted_at, default_scope: false
        has_many :srd_comments, class_name: "SrdOpenComment", foreign_key: :srd_post_id
        has_many :every_comment, -> { with_deleted }, class_name: "SrdOpenComment", foreign_key: :srd_post_id
        has_many :trashed_comments, -> { only_deleted }, class_name: "SrdOpenComment", foreign_key: :srd_post_id
      end)
    end

    def trash!(klass, **attrs)
      klass.create!(**attrs).tap { |record| record.soft_delete!(at: 3.days.ago) }
    end

    it "leaves the trash alone for a scoped relation on a default_scope: false model (where, all, destroy_by)" do
      live = SrdOpenPost.create!(title: "a")
      trash = trash!(SrdOpenPost, title: "a")
      stamp = SrdOpenPost.find(trash.id).deleted_at

      SrdOpenPost.where(title: "a").destroy_all
      SrdOpenPost.all.destroy_all
      SrdOpenPost.destroy_by(title: "a")

      expect(SrdOpenPost.unscoped.count).to eq(2)
      expect(SrdOpenPost.find(live.id)).to be_deleted
      expect(SrdOpenPost.find(trash.id).deleted_at).to eq(stamp)
    end

    it "leaves the trash alone for an association's destroy_all and its scoped relation" do
      post = SrdOpenPost.create!(title: "p")
      live = post.srd_comments.create!(body: "x")
      trash = trash!(SrdOpenComment, srd_post_id: post.id, body: "x")

      post.srd_comments.where(body: "x").destroy_all
      post.srd_comments.destroy_all

      expect(SrdOpenComment.unscoped.count).to eq(2)
      expect(SrdOpenComment.find(live.id)).to be_deleted
      expect(SrdOpenComment.find(trash.id).deleted_at).to be_within(1.minute).of(3.days.ago)
    end

    it "leaves the trash alone for unscoped on a default_scope model" do
      SrdPost.create!(title: "live")
      SrdPost.create!(title: "trash").soft_delete!

      SrdPost.unscoped.destroy_all
      SrdPost.unscoped.where(title: "trash").destroy_all

      expect(SrdPost.unscoped.count).to eq(2)
    end

    {
      only_deleted: :only_deleted.to_proc,
      soft_deleted: :soft_deleted.to_proc,
      deleted_within: ->(klass) { klass.deleted_within(7.days) },
      with_deleted: :with_deleted.to_proc
    }.each do |name, build|
      it "purges the trash through #{name}, however it is chained, merged or ordered" do
        live = SrdOpenPost.create!(title: "live")
        2.times { trash!(SrdOpenPost, title: "trash") }

        build.call(SrdOpenPost).where(title: "trash").order(:id).destroy_all
        expect(SrdOpenPost.unscoped.pluck(:title)).to eq(["live"]) if name != :with_deleted
        SrdOpenPost.unscoped.where.not(id: live.id).delete_all
        2.times { trash!(SrdOpenPost, title: "trash") }

        SrdOpenPost.where(title: "trash").merge(build.call(SrdOpenPost)).destroy_all
        expect(SrdOpenPost.unscoped.where(title: "trash").count).to eq(0)
        trash!(SrdOpenPost, title: "trash")

        build.call(SrdOpenPost).merge(SrdOpenPost.where(title: "trash")).unscope(:order).destroy_all
        expect(SrdOpenPost.unscoped.where(title: "trash").count).to eq(0)
      end
    end

    it "purges through an association declared with a trash scope" do
      post = SrdOpenPost.create!(title: "p")
      post.srd_comments.create!(body: "live")
      2.times { trash!(SrdOpenComment, srd_post_id: post.id, body: "trash") }

      post.trashed_comments.destroy_all

      expect(SrdOpenComment.unscoped.pluck(:body)).to eq(["live"])

      2.times { trash!(SrdOpenComment, srd_post_id: post.id, body: "trash") }
      post.every_comment.where(body: "trash").destroy_all

      expect(SrdOpenComment.unscoped.pluck(:body)).to eq(["live"])
    end

    it "purges through an association's trash scope (post.comments.only_deleted)" do
      post = SrdOpenPost.create!(title: "p")
      trash!(SrdOpenComment, srd_post_id: post.id, body: "trash")

      post.srd_comments.only_deleted.destroy_all

      expect(SrdOpenComment.unscoped.count).to eq(0)
    end

    it "honours renamed (affixed) trash scopes" do
      stub_const("SrdArchived", Class.new(TestModel) do
        self.table_name = "srd_posts"
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :deleted_at, prefix: :arch, default_scope: false
      end)
      SrdArchived.create!(title: "live")
      trash!(SrdArchived, title: "trash")
      names = SrdArchived.soft_delete_scope_names
      expect(names[:only_deleted]).to eq(:arch_only_deleted)

      SrdArchived.where(title: "trash").destroy_all
      expect(SrdArchived.unscoped.count).to eq(2)

      SrdArchived.public_send(names[:only_deleted]).destroy_all
      expect(SrdArchived.unscoped.pluck(:title)).to eq(["live"])
    end

    # Review round 3: Relation#merge copies the OTHER relation's `extending`
    # modules (Merger#merge_multi_values), so one global marker let
    # `Post.joins(:comments).merge(Comment.only_deleted)` purge trashed POSTS.
    # The tag is per model now: only this model's own trash scope counts.
    it "does not let the trash scope of ANOTHER model's relation mark this one" do
      live = SrdOpenPost.create!(title: "live")
      trash!(SrdOpenComment, srd_post_id: live.id, body: "c1")
      trashed = trash!(SrdOpenPost, title: "trashed")
      trash!(SrdOpenComment, srd_post_id: trashed.id, body: "c2")
      relation = SrdOpenPost.joins(:srd_comments).merge(SrdOpenComment.only_deleted)
      expect(relation.pluck(:id)).to contain_exactly(live.id, trashed.id)

      relation.destroy_all

      expect(SrdOpenPost.unscoped.pluck(:id)).to contain_exactly(live.id, trashed.id)
      expect(SrdOpenPost.find(trashed.id).deleted_at).to be_within(1.minute).of(3.days.ago)
      expect(SrdOpenPost.find(live.id)).to be_deleted
      expect(SrdOpenComment.unscoped.count).to eq(2)
    end

    it "does not let this model's trash scope, merged into ANOTHER model's relation, purge that model's trash" do
      post = trash!(SrdOpenPost, title: "trashed")
      comment = trash!(SrdOpenComment, srd_post_id: post.id, body: "trashed")

      SrdOpenComment.joins(:srd_open_post).merge(SrdOpenPost.only_deleted).destroy_all

      expect(SrdOpenComment.unscoped.pluck(:id)).to eq([comment.id])
      expect(SrdOpenPost.unscoped.pluck(:id)).to eq([post.id])
    end

    it "does not let another model's trash scope purge a default-scoped model's trash either" do
      trashed = SrdPost.create!(title: "trashed")
      SrdComment.create!(srd_post_id: trashed.id, body: "c")
      trashed.soft_delete!
      SrdComment.unscoped.update_all(deleted_at: Time.zone.now)

      # A string join: `joins(:srd_comments)` puts the comments' default scope
      # into the ON clause, which would leave the join empty.
      relation = SrdPost.joins("INNER JOIN srd_comments ON srd_comments.srd_post_id = srd_posts.id")
                        .merge(SrdComment.only_deleted)

      relation.destroy_all

      expect(SrdPost.unscoped.pluck(:id)).to eq([trashed.id])
    end

    it "still purges through a merge of THIS model's (or its STI base's) trash scope" do
      trash!(SrdOpenPost, title: "trashed")
      stub_const("SrdOpenPage", Class.new(SrdOpenPost))
      page = SrdOpenPage.create!(title: "page").tap { |record| record.soft_delete!(at: 3.days.ago) }

      SrdOpenPost.where(title: "trashed").merge(SrdOpenPost.only_deleted).destroy_all
      expect(SrdOpenPost.unscoped.pluck(:id)).to eq([page.id])

      SrdOpenPage.all.merge(SrdOpenPost.only_deleted).destroy_all
      expect(SrdOpenPost.unscoped.count).to eq(0)
    end
  end

  describe "the trashed set is decided when the call starts" do
    before do
      stub_const("SrdNode", Class.new(TestModel) do
        self.table_name = "srd_nodes"
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :deleted_at, default_scope: false
        has_many :children, class_name: "SrdNode", foreign_key: :parent_id
        soft_deletable_by :deleted_at, default_scope: false, cascade: [:children]
      end)
    end

    # find_each loads 1000 rows a batch: a child cascaded in batch 1 used to be
    # loaded as "already trashed" by batch 2 and hard-destroyed (a small table
    # only re-stamped it), so the outcome depended on the batch size.
    it "never purges a row that THIS call soft-deleted, whatever the batch size" do
      root = SrdNode.create!(title: "root")
      SrdNode.insert_all(Array.new(1100) { |i| { parent_id: root.id, title: "c#{i}", deleted_at: nil } })

      SrdNode.with_deleted.destroy_all

      expect(SrdNode.unscoped.count).to eq(1101)
      expect(SrdNode.unscoped.where(deleted_at: nil).count).to eq(0)
    end

    it "purges only the rows trashed before the call (a mixed relation with a cascade)" do
      root = SrdNode.create!(title: "root")
      child = SrdNode.create!(title: "child", parent_id: root.id)
      old = SrdNode.create!(title: "old")
      old.soft_delete!(at: 2.days.ago)

      SrdNode.with_deleted.destroy_all

      expect(SrdNode.unscoped.pluck(:title)).to contain_exactly("root", "child")
      expect(SrdNode.unscoped.where(deleted_at: nil).count).to eq(0)
      expect(child.reload).to be_deleted
    end

    it "does not purge a row a hook trashed earlier in the call" do
      stub_const("SrdHooked", Class.new(TestModel) do
        self.table_name = "srd_nodes"
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :deleted_at, default_scope: false
        def after_soft_delete
          self.class.unscoped.where(title: "victim").update_all(deleted_at: Time.zone.now)
        end
      end)
      SrdHooked.create!(title: "a")
      SrdHooked.create!(title: "victim")

      SrdHooked.with_deleted.destroy_all

      expect(SrdHooked.unscoped.pluck(:title)).to contain_exactly("a", "victim")
    end

    it "decides a loaded relation's trashed set from the loaded records" do
      live = SrdNode.create!(title: "live")
      relation = SrdNode.with_deleted.where(title: "live")
      loaded = relation.to_a
      expect(loaded.map(&:id)).to eq([live.id])

      relation.destroy_all

      expect(SrdNode.unscoped.count).to eq(1)
      expect(loaded.first).to be_deleted
    end
  end

  describe "purging a trashed parent whose children were cascaded with it" do
    before do
      stub_const("SrdChild", Class.new(TestModel) do
        self.table_name = "srd_children"
        include ConcernsOnRails::SoftDeletable

        belongs_to :srd_parent
      end)
      stub_const("SrdParent", Class.new(TestModel) do
        self.table_name = "srd_parents"
        include ConcernsOnRails::SoftDeletable

        has_many :srd_children, dependent: :destroy
        soft_deletable_by :deleted_at, cascade: [:srd_children]
      end)
    end

    it "purges the cascaded (trashed) children first, so a real foreign key does not block the parent" do
      parent = SrdParent.create!
      2.times { SrdChild.create!(srd_parent: parent) }
      parent.soft_delete!
      expect(SrdChild.unscoped.where.not(deleted_at: nil).count).to eq(2)

      expect { SrdParent.only_deleted.destroy_all }.not_to raise_error

      expect(SrdParent.unscoped.count).to eq(0)
      expect(SrdChild.unscoped.count).to eq(0)
    end

    it "purges through with_deleted too (a mixed relation)" do
      parent = SrdParent.create!
      SrdChild.create!(srd_parent: parent)
      parent.soft_delete!

      SrdParent.with_deleted.where(id: parent.id).destroy_all

      expect(SrdParent.unscoped.count).to eq(0)
      expect(SrdChild.unscoped.count).to eq(0)
    end

    # Review round 3: a child trashed on its own (a different stamp) used to be
    # left out of the purge, so the parent's DELETE hit the foreign key. The
    # stamp only matters to restore!; a child of an erased parent cannot be
    # restored meaningfully, so every TRASHED cascade child is purged. Live
    # children stay Rails' `dependent:` business.
    it "purges a child that was trashed on its own (a different stamp) too" do
      parent = SrdParent.create!
      lone = SrdChild.create!(srd_parent: parent)
      lone.soft_delete!(at: 5.days.ago)
      SrdChild.create!(srd_parent: parent)
      parent.soft_delete!

      expect { SrdParent.only_deleted.destroy_all }.not_to raise_error

      expect(SrdParent.unscoped.count).to eq(0)
      expect(SrdChild.unscoped.count).to eq(0)
    end

    it "skips (and rolls back) a parent whose cascaded child vetoes its purge, and purges the rest" do
      keep = SrdParent.create!
      ok = SrdChild.create!(srd_parent: keep)
      vetoer_id = SrdChild.create!(srd_parent: keep).id
      SrdChild.class_eval { before_destroy { throw :abort if id == vetoer_id } }
      keep.soft_delete!
      gone = SrdParent.create!
      SrdChild.create!(srd_parent: gone)
      gone.soft_delete!

      result = nil
      expect { result = SrdParent.only_deleted.destroy_all }.not_to raise_error

      expect(result.map(&:id)).to eq([gone.id])
      expect(SrdParent.unscoped.pluck(:id)).to eq([keep.id])
      expect(SrdChild.unscoped.where(srd_parent_id: keep.id).pluck(:id)).to include(ok.id)
      expect(SrdChild.unscoped.where(srd_parent_id: keep.id).count).to eq(2)
    end

    it "raises RecordNotDestroyed on an association purge whose cascaded child vetoes, as Rails' destroy! does" do
      stub_const("SrdParentHolder", Class.new(TestModel) do
        self.table_name = "srd_children"
        has_many :trashed_parents, -> { only_deleted }, class_name: "SrdParent", primary_key: :srd_parent_id,
                                                        foreign_key: :id
      end)
      SrdChild.class_eval { before_destroy { throw :abort } }
      parent = SrdParent.create!
      child = SrdChild.create!(srd_parent: parent)
      parent.soft_delete!

      expect { SrdParentHolder.find(child.id).trashed_parents.destroy_all }
        .to raise_error(ActiveRecord::RecordNotDestroyed)

      expect(SrdParent.unscoped.count).to eq(1)
      expect(SrdChild.unscoped.count).to eq(1)
    end

    # Round 3 re-review: AssociationScope.unfiltered keeps a has_one's LIMIT 1
    # (its reader's row), so only one trashed child was purged and the other
    # still held the foreign key.
    it "purges EVERY trashed child of a has_one cascade" do
      stub_const("SrdOneParent", Class.new(TestModel) do
        self.table_name = "srd_parents"
        include ConcernsOnRails::SoftDeletable

        has_one :srd_child, foreign_key: :srd_parent_id
        soft_deletable_by :deleted_at, cascade: [:srd_child]
      end)
      parent = SrdOneParent.create!
      SrdChild.create!(srd_parent_id: parent.id).soft_delete!(at: 5.days.ago)
      SrdChild.create!(srd_parent_id: parent.id)
      parent.soft_delete!
      expect(SrdChild.unscoped.where.not(deleted_at: nil).count).to eq(2)

      expect { SrdOneParent.only_deleted.destroy_all }.not_to raise_error

      expect(SrdOneParent.unscoped.count).to eq(0)
      expect(SrdChild.unscoped.count).to eq(0)
    end
  end

  # Round 3 re-review: the association form handled its targets in target
  # order, so a live record soft-deleted early in the call was then picked up
  # (now trashed) by a later trashed record's purge of its trashed cascade
  # children and hard-deleted. Trashed targets are purged first now, as the
  # relation form does.
  describe "an association destroy_all over a self-referential cascade" do
    before do
      ActiveRecord::Schema.define do
        create_table :srd_replies, force: true do |t|
          t.integer :srd_post_id
          t.integer :parent_id
          t.datetime :deleted_at
        end
      end
      stub_const("SrdReply", Class.new(TestModel) do
        self.table_name = "srd_replies"
        include ConcernsOnRails::SoftDeletable

        has_many :replies, class_name: "SrdReply", foreign_key: :parent_id
        soft_deletable_by :deleted_at, cascade: [:replies]
      end)
      stub_const("SrdThread", Class.new(TestModel) do
        self.table_name = "srd_posts"
        include ConcernsOnRails::SoftDeletable

        has_many :all_replies, -> { with_deleted.order(id: :desc) }, class_name: "SrdReply", foreign_key: :srd_post_id
      end)
    end

    it "never purges a live target it soft-deleted earlier in the call, whatever the target order" do
      thread = SrdThread.create!(title: "t")
      trashed = SrdReply.create!(srd_post_id: thread.id)
      trashed.soft_delete!(at: 2.days.ago)
      live = SrdReply.create!(srd_post_id: thread.id, parent_id: trashed.id)
      expect(thread.all_replies.map(&:id)).to eq([live.id, trashed.id])

      thread.all_replies.destroy_all

      expect(SrdReply.unscoped.pluck(:id)).to eq([live.id])
      expect(SrdReply.unscoped.find(live.id)).to be_deleted
    end
  end

  # Review round 3: each child is a fresh instance and its parent's row still
  # exists until the parent's own destroy, so a cascade cycle recursed until
  # SystemStackError (which escapes every savepoint).
  describe "purging through a cascade cycle" do
    it "purges a self-parented tree row once" do
      stub_const("SrdLoop", Class.new(TestModel) do
        self.table_name = "srd_nodes"
        include ConcernsOnRails::SoftDeletable

        has_many :children, class_name: "SrdLoop", foreign_key: :parent_id
        soft_deletable_by :deleted_at, cascade: [:children]
      end)
      node = SrdLoop.create!(title: "self")
      node.update_column(:parent_id, node.id)
      node.soft_delete!

      expect { SrdLoop.only_deleted.destroy_all }.not_to raise_error

      expect(SrdLoop.unscoped.count).to eq(0)
    end

    it "purges a two-model cycle (a user owning the team it is a member of)" do
      ActiveRecord::Schema.define do
        create_table :srd_cyc_users, force: true do |t|
          t.integer :team_id
          t.datetime :deleted_at
        end
        create_table :srd_cyc_teams, force: true do |t|
          t.integer :owner_id
          t.datetime :deleted_at
        end
      end
      stub_const("SrdCycTeam", Class.new(TestModel) do
        self.table_name = "srd_cyc_teams"
        include ConcernsOnRails::SoftDeletable
      end)
      stub_const("SrdCycUser", Class.new(TestModel) do
        self.table_name = "srd_cyc_users"
        include ConcernsOnRails::SoftDeletable

        has_many :owned_teams, class_name: "SrdCycTeam", foreign_key: :owner_id
        soft_deletable_by :deleted_at, cascade: [:owned_teams]
      end)
      SrdCycTeam.class_eval do
        has_many :members, class_name: "SrdCycUser", foreign_key: :team_id
        soft_deletable_by :deleted_at, cascade: [:members]
      end
      user = SrdCycUser.create!
      team = SrdCycTeam.create!(owner_id: user.id)
      user.update_column(:team_id, team.id)
      user.soft_delete!
      expect(SrdCycTeam.only_deleted.count).to eq(1)

      expect { SrdCycUser.only_deleted.destroy_all }.not_to raise_error

      expect(SrdCycUser.unscoped.count).to eq(0)
      expect(SrdCycTeam.unscoped.count).to eq(0)
    end
  end

  # Review round 3: the trashed set is fixed at the start, but a row can be
  # restored before its turn — a loaded relation's instances, or a stale copy
  # in a find_each batch. Each purge re-checks the row is still trashed.
  describe "a row restored before its purge" do
    it "is left alone by a loaded relation" do
      SrdPost.create!(title: "back").soft_delete!
      relation = SrdPost.only_deleted.load
      SrdPost.unscoped.update_all(deleted_at: nil)

      expect(relation.destroy_all).to eq([])

      expect(SrdPost.pluck(:title)).to eq(["back"])
    end

    it "is left alone by a streamed relation whose batch holds a stale copy" do
      stub_const("SrdRestorer", Class.new(TestModel) do
        self.table_name = "srd_posts"
        include ConcernsOnRails::SoftDeletable

        before_destroy { self.class.unscoped.where(title: "victim").update_all(deleted_at: nil) }
      end)
      SrdRestorer.create!(title: "a").soft_delete!
      SrdRestorer.create!(title: "victim").soft_delete!

      SrdRestorer.only_deleted.destroy_all

      expect(SrdRestorer.pluck(:title)).to eq(["victim"])
    end
  end

  describe "a loaded relation with duplicate rows" do
    it "soft-deletes each record once (no stale copy per joined row)" do
      stub_const("SrdCounted", Class.new(TestModel) do
        self.table_name = "srd_posts"
        include ConcernsOnRails::SoftDeletable

        has_many :srd_comments, foreign_key: :srd_post_id
        cattr_accessor(:stamped) { [] }

        def before_soft_delete
          self.class.stamped << id
        end
      end)
      post = SrdCounted.create!(title: "p")
      3.times { SrdComment.create!(srd_post_id: post.id) }
      relation = SrdCounted.joins(:srd_comments).load
      expect(relation.to_a.size).to eq(3)

      result = relation.destroy_all

      expect(SrdCounted.stamped).to eq([post.id])
      expect(result.map(&:id)).to eq([post.id])
    end
  end

  describe "an association destroy_all vetoed by before_remove" do
    it "returns nil, as ActiveRecord's own destroy_all does" do
      stub_const("SrdVetoPost", Class.new(TestModel) do
        self.table_name = "srd_posts"
        include ConcernsOnRails::SoftDeletable

        has_many :srd_comments, foreign_key: :srd_post_id, before_remove: ->(_owner, _c) { throw :abort }
      end)
      post = SrdVetoPost.create!(title: "t")
      post.srd_comments.create!(body: "x")

      expect(post.srd_comments.destroy_all).to be_nil
      expect(SrdComment.count).to eq(1)
    end

    it "returns the (empty) record list for an association with nothing to remove" do
      post = SrdPost.create!(title: "t")

      expect(post.srd_comments.destroy_all).to eq([])
    end
  end

  describe "a model that includes SoftDeletable AFTER its subclass was defined" do
    it "still soft-deletes through the subclass's relation" do
      stub_const("SrdEarlyBase", Class.new(TestModel) { self.table_name = "srd_posts" })
      stub_const("SrdEarlyChild", Class.new(SrdEarlyBase))
      SrdEarlyBase.include(ConcernsOnRails::SoftDeletable)
      SrdEarlyChild.create!(title: "kid")

      SrdEarlyChild.where(title: "kid").destroy_all

      expect(SrdEarlyBase.unscoped.count).to eq(1)
      expect(SrdEarlyBase.only_deleted.count).to eq(1)
    end
  end

  describe "a has_many :through with disable_joins: true", min_rails: "7.0" do
    it "soft-deletes through the relation without raising NoMethodError" do
      stub_const("SrdDjGroup", Class.new(TestModel) do
        self.table_name = "srd_groups"
        include ConcernsOnRails::SoftDeletable
      end)
      stub_const("SrdDjMembership", Class.new(TestModel) do
        self.table_name = "srd_memberships"
        belongs_to :srd_group, class_name: "SrdDjGroup"
      end)
      stub_const("SrdDjUser", Class.new(TestModel) do
        self.table_name = "srd_users"
        # An ORDERED through scope (and an unordered target) makes Rails hand back a
        # DisableJoinsAssociationRelation, whose #limit returns an Array.
        has_many :srd_dj_memberships, -> { order(:id) }, foreign_key: :srd_user_id
        has_many :srd_dj_groups, through: :srd_dj_memberships, source: :srd_group, disable_joins: true
      end)
      user = SrdDjUser.create!
      2.times { SrdDjMembership.create!(srd_user_id: user.id, srd_group_id: SrdDjGroup.create!.id) }

      relation = user.srd_dj_groups.where.not(id: nil)
      expect(relation).to be_a(ActiveRecord::DisableJoinsAssociationRelation)

      expect { relation.destroy_all }.not_to raise_error

      expect(SrdDjGroup.unscoped.count).to eq(2)
      expect(SrdDjGroup.only_deleted.count).to eq(2)
    end
  end

  describe "the hard context is one-shot (has_many :through maintenance)" do
    it "does not hard-delete a destroy_all issued by the join model's own callback" do
      stub_const("SrdGroup", Class.new(TestModel) do
        self.table_name = "srd_groups"
        include ConcernsOnRails::SoftDeletable
      end)
      stub_const("SrdMembership", Class.new(TestModel) do
        self.table_name = "srd_memberships"
        include ConcernsOnRails::SoftDeletable

        belongs_to :srd_user
        belongs_to :srd_group
        after_destroy { self.class.where(srd_user_id: nil).destroy_all }
      end)
      stub_const("SrdUser", Class.new(TestModel) do
        self.table_name = "srd_users"
        has_many :srd_memberships
        has_many :srd_groups, through: :srd_memberships, dependent: :destroy
      end)
      user = SrdUser.create!
      SrdMembership.create!(srd_user: user, srd_group: SrdGroup.create!)
      orphan = SrdMembership.create!(srd_user_id: nil, srd_group: SrdGroup.create!)

      user.destroy

      expect(SrdMembership.unscoped.pluck(:id)).to eq([orphan.id])
      expect(SrdMembership.only_deleted.pluck(:id)).to eq([orphan.id])
    end
  end

  describe "loader bookkeeping" do
    it "lists Support::ContextualDestroy among the loader's autoloads" do
      loader = File.read(File.expand_path("../../../lib/concerns_on_rails.rb", __dir__))

      expect(loader).to match(%r{autoload :ContextualDestroy,\s+"concerns_on_rails/support/contextual_destroy"})
    end
  end

  describe "association forms that stay Rails' own hard deletes (documented)" do
    before do
      stub_const("SrdDepPost", Class.new(TestModel) do
        self.table_name = "srd_posts"
        include ConcernsOnRails::SoftDeletable

        has_many :srd_comments, foreign_key: :srd_post_id, dependent: :destroy
        accepts_nested_attributes_for :srd_comments, allow_destroy: true
      end)
    end

    let(:post) { SrdDepPost.create!(title: "p") }

    it "hard-deletes through destroy(record) and delete(record) on a dependent: :destroy association" do
      keep = post.srd_comments.create!(body: "keep")
      gone = post.srd_comments.create!(body: "gone")
      dropped = post.srd_comments.create!(body: "dropped")

      post.srd_comments.destroy(gone)
      post.srd_comments.delete(dropped)

      expect(SrdComment.unscoped.pluck(:id)).to eq([keep.id])
    end

    it "hard-deletes through collection replace and nested-attributes _destroy" do
      keep = post.srd_comments.create!(body: "keep")
      post.srd_comments.create!(body: "replaced")
      post.srd_comments.replace([keep])
      expect(SrdComment.unscoped.pluck(:id)).to eq([keep.id])

      post.update!(srd_comments_attributes: [{ id: keep.id, _destroy: "1" }])

      expect(SrdComment.unscoped.count).to eq(0)
    end

    it "soft-deletes through post.srd_comments.soft_delete_all" do
      post.srd_comments.create!(body: "x")

      post.srd_comments.soft_delete_all

      expect(SrdComment.only_deleted.count).to eq(1)
    end
  end
end
