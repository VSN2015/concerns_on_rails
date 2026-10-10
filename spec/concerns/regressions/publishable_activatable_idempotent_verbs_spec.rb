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
