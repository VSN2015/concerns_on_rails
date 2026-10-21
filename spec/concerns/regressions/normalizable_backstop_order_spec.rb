require "spec_helper"
require "erb"

# Audit 2026-10-10, TRANS-5. Normalizable, Sanitizable, Taggable and
# Addressable each PREPENDED their own before_save backstop. Every prepend
# goes to the front of the chain, so the backstops ran in REVERSE include
# order while the before_validation passes run in include order: with two
# transforms on one column, update_attribute / save(validate: false) stored a
# third value that was neither the raw input nor what a validated save
# stores. One shared prepended dispatcher now runs the backstops in
# before_validation order.
describe "Transform backstops run in before_validation order" do
  before do
    ActiveRecord::Schema.define do
      create_table :backstop_order_posts, force: true do |t|
        t.string :title
        t.string :tags
        t.string :line1
        t.string :city
        t.string :postal_code
        t.string :country
      end
    end
  end

  after do
    ActiveRecord::Base.connection.drop_table(:backstop_order_posts, if_exists: true)
  end

  let(:dispatcher) { ConcernsOnRails::Support::TransformBackstop::DISPATCHER }

  # The value each save path stores for `field`, given the raw input.
  def stored_values(klass, field, input, **create_attrs)
    validated = klass.create!(create_attrs.merge(field => input)).reload[field]

    unvalidated = klass.new(create_attrs.merge(field => input))
    unvalidated.save(validate: false)

    via_update_attribute = klass.create!(create_attrs)
    via_update_attribute.update_attribute(field, input)

    [validated, unvalidated.reload[field], via_update_attribute.reload[field]]
  end

  it "stores the validated value when Sanitizable (on: :write) precedes Normalizable on a column" do
    klass = Class.new(TestModel) do
      self.table_name = "backstop_order_posts"
      include ConcernsOnRails::Models::Sanitizable
      include ConcernsOnRails::Models::Normalizable

      sanitizable :title, with: :strip, on: :write
      normalizable :title, with: :squish
    end

    expect(stored_values(klass, :title, "<b> a </b>  b")).to eq(["a b"] * 3)
  end

  it "stores the validated value when Addressable precedes Normalizable on a column" do
    klass = Class.new(TestModel) do
      self.table_name = "backstop_order_posts"
      include ConcernsOnRails::Models::Addressable
      include ConcernsOnRails::Models::Normalizable

      addressable_by required: []
      normalizable :city, with: ->(v) { v.sub(/\s*\(.*\)\z/, "") } # sees Addressable's squished value
    end

    expect(stored_values(klass, :city, " Cupertino  (HQ)  ")).to eq(["Cupertino"] * 3)
  end

  it "stores the validated value when Taggable precedes Normalizable on a column" do
    klass = Class.new(TestModel) do
      self.table_name = "backstop_order_posts"
      include ConcernsOnRails::Models::Taggable

      taggable_by :tags # its before_validation pass is registered here, ahead of Normalizable's
      include ConcernsOnRails::Models::Normalizable

      normalizable :tags, with: ->(v) { v.split(",").first.to_s } # keeps the first (cleaned) tag
    end

    expect(stored_values(klass, :tags, " , ruby, rails", title: "t")).to eq(["ruby"] * 3)
  end

  # Normalizable compares against what IT produced, so in a validated save it
  # re-normalizes at before_save a field a later transform rewrote. A save
  # that skips validation must end the same way, without making the later
  # transform run twice.
  it "keeps the include order the other way round too (Normalizable gets the last word)" do
    klass = Class.new(TestModel) do
      self.table_name = "backstop_order_posts"
      include ConcernsOnRails::Models::Normalizable
      include ConcernsOnRails::Models::Sanitizable

      normalizable :title, with: :squish
      sanitizable :title, with: :strip, on: :write
    end

    expect(stored_values(klass, :title, "<b> a </b>  b")).to eq(["a b"] * 3)
  end

  it "runs each non-idempotent Proc once on every path, in either include order" do
    escape = ->(v) { ERB::Util.html_escape(v).to_str }
    bang = ->(v) { "#{v}!" }
    sanitize_first = Class.new(TestModel) do
      self.table_name = "backstop_order_posts"
      include ConcernsOnRails::Models::Sanitizable
      include ConcernsOnRails::Models::Normalizable

      sanitizable :title, with: escape, on: :write
      normalizable :title, with: bang
    end
    normalize_first = Class.new(TestModel) do
      self.table_name = "backstop_order_posts"
      include ConcernsOnRails::Models::Normalizable
      include ConcernsOnRails::Models::Sanitizable

      normalizable :title, with: bang
      sanitizable :title, with: escape, on: :write
    end

    expect(stored_values(sanitize_first, :title, "a&b")).to eq(["a&amp;b!"] * 3)
    # Validated: bang, escape, then bang again for the escaped value (the
    # documented "Normalizable compares against what IT produced").
    expect(stored_values(normalize_first, :title, "a&b")).to eq(["a&amp;b!!"] * 3)
  end

  it "registers ONE prepended dispatcher, in before_validation order, ahead of an earlier before_save" do
    seen = nil
    klass = Class.new(TestModel) do
      self.table_name = "backstop_order_posts"
      before_save { seen = title }
      include ConcernsOnRails::Models::Sanitizable
      include ConcernsOnRails::Models::Normalizable
      include ConcernsOnRails::Models::Addressable
      include ConcernsOnRails::Models::Taggable

      sanitizable :title, with: :strip, on: :write
      normalizable :title, with: :squish
      addressable_by required: []
      taggable_by :tags
      taggable_by :tags # re-declared: still one entry
    end

    expect(klass._save_callbacks.map(&:filter).count(dispatcher)).to eq(1)
    expect(klass.concerns_on_rails_transform_backstops)
      .to eq(%i[sanitizable_apply_unvalidated normalizable_apply_unvalidated
                addressable_normalize_unvalidated taggable_normalize_unvalidated])
    expect(klass.concerns_on_rails_transform_settles).to eq(%i[normalizable_settle])

    klass.create!(title: "t").update_attribute(:title, "<b> new </b>  title")
    expect(seen).to eq("new title")
  end

  it "lets a subclass add a backstop without touching its parent's list" do
    parent = Class.new(TestModel) do
      self.table_name = "backstop_order_posts"
      include ConcernsOnRails::Models::Normalizable

      normalizable :title, with: :squish
    end
    child = Class.new(parent) do
      include ConcernsOnRails::Models::Sanitizable

      sanitizable :title, with: :strip, on: :write
    end

    expect(parent.concerns_on_rails_transform_backstops).to eq(%i[normalizable_apply_unvalidated])
    expect(child.concerns_on_rails_transform_backstops)
      .to eq(%i[normalizable_apply_unvalidated sanitizable_apply_unvalidated])
    expect(child._save_callbacks.map(&:filter).count(dispatcher)).to eq(1)

    record = parent.create!(title: "x")
    record.update_attribute(:title, "<b>a</b>  b")
    expect(record.reload.title).to eq("<b>a</b> b") # the parent has no Sanitizable backstop

    record = child.create!(title: "x")
    record.update_attribute(:title, " <b>a</b>  b")
    expect(record.reload.title).to eq("a b")
  end
end
