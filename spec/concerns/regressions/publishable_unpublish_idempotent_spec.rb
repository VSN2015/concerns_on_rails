require "spec_helper"

# Audit 2026-10-29 (STATE-5): 1.33.0 made publish! (and activate!/deactivate!,
# restore!) a no-op in the target state but left unpublish! out, so unpublishing
# a draft, or unpublishing twice, rewrote NULL and fired before/after_unpublish
# again ("your post was taken down" sent twice) while unpublish_all skips those
# rows. unpublish! now mirrors publish!: a stored record whose column has no
# unsaved change and whose SAVED value is already blank is a no-op. A scheduled
# row (a future time is set) is still cleared, with the hooks.
describe "Publishable#unpublish! on an already-unpublished record" do
  before do
    ActiveRecord::Schema.define do
      create_table :piu_posts, force: true do |t|
        t.datetime :published_at
        t.string :note
        t.timestamps
      end
      create_table :piu_flags, force: true do |t|
        t.boolean :published
        t.string :note
      end
      create_table :piu_dated, force: true do |t|
        t.date :published_on
      end
    end
  end

  after do
    %i[piu_posts piu_flags piu_dated].each { |t| ActiveRecord::Base.connection.drop_table(t, if_exists: true) }
  end

  let(:hooks) { %i[before_publish after_publish before_unpublish after_unpublish] }
  let(:model) do
    names = hooks
    Class.new(TestModel) do
      self.table_name = "piu_posts"
      include ConcernsOnRails::Publishable

      attr_accessor :fired

      publishable_by :published_at
      names.each { |hook| define_method(hook) { (self.fired ||= []) << hook } }
    end
  end
  let(:flag_model) do
    names = hooks
    Class.new(TestModel) do
      self.table_name = "piu_flags"
      include ConcernsOnRails::Publishable

      attr_accessor :fired

      publishable_by :published
      names.each { |hook| define_method(hook) { (self.fired ||= []) << hook } }
    end
  end
  let(:earlier) { Time.utc(2026, 1, 1, 10) }

  it "is a no-op on a draft: true, no hook, nothing written" do
    post = model.create!
    updated_at = post.reload.updated_at

    expect(post.unpublish!).to be(true)
    expect(post.fired).to be_nil
    expect(post.reload.published_at).to be_nil
    expect(post.updated_at).to eq(updated_at)
  end

  it "fires the hooks once for a published record, then a second call is a no-op" do
    post = model.create!(published_at: earlier)

    expect(post.unpublish!).to be(true)
    expect(post.reload.published_at).to be_nil
    expect(post.fired).to eq(%i[before_unpublish after_unpublish])
    post.fired = nil

    expect(post.unpublish!).to be(true)
    expect(post.fired).to be_nil
  end

  it "still clears a SCHEDULED record, with the hooks" do
    post = model.create!(published_at: 3.days.from_now)

    expect(post.scheduled?).to be(true)
    expect(post.unpublish!).to be(true)
    expect(post.reload.published_at).to be_nil
    expect(post.fired).to eq(%i[before_unpublish after_unpublish])
  end

  it "saves the other pending changes of a draft without a hook" do
    post = model.create!
    post.note = "kept"

    expect(post.unpublish!).to be(true)
    expect(post.reload.note).to eq("kept")
    expect(post.fired).to be_nil
  end

  it "returns the failed save's false when a draft's pending changes are invalid" do
    invalid = Class.new(model) { validates :note, inclusion: { in: [nil] } }
    post = invalid.create!
    post.note = "nope"

    expect(post.unpublish!).to be(false)
    expect(post.fired).to be_nil
    expect(post.reload.note).to be_nil
  end

  it "writes an unsaved flip of the column (publish then unpublish before saving) with the hooks" do
    post = model.create!(published_at: earlier)
    post.published_at = nil

    expect(post.unpublish!).to be(true)
    expect(post.reload.published_at).to be_nil
    expect(post.fired).to eq(%i[before_unpublish after_unpublish])
  end

  it "unpublishes a new record (it is inserted, the hooks fire)" do
    post = model.new

    expect(post.unpublish!).to be(true)
    expect(post).to be_persisted
    expect(post.fired).to eq(%i[before_unpublish after_unpublish])
  end

  it "stays a no-op on a destroyed draft" do
    post = model.create!
    post.destroy

    expect(post.unpublish!).to be(true)
    expect(post.fired).to be_nil
  end

  it "ignores an overridden draft? / published?" do
    lying = Class.new(model) do
      def draft? = false
      def published? = true
    end
    post = lying.create!

    expect(post.unpublish!).to be(true)
    expect(post.fired).to be_nil
  end

  describe "a boolean column" do
    it "is a no-op on a false or NULL flag" do
      off = flag_model.create!(published: false)
      unset = flag_model.create!(published: nil)

      expect(off.unpublish!).to be(true)
      expect(unset.unpublish!).to be(true)
      expect(off.fired).to be_nil
      expect(unset.fired).to be_nil
      expect(unset.reload.published).to be_nil
    end

    it "writes false (never NULL) with the hooks over a true flag" do
      on = flag_model.create!(published: true)

      expect(on.unpublish!).to be(true)
      expect(on.reload.published).to be(false)
      expect(on.fired).to eq(%i[before_unpublish after_unpublish])
    end
  end

  describe "a date column" do
    let(:dated_model) do
      Class.new(TestModel) do
        self.table_name = "piu_dated"
        include ConcernsOnRails::Publishable

        publishable_by :published_on
      end
    end

    it "clears a published or a scheduled date and leaves a NULL one alone" do
      published = dated_model.create!(published_on: Date.current - 1)
      scheduled = dated_model.create!(published_on: Date.current + 4)
      draft = dated_model.create!

      expect(published.unpublish!).to be(true)
      expect(scheduled.unpublish!).to be(true)
      expect(draft.unpublish!).to be(true)
      expect([published, scheduled, draft].map { |r| r.reload.published_on }).to eq([nil, nil, nil])
    end
  end

  describe "unpublish_all" do
    it "agrees with the verb: counts only the published rows, drafts untouched" do
      published = model.create!(published_at: earlier)
      draft = model.create!

      expect(model.unpublish_all).to eq(1)
      expect(published.reload.published_at).to be_nil
      expect(draft.reload.published_at).to be_nil
    end

    it "runs each published row's hooks once on the per-record path" do
      model.create!(published_at: earlier)
      model.create!
      fired = []
      model.class_eval { define_method(:after_unpublish) { fired << id } }

      expect(model.unpublish_all).to eq(1)
      expect(fired.size).to eq(1)
    end
  end

  it "leaves publish! able to republish an unpublished record" do
    post = model.create!(published_at: earlier)
    post.unpublish!
    post.fired = nil

    expect(post.publish!).to be(true)
    expect(post.reload.published_at).to be_present
    expect(post.fired).to eq(%i[before_publish after_publish])
  end
end
