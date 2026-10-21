require "spec_helper"

# Audit 2026-10-10 (STATE-6): publish! / activate! / deactivate! on a record
# already in the target state rewrote its stamp (the "published on" date,
# activated_at) to now and fired the after-hook again — a double-submitted
# button or a retried job sent the "your post is live" mail twice — while
# publish_all / activate_all / deactivate_all skip such rows. They are now
# no-ops there: true, nothing written, no hook. publish_at! and
# toggle_active! still always write.
describe "Publishable / Activatable verbs on an already-transitioned record" do
  before do
    ActiveRecord::Schema.define do
      create_table :idv_posts, force: true do |t|
        t.datetime :published_at
        t.boolean :active
        t.datetime :activated_at
        t.datetime :deactivated_at
        t.timestamps
      end
      create_table :idv_flags, force: true do |t|
        t.boolean :published, default: false
        t.string :note
      end
    end
  end

  after do
    %i[idv_posts idv_flags].each { |table| ActiveRecord::Base.connection.drop_table(table, if_exists: true) }
  end

  let(:model) do
    Class.new(TestModel) do
      self.table_name = "idv_posts"
      include ConcernsOnRails::Publishable
      include ConcernsOnRails::Activatable

      attr_accessor :fired

      publishable_by :published_at
      activatable_by :active, timestamps: true

      %i[before_publish after_publish before_activate after_activate before_deactivate after_deactivate].each do |hook|
        define_method(hook) { (self.fired ||= []) << hook }
      end
    end
  end

  let(:earlier) { Time.utc(2026, 1, 1, 10) }

  describe "#publish!" do
    it "keeps the original publication time and fires no hook" do
      post = model.create!
      travel_to(earlier) { post.publish! }
      post.fired = nil
      updated_at = post.reload.updated_at

      expect(post.publish!).to be(true)
      expect(post.fired).to be_nil
      expect(post.reload.published_at).to eq(earlier)
      expect(post.updated_at).to eq(updated_at)
    end

    it "still publishes a draft or a scheduled record now" do
      freeze_time do
        draft = model.create!
        scheduled = model.create!(published_at: 1.day.from_now)

        expect(draft.publish!).to be(true)
        expect(scheduled.publish!).to be(true)
        expect(draft.reload.published_at).to eq(Time.zone.now)
        expect(scheduled.reload.published_at).to eq(Time.zone.now)
        expect(draft.fired).to eq(%i[before_publish after_publish])
      end
    end

    it "leaves publish_at! able to re-stamp a published record" do
      post = model.create!(published_at: earlier)

      expect(post.publish_at!(earlier + 1.day)).to be(true)
      expect(post.reload.published_at).to eq(earlier + 1.day)
    end

    it "is a no-op on a boolean column that is already true" do
      flag_model = Class.new(TestModel) do
        self.table_name = "idv_flags"
        include ConcernsOnRails::Publishable

        attr_accessor :fired

        publishable_by :published
        define_method(:after_publish) { self.fired = true }
      end
      post = flag_model.create!(published: true)

      expect(post.publish!).to be(true)
      expect(post.fired).to be_nil
    end
  end

  describe "#activate!" do
    it "keeps activated_at and fires no hook on an active record" do
      post = model.create!
      travel_to(earlier) { post.activate! }
      post.fired = nil

      expect(post.activate!).to be(true)
      expect(post.fired).to be_nil
      expect(post.reload.activated_at).to eq(earlier)
    end
  end

  describe "#deactivate!" do
    it "keeps deactivated_at and fires no hook on an inactive record" do
      post = model.create!(active: true)
      travel_to(earlier) { post.deactivate! }
      post.fired = nil

      expect(post.deactivate!).to be(true)
      expect(post.fired).to be_nil
      expect(post.reload.deactivated_at).to eq(earlier)
    end

    it "still writes false over a NULL flag" do
      post = model.create!(active: nil)

      expect(post.deactivate!).to be(true)
      expect(post.reload.active).to be(false)
      expect(post.fired).to eq(%i[before_deactivate after_deactivate])
    end
  end

  # Review follow-up: the guards read IN-MEMORY state, so a record carrying
  # unsaved changes (a new record, an unsaved flip of the flag itself, other
  # columns) "was already there" and the verb returned true without saving.
  # The no-op now needs a persisted record, no unsaved change to the field,
  # and the SAVED value already in the target state.
  describe "a record with unsaved state" do
    let(:flag_model) do
      Class.new(TestModel) do
        self.table_name = "idv_flags"
        include ConcernsOnRails::Publishable

        attr_accessor :fired

        publishable_by :published
        define_method(:after_publish) { (self.fired ||= []) << :after_publish }
      end
    end

    it "publish! saves the other pending changes of a live post (no re-stamp, no hooks)" do
      post = model.create!(published_at: earlier)
      post.fired = nil
      post.assign_attributes(active: true)

      expect(post.publish!).to be(true)
      expect(post.reload.active).to be(true)
      expect(post.published_at).to eq(earlier)
      expect(post.fired).to be_nil
    end

    it "publish! returns the failed save's false when the pending changes are invalid" do
      invalid = Class.new(model) { validates :active, inclusion: { in: [false] } }
      post = invalid.create!(published_at: earlier, active: false)
      post.active = true

      expect(post.publish!).to be(false)
      expect(post.reload.active).to be(false)
    end

    it "publish! inserts a new record whose column default already reads as published" do
      post = flag_model.new(published: true)
      expect(post.publish!).to be(true)
      expect(post).to be_persisted
      expect(post.fired).to eq([:after_publish])
    end

    it "publish! on a boolean column saves an unsaved published = true" do
      post = flag_model.create!(published: false)
      post.published = true

      expect(post.publish!).to be(true)
      expect(post.reload.published).to be(true)
      expect(post.fired).to eq([:after_publish])
    end

    it "publish! on a boolean column saves the other pending changes of a published record" do
      post = flag_model.create!(published: true)
      post.fired = nil
      post.note = "kept"

      expect(post.publish!).to be(true)
      expect(post.reload.note).to eq("kept")
      expect(post.fired).to be_nil
    end

    it "publish! ignores an overridden published?" do
      lying = Class.new(model) { def published? = false }
      post = lying.create!(published_at: earlier)
      post.fired = nil

      expect(post.publish!).to be(true)
      expect(post.fired).to be_nil
      expect(post.reload.published_at).to eq(earlier)
    end

    it "activate! inserts a new record whose column default is already true" do
      ActiveRecord::Schema.define { create_table(:idv_defaults, force: true) { |t| t.boolean :active, default: true } }
      with_default = Class.new(TestModel) do
        self.table_name = "idv_defaults"
        include ConcernsOnRails::Activatable

        activatable_by :active
      end
      sub = with_default.new

      expect(sub.activate!).to be(true)
      expect(sub).to be_persisted
    ensure
      ActiveRecord::Base.connection.drop_table(:idv_defaults, if_exists: true)
    end

    it "activate! saves the other pending changes of an active record without a hook" do
      post = model.create!(active: true)
      post.fired = nil
      post.assign_attributes(published_at: earlier)

      expect(post.activate!).to be(true)
      expect(post.reload.published_at).to eq(earlier)
      expect(post.fired).to be_nil
    end

    it "activate! saves an unsaved active = true over a stored false" do
      post = model.create!(active: false)
      post.active = true

      expect(post.activate!).to be(true)
      expect(post.reload.active).to be(true)
      expect(post.activated_at).to be_present
    end

    it "deactivate! saves an unsaved active = false and stamps deactivated_at" do
      post = model.create!(active: true)
      post.fired = nil
      post.active = false

      expect(post.deactivate!).to be(true)
      post.reload
      expect(post.active).to be(false)
      expect(post.deactivated_at).to be_present
      expect(post.fired).to eq(%i[before_deactivate after_deactivate])
    end

    it "deactivate! saves the other pending changes of an inactive record without a hook" do
      post = model.create!(active: false)
      post.fired = nil
      post.assign_attributes(published_at: earlier)

      expect(post.deactivate!).to be(true)
      expect(post.reload.published_at).to eq(earlier)
      expect(post.deactivated_at).to be_nil
      expect(post.fired).to be_nil
    end
  end

  # Review follow-up: the guards asked persisted?, which a DESTROYED record
  # fails, so an already-published / active one ran the transition and hit the
  # frozen record where it used to return true. They ask !new_record?, like
  # the sibling guards.
  describe "a destroyed record already in the target state" do
    it "publish! stays a no-op" do
      post = model.create!(published_at: earlier)
      post.destroy

      expect(post.publish!).to be(true)
    end

    it "activate! and deactivate! stay no-ops" do
      active = model.create!(active: true)
      active.destroy
      inactive = model.create!(active: false)
      inactive.destroy

      expect(active.activate!).to be(true)
      expect(inactive.deactivate!).to be(true)
    end
  end

  describe "#toggle_active!" do
    it "still flips both ways and fires the hooks each time" do
      post = model.create!(active: false)

      post.toggle_active!
      expect(post.reload.active).to be(true)
      post.toggle_active!
      expect(post.reload.active).to be(false)
      expect(post.fired).to eq(%i[before_activate after_activate before_deactivate after_deactivate])
    end
  end
end
