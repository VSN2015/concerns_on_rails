require "spec_helper"
require "cgi"
require "erb"
require "json"

describe "TRANS audit v1.33.0" do
  before do
    ActiveRecord::Schema.define do
      create_table :trans_posts, force: true do |t|
        t.string :title
        t.string :code
        t.text :body
        t.text :settings
        t.string :tags
      end
      add_index :trans_posts, :code, unique: true
    end
  end

  after do
    ActiveRecord::Base.connection.drop_table(:trans_posts, if_exists: true)
  end

  def post_class(&body)
    klass = Class.new(TestModel) { self.table_name = "trans_posts" }
    klass.class_eval(&body)
    klass
  end

  describe "TRANS-1 Storable on a JSON-typed attribute over a non-:json column (PG jsonb has the same shape)" do
    let(:klass) do
      post_class do
        attribute :settings, :json
        include ConcernsOnRails::Models::Storable
        storable_by :settings, theme: { type: :string }
      end
    end

    it "stores a JSON object, not a JSON string scalar" do
      record = klass.create!(theme: "dark")
      raw = klass.connection.select_value("SELECT settings FROM trans_posts WHERE id = #{record.id}")
      expect(JSON.parse(raw)).to eq("theme" => "dark")
    end

    it "keeps a Hash in the attribute, as on a native json column" do
      expect(klass.create!(theme: "dark").reload.read_attribute(:settings)).to be_a(Hash)
    end

    it "finds the row with where_<key>(value)" do
      record = klass.create!(theme: "dark")
      expect(klass.where_theme("dark").to_a).to eq([record])
    end

    it "does not match a row holding a value with where_<key>(nil)" do
      klass.create!(theme: "dark")
      expect(klass.where_theme(nil).to_a).to be_empty
    end
  end

  describe "TRANS-2 Normalizable's settle step rewrites Sanitizable on: :write output" do
    it "stores what validation accepted (:titleize + :strip on: :write)" do
      validated = []
      klass = post_class do
        include ConcernsOnRails::Models::Normalizable
        include ConcernsOnRails::Models::Sanitizable
        normalizable :title, with: :titleize
        sanitizable :title, with: :strip, on: :write
        validate { validated << title }
      end
      record = klass.create!(title: "a < b")
      expect(validated.last).to eq("A &lt; B")
      expect(record.reload.title).to eq("A &lt; B") # observed by trace: "A &Lt; B" (U+226A)
    end

    it "never stores markup in a :strip on: :write column" do
      klass = post_class do
        include ConcernsOnRails::Models::Normalizable
        include ConcernsOnRails::Models::Sanitizable
        normalizable :body, with: ->(v) { CGI.unescapeHTML(v) }
        sanitizable :body, with: :strip, on: :write
      end
      record = klass.create!(body: "&amp;lt;img src=x onerror=alert(1)&amp;gt;<b></b>")
      expect(record.reload.body).not_to include("<img") # trace: "<img src=x onerror=alert(1)>"
    end
  end

  describe "TRANS-3 a halted or rolled-back save, retried, re-applies a non-idempotent rule" do
    it "Normalizable: halted by a later before_save, then saved again" do
      klass = post_class do
        attr_accessor :halt
        include ConcernsOnRails::Models::Normalizable
        normalizable :title, with: ->(v) { "#{v}!" }
        before_save { throw :abort if halt }
      end
      record = klass.new(title: "a", halt: true)
      expect(record.save).to be(false)
      record.halt = false
      record.save!
      expect(record.reload.title).to eq("a!") # trace: "a!!"
    end

    it "Normalizable: first INSERT hits a unique index, the same record is saved again" do
      klass = post_class do
        include ConcernsOnRails::Models::Normalizable
        normalizable :title, with: ->(v) { ERB::Util.html_escape(v).to_str }
      end
      klass.create!(code: "taken", title: "seed")
      record = klass.new(code: "taken", title: "Tom & Jerry")
      expect { record.save! }.to raise_error(ActiveRecord::RecordNotUnique)
      record.code = "free"
      record.save!
      expect(record.reload.title).to eq("Tom &amp; Jerry") # trace: "Tom &amp;amp; Jerry"
    end

    it "Sanitizable on: :write: halted, then saved again" do
      klass = post_class do
        attr_accessor :halt
        include ConcernsOnRails::Models::Sanitizable
        sanitizable :title, with: ->(v) { ERB::Util.html_escape(v).to_str }, on: :write
        before_save { throw :abort if halt }
      end
      record = klass.new(title: "a&b", halt: true)
      expect(record.save).to be(false)
      record.halt = false
      record.save!
      expect(record.reload.title).to eq("a&amp;b") # trace: "a&amp;amp;b"
    end

    it "(control, expected to PASS) a failed validation does not re-apply" do
      klass = post_class do
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

  describe "TRANS-4 Taggable multi-character delimiter" do
    it "reads back the tags it was given" do
      klass = post_class do
        include ConcernsOnRails::Models::Taggable
        taggable_by :tags, delimiter: "--"
      end
      record = klass.new
      record.tag_list = ["a-", "b"]
      expect(record.tag_list).to eq(["a-", "b"]) # trace: ["a", "-b"]
    end
  end
end
