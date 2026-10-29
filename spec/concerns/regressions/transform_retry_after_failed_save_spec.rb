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
    end
  end

  after { ActiveRecord::Base.connection.drop_table(:transform_retry_posts, if_exists: true) }

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
