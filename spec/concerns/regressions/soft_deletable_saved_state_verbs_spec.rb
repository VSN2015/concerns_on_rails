require "spec_helper"

# Audit 2026-10-29 (STATE-12): 1.33.0 (#146) moved publish!/activate!/
# deactivate!/expire! to the SAVED state ("a stored record, no unsaved change
# to the column"), but soft_delete!/restore! still asked the in-memory stamp:
# `c.deleted_at = Time.current; c.soft_delete!` answered true while the row
# stayed live (no write, no hook, no cascade), and `c.deleted_at = nil;
# c.restore!` answered true while the row, and its cascaded children, stayed
# trashed. They now follow the same rule.
describe "SoftDeletable#soft_delete! / #restore! decide from the saved state" do
  before do
    ActiveRecord::Schema.define do
      create_table :ssv_posts, force: true do |t|
        t.string :title
        t.datetime :deleted_at, precision: 6
        t.timestamps null: false
      end
      create_table :ssv_comments, force: true do |t|
        t.integer :ssv_post_id
        t.string :body
        t.datetime :deleted_at, precision: 6
      end
    end
  end

  after do
    %i[ssv_posts ssv_comments].each { |t| ActiveRecord::Base.connection.drop_table(t, if_exists: true) }
  end

  let(:hooks) { %i[before_soft_delete after_soft_delete before_restore after_restore] }
  let(:comment_model) do
    Class.new(TestModel) do
      self.table_name = "ssv_comments"
      include ConcernsOnRails::SoftDeletable

      soft_deletable_by :deleted_at
    end
  end
  let(:model) do
    names = hooks
    comments = comment_model
    Class.new(TestModel) do
      self.table_name = "ssv_posts"
      include ConcernsOnRails::SoftDeletable

      has_many :ssv_comments, anonymous_class: comments, foreign_key: :ssv_post_id
      soft_deletable_by :deleted_at, cascade: :ssv_comments

      attr_accessor :fired

      names.each { |hook| define_method(hook) { (self.fired ||= []) << hook } }
    end
  end
  let(:stamp) { Time.utc(2026, 1, 1, 10) }

  def stored(klass, record)
    klass.unscoped.find(record.id)
  end

  describe "#soft_delete!" do
    it "really soft-deletes a record whose stamp was assigned but not saved (hooks, cascade)" do
      post = model.create!(title: "a")
      comment = comment_model.create!(ssv_post_id: post.id, body: "c")
      post.deleted_at = Time.current

      expect(post.soft_delete!).to be(true)
      expect(stored(model, post).deleted_at).not_to be_nil
      expect(stored(comment_model, comment).deleted_at).not_to be_nil
      expect(post.fired).to eq(%i[before_soft_delete after_soft_delete])
    end

    it "writes the verb's own time over an unsaved assigned stamp" do
      post = model.create!(title: "a")
      post.deleted_at = stamp - 1.day

      expect(post.soft_delete!(at: stamp)).to be(true)
      expect(stored(model, post).deleted_at).to eq(stamp)
    end

    it "is a no-op on a record soft-deleted in the database: keeps the stamp, no hook, no cascade write" do
      post = model.create!(title: "a")
      post.soft_delete!(at: stamp)
      post.fired = nil

      expect(post.soft_delete!).to be(true)
      expect(post.fired).to be_nil
      expect(stored(model, post).deleted_at).to eq(stamp)
    end

    it "saves the other pending changes of an already soft-deleted record (no stamp write, no hook)" do
      post = model.create!(title: "a")
      post.soft_delete!(at: stamp)
      post.fired = nil
      post.title = "kept"

      expect(post.soft_delete!).to be(true)
      expect(stored(model, post).title).to eq("kept")
      expect(stored(model, post).deleted_at).to eq(stamp)
      expect(post.fired).to be_nil
    end

    it "returns false when those pending changes are invalid" do
      invalid = Class.new(model) { validates :title, inclusion: { in: %w[a] } }
      post = invalid.create!(title: "a")
      post.soft_delete!(at: stamp)
      post.title = "bad"

      expect(post.soft_delete!).to be(false)
      expect(stored(model, post).title).to eq("a")
    end

    it "soft-deletes a new record (it is inserted with the stamp)" do
      post = model.new(title: "new")

      expect(post.soft_delete!(at: stamp)).to be(true)
      expect(post).to be_persisted
      expect(stored(model, post).deleted_at).to eq(stamp)
      expect(post.fired).to eq(%i[before_soft_delete after_soft_delete])
    end

    it "transitions a new record whose stamp is assigned" do
      post = model.new(title: "new", deleted_at: stamp)

      expect(post.soft_delete!).to be(true)
      expect(post).to be_persisted
      expect(post.fired).to eq(%i[before_soft_delete after_soft_delete])
    end

    it "stays a no-op on a destroyed record that was soft-deleted" do
      post = model.create!(title: "a")
      post.soft_delete!
      post.destroy

      expect(post.soft_delete!).to be(true)
    end

    it "still soft-deletes a live record, writes once and fires the hooks (the unaffected path)" do
      post = model.create!(title: "a")

      expect(post.soft_delete!(at: stamp)).to be(true)
      expect(stored(model, post).deleted_at).to eq(stamp)
      expect(post.fired).to eq(%i[before_soft_delete after_soft_delete])
    end

    it "retries cleanly after a vetoed write (the stamp is put back, not swallowed)" do
      vetoing = Class.new(model) do
        def after_soft_delete
          super
          raise ActiveRecord::Rollback if @veto
        end

        attr_writer :veto
      end
      post = vetoing.create!(title: "a")
      post.veto = true

      expect(post.soft_delete!).to be(false)
      expect(stored(model, post).deleted_at).to be_nil

      post.veto = false
      expect(post.soft_delete!).to be(true)
      expect(stored(model, post).deleted_at).not_to be_nil
    end
  end

  describe "#restore!" do
    it "really restores a record whose stamp was cleared but not saved (hooks, cascade)" do
      post = model.create!(title: "a")
      comment = comment_model.create!(ssv_post_id: post.id, body: "c")
      post.soft_delete!(at: stamp)
      post.fired = nil
      post.deleted_at = nil

      expect(post.restore!).to be(true)
      expect(stored(model, post).deleted_at).to be_nil
      expect(stored(comment_model, comment).deleted_at).to be_nil
      expect(post.fired).to eq(%i[before_restore after_restore])
    end

    it "restores the children carrying the SAVED stamp when the in-memory one was edited" do
      post = model.create!(title: "a")
      comment = comment_model.create!(ssv_post_id: post.id, body: "c")
      post.soft_delete!(at: stamp)
      post.deleted_at = stamp + 1.hour

      expect(post.restore!).to be(true)
      expect(stored(model, post).deleted_at).to be_nil
      expect(stored(comment_model, comment).deleted_at).to be_nil
    end

    it "is a no-op on a live record: no hook, nothing written" do
      post = model.create!(title: "a")

      expect(post.restore!).to be(true)
      expect(post.fired).to be_nil
    end

    it "saves the other pending changes of a live record (no hook)" do
      post = model.create!(title: "a")
      post.title = "kept"

      expect(post.restore!).to be(true)
      expect(stored(model, post).title).to eq("kept")
      expect(post.fired).to be_nil
    end

    it "transitions a live record whose stamp was assigned but not saved (the unsaved flip is cleared)" do
      post = model.create!(title: "a")
      post.deleted_at = stamp

      expect(post.restore!).to be(true)
      expect(post.deleted_at).to be_nil
      expect(stored(model, post).deleted_at).to be_nil
      expect(post.fired).to eq(%i[before_restore after_restore])
    end

    it "stays a no-op on a destroyed live record" do
      post = model.create!(title: "a")
      post.destroy

      expect(post.restore!).to be(true)
    end

    it "still restores a record soft-deleted in the database, cascade included (the unaffected path)" do
      post = model.create!(title: "a")
      comment = comment_model.create!(ssv_post_id: post.id, body: "c")
      post.soft_delete!(at: stamp)
      post.fired = nil

      expect(post.restore!).to be(true)
      expect(stored(model, post).deleted_at).to be_nil
      expect(stored(comment_model, comment).deleted_at).to be_nil
      expect(post.fired).to eq(%i[before_restore after_restore])
    end
  end

  describe "with touch: false (update_column write path)" do
    let(:quiet_model) do
      Class.new(TestModel) do
        self.table_name = "ssv_posts"
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :deleted_at, touch: false
      end
    end

    it "soft_delete! and restore! act on an unsaved stamp flip too" do
      post = quiet_model.create!(title: "a")
      post.deleted_at = stamp
      expect(post.soft_delete!(at: stamp)).to be(true)
      expect(stored(quiet_model, post).deleted_at).to eq(stamp)

      post.deleted_at = nil
      expect(post.restore!).to be(true)
      expect(stored(quiet_model, post).deleted_at).to be_nil
    end
  end
end
