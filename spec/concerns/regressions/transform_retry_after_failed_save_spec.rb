require "spec_helper"
require "erb"

# TRANS-3 (audit 2026-10-29): Normalizable and Sanitizable `on: :write` cleared
# their per-save record inside the before_save dispatcher, before the save was
# known to succeed. A save halted by a later before_save, or rolled back
# (RecordNotUnique), then retried on the same record, ran a non-idempotent rule
# on its own output again ("a!" -> "a!!"). The record now outlives such a save
# and is dropped once it SUCCEEDED (after_save) and on reload.
describe "Transform rules run once per attempt when a save is halted or rolled back and retried" do
  before do
    ActiveRecord::Schema.define do
      create_table :transform_retry_posts, force: true do |t|
        t.string :title
        t.string :code
      end
      add_index :transform_retry_posts, :code, unique: true
      create_table :transform_retry_children, force: true do |t|
        t.integer :transform_retry_post_id
        t.string :title
        t.string :code
      end
      add_index :transform_retry_children, :code, unique: true
    end
  end

  after do
    %i[transform_retry_posts transform_retry_children].each do |table|
      ActiveRecord::Base.connection.drop_table(table, if_exists: true)
    end
  end

  let(:escape) { ->(v) { ERB::Util.html_escape(v).to_str } }

  def model(&body)
    klass = Class.new(TestModel) { self.table_name = "transform_retry_posts" }
    klass.class_eval(&body)
    klass
  end

  it "Normalizable: halted by a later before_save, then saved again" do
    klass = model do
      attr_accessor :halt

      include ConcernsOnRails::Models::Normalizable

      normalizable :title, with: ->(v) { "#{v}!" }
      before_save { throw :abort if halt }
    end
    record = klass.new(title: "a", halt: true)

    expect(record.save).to be(false)
    record.halt = false
    record.save!

    expect(record.reload.title).to eq("a!")
  end

  it "Normalizable: first INSERT hits a unique index, the same record is saved again" do
    esc = escape
    klass = model do
      include ConcernsOnRails::Models::Normalizable

      normalizable :title, with: esc
    end
    klass.create!(code: "taken", title: "seed")
    record = klass.new(code: "taken", title: "Tom & Jerry")

    expect { record.save! }.to raise_error(ActiveRecord::RecordNotUnique)
    record.code = "free"
    record.save!

    expect(record.reload.title).to eq("Tom &amp; Jerry")
  end

  it "Sanitizable on: :write: halted, then saved again" do
    esc = escape
    klass = model do
      attr_accessor :halt

      include ConcernsOnRails::Models::Sanitizable

      sanitizable :title, with: esc, on: :write
      before_save { throw :abort if halt }
    end
    record = klass.new(title: "a&b", halt: true)

    expect(record.save).to be(false)
    record.halt = false
    record.save!

    expect(record.reload.title).to eq("a&amp;b")
  end

  it "Sanitizable on: :write: an update_attribute (validation skipped) halted, then saved again" do
    esc = escape
    klass = model do
      attr_accessor :halt

      include ConcernsOnRails::Models::Sanitizable

      sanitizable :title, with: esc, on: :write
      before_save { throw :abort if halt }
    end
    record = klass.create!(title: "seed")
    record.halt = true

    expect(record.update_attribute(:title, "a&b")).to be(false)
    record.halt = false
    record.save!

    expect(record.reload.title).to eq("a&amp;b")
  end

  it "Normalizable then Sanitizable on one column: halted, then saved again" do
    esc = escape
    klass = model do
      attr_accessor :halt

      include ConcernsOnRails::Models::Normalizable
      include ConcernsOnRails::Models::Sanitizable

      normalizable :title, with: ->(v) { "#{v}!" }
      sanitizable :title, with: esc, on: :write
      before_save { throw :abort if halt }
    end
    record = klass.new(title: "a&b", halt: true)

    expect(record.save).to be(false)
    record.halt = false
    record.save!

    expect(record.reload.title).to eq("a&amp;b!")
  end

  # Round 2: a rollback AFTER after_save restores the dirty state but keeps the
  # transformed values, so the records must come back with it.
  it "Sanitizable on: :write: an explicit Rollback after the save, then saved again" do
    esc = escape
    klass = model do
      include ConcernsOnRails::Models::Sanitizable

      sanitizable :title, with: esc, on: :write
    end
    record = klass.new(title: "a&b")
    klass.transaction do
      record.save!
      raise ActiveRecord::Rollback
    end
    expect(record).to be_new_record
    record.save!

    expect(record.reload.title).to eq("a&amp;b")
  end

  it "Normalizable: a later after_save raising rolls the save back, then saved again" do
    klass = model do
      attr_accessor :explode

      include ConcernsOnRails::Models::Normalizable

      normalizable :title, with: ->(v) { "#{v}!" }
      after_save { raise "boom" if explode }
    end
    record = klass.new(title: "a", explode: true)

    expect { record.save! }.to raise_error("boom")
    record.explode = false
    record.save!

    expect(record.reload.title).to eq("a!")
  end

  it "Sanitizable: a parent's autosave where a LATER child fails, the parent retried" do
    esc = escape
    stub_const("TransformRetryChild", Class.new(TestModel) do
      self.table_name = "transform_retry_children"
      include ConcernsOnRails::Models::Sanitizable

      sanitizable :title, with: esc, on: :write
    end)
    stub_const("TransformRetryPost", Class.new(TestModel) do
      self.table_name = "transform_retry_posts"
      has_many :transform_retry_children, class_name: "TransformRetryChild", foreign_key: :transform_retry_post_id
    end)
    TransformRetryChild.create!(code: "taken", title: "seed")
    post = TransformRetryPost.new(title: "p")
    post.transform_retry_children.build(code: "c1", title: "a&b")
    bad = post.transform_retry_children.build(code: "taken", title: "x")

    expect { post.save! }.to raise_error(ActiveRecord::RecordNotUnique)
    bad.code = "c2"
    post.save!

    expect(TransformRetryChild.find_by(code: "c1").title).to eq("a&amp;b")
  end

  it "does not let a committed save's record leak into a later rolled-back one" do
    klass = model do
      include ConcernsOnRails::Models::Normalizable

      normalizable :title, with: ->(v) { "#{v}!" }
    end
    record = klass.create!(title: "a")
    record.title = "b"
    klass.transaction do
      record.save!
      raise ActiveRecord::Rollback
    end
    record.save!

    expect(record.reload.title).to eq("b!")
  end

  # A shallow `dup` shared the Hash the original keeps updating.
  it "gives a dup its own copy of the record" do
    klass = model do
      include ConcernsOnRails::Models::Normalizable

      normalizable :title, with: ->(v) { "#{v}!" }
    end
    original = klass.new(title: "a")
    original.valid?
    copy = original.dup
    copy.title = "b"
    copy.save!
    original.save!

    expect(original.reload.title).to eq("a!")
    expect(copy.reload.title).to eq("b!")
  end

  it "gives a Duplicable copy its own record too" do
    klass = model do
      include ConcernsOnRails::Models::Normalizable
      include ConcernsOnRails::Models::Duplicable

      normalizable :title, with: ->(v) { "#{v}!" }
    end
    original = klass.create!(title: "a")
    copy = original.duplicate
    copy.title = "z"
    copy.save!
    original.update!(title: "q")

    expect(copy.reload.title).to eq("z!")
    expect(original.reload.title).to eq("q!")
  end

  it "Sanitizable before Normalizable: an update_attribute halted, then saved again" do
    esc = escape
    klass = model do
      attr_accessor :halt

      include ConcernsOnRails::Models::Sanitizable
      include ConcernsOnRails::Models::Normalizable

      sanitizable :title, with: esc, on: :write
      normalizable :title, with: :squish
      before_save { throw :abort if halt }
    end
    record = klass.create!(title: "x")
    record.halt = true

    expect(record.update_attribute(:title, "a  & b")).to be(false)
    record.halt = false
    record.save!

    expect(record.reload.title).to eq("a &amp; b")
  end

  it "starts afresh with the next save cycle after a successful save" do
    klass = model do
      include ConcernsOnRails::Models::Normalizable

      normalizable :title, with: ->(v) { "#{v}!" }
    end
    record = klass.create!(title: "a")
    record.update!(title: "b")
    record.update!(title: "a!")

    expect(record.reload.title).to eq("a!!")
  end

  it "(control) a failed validation does not re-apply" do
    klass = model do
      attr_accessor :invalid

      include ConcernsOnRails::Models::Normalizable

      normalizable :title, with: ->(v) { "#{v}!" }
      validate { errors.add(:base, "no") if invalid }
    end
    record = klass.new(title: "a", invalid: true)

    expect(record.save).to be(false)
    record.invalid = false
    record.save!

    expect(record.reload.title).to eq("a!")
  end
end
