require "spec_helper"

# Audit 2026-10-10 DATA-9: a child destroyed through its parent's
# `has_one ..., dependent: :destroy` still decremented that parent (on
# purpose: a has_one REPLACEMENT sets destroyed_by_association too, and there
# the parent survives). The decrement's UPDATE bumped the parent row's
# lock_version, and the bump was mirrored only onto the instance the child's
# belongs_to held. Through a scoped has_one (no inverse detection) that was
# not the destroying parent, whose own DELETE then raised StaleObjectError:
# a freshly loaded locked parent could never be destroyed.
describe "CounterCacheable: a child destroyed through a has_one, dependent: :destroy" do
  before do
    ActiveRecord::Schema.define do
      create_table :ho_lock_posts, force: true do |t|
        t.string :title
        t.integer :profiles_count, default: 0
        t.datetime :updated_at
        t.integer :lock_version
      end
      create_table :ho_lock_profiles, force: true do |t|
        t.integer :ho_lock_post_id
        t.boolean :primary, default: true
      end
    end
  end

  after(:each) do
    %i[ho_lock_posts ho_lock_profiles].each { |table| ActiveRecord::Base.connection.drop_table(table, if_exists: true) }
  end

  def define_profile(touch: false)
    stub_const("HoLockProfile", Class.new(TestModel) do
      self.table_name = "ho_lock_profiles"
      include ConcernsOnRails::Models::CounterCacheable

      belongs_to :ho_lock_post
      counter_cacheable_by :ho_lock_post, count: :profiles_count, touch: touch
    end)
  end

  context "through a scoped has_one (no inverse detection)" do
    before do
      stub_const("HoLockPost", Class.new(TestModel) do
        self.table_name = "ho_lock_posts"
        has_one :ho_lock_profile, -> { where(primary: true) }, dependent: :destroy
      end)
      define_profile
    end

    it "lets a freshly loaded locked parent be destroyed" do
      post = HoLockPost.create!(title: "t")
      HoLockProfile.create!(ho_lock_post: post)
      post = HoLockPost.find(post.id) # nothing stale about it

      expect { post.destroy! }.not_to raise_error
      expect(HoLockPost.exists?(post.id)).to be(false)
      expect(HoLockProfile.count).to eq(0)
    end

    it "still decrements a surviving parent on replacement, without moving its lock_version" do
      post = HoLockPost.create!(title: "t")
      post.create_ho_lock_profile!
      post = HoLockPost.find(post.id)
      version = post.lock_version
      post.create_ho_lock_profile! # replaces (destroys) the old one

      expect(HoLockProfile.count).to eq(1)
      expect(post.reload.profiles_count).to eq(1)
      expect(post.lock_version).to eq(version + 1) # the new profile's increment only
      expect { post.update!(title: "after") }.not_to raise_error
    end
  end

  context "through an inverse-detected has_one" do
    before do
      stub_const("HoLockPost", Class.new(TestModel) do
        self.table_name = "ho_lock_posts"
        has_one :ho_lock_profile, dependent: :destroy
      end)
    end

    it "lets the parent be destroyed (unchanged)" do
      define_profile
      post = HoLockPost.create!(title: "t")
      HoLockProfile.create!(ho_lock_post: post)

      expect { HoLockPost.find(post.id).destroy! }.not_to raise_error
      expect(HoLockPost.exists?(post.id)).to be(false)
    end

    it "keeps the replacement count right and the parent saveable" do
      define_profile
      post = HoLockPost.create!(title: "t")
      post.create_ho_lock_profile!
      post.create_ho_lock_profile!

      expect(post.reload.profiles_count).to eq(1)
      expect { post.update!(title: "after") }.not_to raise_error
    end

    it "touches the parent on the replaced child's decrement when the rule says so" do
      define_profile(touch: true)
      post = HoLockPost.create!(title: "t")
      post.create_ho_lock_profile!
      HoLockPost.where(id: post.id).update_all(updated_at: Time.utc(2000, 1, 1))
      post = HoLockPost.find(post.id)
      post.create_ho_lock_profile!

      expect(post.reload.profiles_count).to eq(1)
      expect(post.updated_at).to be > Time.utc(2001, 1, 1)
    end
  end

  it "keeps a has_many dependent: :destroy parent destroyable (no decrement at all)" do
    stub_const("HoLockPost", Class.new(TestModel) do
      self.table_name = "ho_lock_posts"
      has_many :ho_lock_profiles, -> { where(primary: true) }, dependent: :destroy
    end)
    define_profile
    post = HoLockPost.create!(title: "t")
    2.times { HoLockProfile.create!(ho_lock_post: post) }

    expect { HoLockPost.find(post.id).destroy! }.not_to raise_error
    expect(HoLockProfile.count).to eq(0)
  end
end
