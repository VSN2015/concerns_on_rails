require "spec_helper"
require "erb"

# Audit 2026-10-10, TRANS-3. `on: :write` re-ran the writer on every save of
# a persisted record, changed or not, so a non-idempotent writer compounded
# once per save ("Tom &amp; Jerry" -> "Tom &amp;amp; Jerry" -> ...).
# Normalizable and Addressable already skip a persisted field this save does
# not change.
describe ConcernsOnRails::Models::Sanitizable do
  before do
    ActiveRecord::Schema.define do
      create_table :unchanged_sanitized_posts, force: true do |t|
        t.string :title
        t.integer :views
      end
    end
  end

  after do
    ActiveRecord::Base.connection.drop_table(:unchanged_sanitized_posts, if_exists: true)
  end

  let(:escape) { ->(v) { ERB::Util.html_escape(v).to_str } }

  let(:klass) do
    writer = escape
    Class.new(TestModel) do
      self.table_name = "unchanged_sanitized_posts"
      include ConcernsOnRails::Models::Sanitizable

      # Store HTML-escaped text: a legitimate, non-idempotent Proc writer.
      sanitizable :title, with: writer, on: :write
    end
  end

  it "leaves an unchanged persisted field alone on an unrelated save" do
    post = klass.create!(title: "Tom & Jerry")
    expect(post.title).to eq("Tom &amp; Jerry")

    post.update!(views: 1)
    expect(post.saved_changes.keys).not_to include("title")
    post.update!(views: 2)

    expect(post.reload.title).to eq("Tom &amp; Jerry")
  end

  it "leaves it alone on saves that skip validation too" do
    post = klass.create!(title: "Tom & Jerry")

    post.update_attribute(:views, 1)
    post.views = 2
    post.save(validate: false)

    expect(post.reload.title).to eq("Tom &amp; Jerry")
  end

  it "still sanitizes the field when this save changes it" do
    post = klass.create!(title: "Tom & Jerry")

    post.update!(title: "Bert & Ernie")
    expect(post.reload.title).to eq("Bert &amp; Ernie")

    post.update_attribute(:title, "Tom & Jerry")
    expect(post.reload.title).to eq("Tom &amp; Jerry")
  end

  it "no longer repairs a row written around the callbacks on an unrelated save (sanitize_all! does)" do
    strip = Class.new(TestModel) do
      self.table_name = "unchanged_sanitized_posts"
      include ConcernsOnRails::Models::Sanitizable

      sanitizable :title, with: :strip, on: :write
    end
    post = strip.create!(title: "clean")
    post.update_columns(title: "<b>raw</b>")

    post.update!(views: 1)
    expect(post.reload.title).to eq("<b>raw</b>")

    expect(strip.sanitize_all!).to eq(1)
    expect(post.reload.title).to eq("raw")
  end
end
