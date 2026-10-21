require "spec_helper"

# Audit 2026-10-10 (STATE-4): the batch verbs' single-UPDATE fast path
# skipped the save callbacks in which the gem's OWN sibling concerns keep
# data in step — a CounterCacheable rule with an `if:` condition, Auditable
# tracking the written column — while the per-record path ran them. Whether
# the counter or the audit trail was kept therefore depended on whether the
# model happened to declare an unrelated validator. The fast path is now
# refused when such bookkeeping is present, and taken as before otherwise.
describe "batch fast paths and sibling concerns' save-callback bookkeeping" do
  before do
    ActiveRecord::Schema.define do
      create_table :bfb_posts, force: true do |t|
        t.integer :live_comments_count, default: 0
        t.integer :comments_count, default: 0
      end
      create_table :bfb_comments, force: true do |t|
        t.integer :bfb_post_id
        t.string :body
        t.datetime :published_at
        t.datetime :expires_at
        t.boolean :active, default: false
        t.text :audit_log
        t.timestamps
      end
    end
    stub_const("BfbPost", Class.new(TestModel) { self.table_name = "bfb_posts" })
  end

  after do
    %i[bfb_posts bfb_comments].each { |table| ActiveRecord::Base.connection.drop_table(table, if_exists: true) }
  end

  # Named: CounterCacheable needs a class name for the rows it counts.
  def comment_model(&block)
    stub_const("BfbComment", Class.new(TestModel) do
      self.table_name = "bfb_comments"
      include ConcernsOnRails::Publishable
      include ConcernsOnRails::Expirable
      include ConcernsOnRails::Activatable

      belongs_to :bfb_post, optional: true
      publishable_by :published_at
      expirable_by :expires_at, prefix: :term
      activatable_by :active, prefix: :flag
      class_eval(&block) if block
    end)
  end

  def update_statements(&)
    sql = []
    callback = ->(*, payload) { sql << payload[:sql] if payload[:sql] =~ /\AUPDATE/i }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &)
    sql
  end

  describe "CounterCacheable with a conditional rule" do
    it "publish_all keeps the counter in step, as publish! does" do
      model = comment_model do
        include ConcernsOnRails::CounterCacheable

        counter_cacheable_by :bfb_post, count: :live_comments_count, if: -> { published? }
      end
      post = BfbPost.create!
      2.times { model.create!(bfb_post: post) }

      expect(model.publish_all).to eq(2)
      expect(post.reload.live_comments_count).to eq(2)
      expect(model.unpublish_all).to eq(2)
      expect(post.reload.live_comments_count).to eq(0)
    end

    it "expire_all keeps the counter in step, as expire! does" do
      model = comment_model do
        include ConcernsOnRails::CounterCacheable

        counter_cacheable_by :bfb_post, count: :live_comments_count, if: -> { expires_at.nil? }
      end
      post = BfbPost.create!
      2.times { model.create!(bfb_post: post) }
      expect(post.reload.live_comments_count).to eq(2)

      expect(model.expire_all).to eq(2)
      expect(post.reload.live_comments_count).to eq(0)
    end

    it "activate_all / deactivate_all keep the counter in step" do
      model = comment_model do
        include ConcernsOnRails::CounterCacheable

        counter_cacheable_by :bfb_post, count: :live_comments_count, if: -> { active == true }
      end
      post = BfbPost.create!
      2.times { model.create!(bfb_post: post) }

      expect(model.activate_all).to eq(2)
      expect(post.reload.live_comments_count).to eq(2)
      expect(model.deactivate_all).to eq(2)
      expect(post.reload.live_comments_count).to eq(0)
    end

    it "still takes the single UPDATE for an unconditional rule (a batch never moves the foreign key)" do
      model = comment_model do
        include ConcernsOnRails::CounterCacheable

        counter_cacheable_by :bfb_post, count: :comments_count
      end
      post = BfbPost.create!
      2.times { model.create!(bfb_post: post) }

      expect(update_statements { expect(model.publish_all).to eq(2) }.size).to eq(1)
      expect(post.reload.comments_count).to eq(2)
    end
  end

  describe "Auditable" do
    it "publish_all records the change when the publish column is tracked" do
      model = comment_model do
        include ConcernsOnRails::Auditable

        auditable_by :published_at
      end
      comment = model.create!

      model.publish_all

      expect(comment.reload.last_change_for(:published_at)).not_to be_nil
    end

    it "activate_all records the change when the flag is tracked" do
      model = comment_model do
        include ConcernsOnRails::Auditable

        auditable_by :active
      end
      comment = model.create!

      model.activate_all

      expect(comment.reload.last_change_for(:active)).not_to be_nil
    end

    it "still takes the single UPDATE when only other columns are tracked" do
      model = comment_model do
        include ConcernsOnRails::Auditable

        auditable_by :body
      end
      2.times { model.create!(body: "x") }

      expect(update_statements { expect(model.publish_all).to eq(2) }.size).to eq(1)
    end
  end

  it "takes the single UPDATE on a plain model, bumping updated_at as before" do
    model = comment_model
    comment = travel_to(1.day.ago) { model.create! }

    freeze_time do
      expect(update_statements { expect(model.publish_all).to eq(1) }.size).to eq(1)
      expect(comment.reload.updated_at).to eq(Time.zone.now)
    end
  end
end
