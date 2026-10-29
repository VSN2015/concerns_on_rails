require "spec_helper"
require "cgi"

# TRANS-2 (audit 2026-10-29): Normalizable's before_save settle step compared a
# field with what NORMALIZABLE produced, so it re-normalized what a later
# sibling transform (Sanitizable `on: :write`) had written: the stored value
# differed from the validated one, titleize turned "&lt;" into "&Lt;" (U+226A),
# and an entity-decoding rule stored live markup. A field still holding what a
# transform last wrote is left alone; a field rewritten by code that is no
# transform (a slug built in a validate step) is still normalized.
describe "Normalizable does not re-normalize a sibling transform's output" do
  before do
    ActiveRecord::Schema.define do
      create_table :sibling_output_posts, force: true do |t|
        t.string :title
        t.text :body
        t.string :slug
        t.string :tags
      end
    end
  end

  after { ActiveRecord::Base.connection.drop_table(:sibling_output_posts, if_exists: true) }

  def model(&body)
    klass = Class.new(TestModel) { self.table_name = "sibling_output_posts" }
    klass.class_eval(&body)
    klass
  end

  it "stores what validation accepted (:titleize + :strip on: :write)" do
    validated = []
    klass = model do
      include ConcernsOnRails::Models::Normalizable
      include ConcernsOnRails::Models::Sanitizable

      normalizable :title, with: :titleize
      sanitizable :title, with: :strip, on: :write
      validate { validated << title }
    end

    record = klass.create!(title: "a < b")

    expect(validated.last).to eq("A &lt; B")
    expect(record.reload.title).to eq("A &lt; B")
  end

  it "stores the validated value on every save path" do
    klass = model do
      include ConcernsOnRails::Models::Normalizable
      include ConcernsOnRails::Models::Sanitizable

      normalizable :title, with: :titleize
      sanitizable :title, with: :strip, on: :write
    end

    unvalidated = klass.new(title: "a < b")
    unvalidated.save(validate: false)
    updated = klass.create!(title: "x").tap { |r| r.update_attribute(:title, "a < b") }
    twice = klass.new(title: "a < b").tap { |r| r.save! if r.valid? }

    expect([unvalidated, updated, twice].map { |r| r.reload.title }).to eq(["A &lt; B"] * 3)
  end

  it "never stores markup in a :strip on: :write column" do
    klass = model do
      include ConcernsOnRails::Models::Normalizable
      include ConcernsOnRails::Models::Sanitizable

      normalizable :body, with: ->(v) { CGI.unescapeHTML(v) }
      sanitizable :body, with: :strip, on: :write
    end

    record = klass.create!(body: "&amp;lt;img src=x onerror=alert(1)&amp;gt;<b></b>")

    expect(record.reload.body).not_to include("<img")
    expect(record.body).to eq("&lt;img src=x onerror=alert(1)&gt;")
  end

  it "does not re-normalize a Taggable rewrite of the same column either" do
    klass = model do
      include ConcernsOnRails::Models::Normalizable
      include ConcernsOnRails::Models::Taggable

      normalizable :tags, with: ->(v) { "#{v}, extra" }
      taggable_by :tags
    end

    expect(klass.create!(tags: "a,b").reload.tags).to eq("a,b,extra")
  end

  it "still normalizes a field rewritten by code that is no transform (a slug built after the pass)" do
    klass = model do
      include ConcernsOnRails::Models::Normalizable

      normalizable :slug, with: ->(v) { v.tr("-", "_") }
      validate { self.slug = "hello-world" if slug == "placeholder" }
    end

    expect(klass.create!(slug: "placeholder").reload.slug).to eq("hello_world")
  end

  it "still normalizes a field a before_save-free pass never saw (nil at the pass, filled in a validate step)" do
    klass = model do
      include ConcernsOnRails::Models::Normalizable

      normalizable :slug, with: :upcase
      validate { self.slug ||= "filled" }
    end

    expect(klass.create!.reload.slug).to eq("FILLED")
  end

  it "forgets the transforms' record on reload" do
    klass = model do
      include ConcernsOnRails::Models::Normalizable

      normalizable :title, with: ->(v) { "#{v}!" }
    end
    record = klass.create!(title: "a")
    record.title = "b"
    record.valid?
    record.reload
    record.title = "b!"
    record.save!

    expect(record.reload.title).to eq("b!!")
  end
end
