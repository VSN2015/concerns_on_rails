require "spec_helper"
require "json"

# TRANS-1: Storable (and Auditable) decided "native JSON column" from the
# COLUMN type alone, so PostgreSQL's jsonb and an `attribute :x, :json` override
# over a text column were handed a generated JSON String, which the Json type
# stored as a JSON string scalar. One shared detection (Support::NativeJson)
# now backs both concerns. PostgreSQL's OID::Jsonb reports `type == :jsonb`
# and takes the same branch as the `:json` attribute exercised here.
RSpec.describe "native JSON attribute detection (Storable + Auditable)" do
  before do
    ActiveRecord::Schema.define do
      create_table :native_json_posts, force: true do |t|
        t.string :title
        t.text :settings
        t.text :audit
        t.text :plain
      end
    end
  end

  after { ActiveRecord::Base.connection.drop_table(:native_json_posts, if_exists: true) }

  def model(&body)
    klass = Class.new(TestModel) { self.table_name = "native_json_posts" }
    klass.class_eval(&body)
    klass
  end

  def raw_column(klass, record, column)
    klass.connection.select_value("SELECT #{column} FROM native_json_posts WHERE id = #{record.id}")
  end

  describe "Storable over an `attribute :settings, :json` text column" do
    let(:klass) do
      model do
        attribute :settings, :json
        include ConcernsOnRails::Models::Storable

        storable_by :settings, theme: { type: :string }, size: { type: :integer }
      end
    end

    it "stores a JSON object, not a string scalar, and keeps a Hash in the attribute" do
      record = klass.create!(theme: "dark")
      expect(JSON.parse(raw_column(klass, record, "settings"))).to eq("theme" => "dark")
      expect(record.reload.read_attribute(:settings)).to be_a(Hash)
    end

    it "writing a second key to an existing row keeps it an object" do
      record = klass.create!(theme: "dark")
      record.update!(size: 3)
      expect(JSON.parse(raw_column(klass, record, "settings"))).to eq("theme" => "dark", "size" => 3)
    end

    it "answers where_<key> by value and does not fail open on nil" do
      dark = klass.create!(theme: "dark")
      klass.create!(theme: "light")
      expect(klass.where_theme("dark").to_a).to eq([dark])
      expect(klass.where_theme(nil).to_a).to be_empty
    end
  end

  describe "Auditable over an `attribute :audit, :json` text column" do
    let(:klass) do
      model do
        attribute :audit, :json
        include ConcernsOnRails::Models::Auditable

        auditable_by :title, into: :audit
      end
    end

    it "stores the trail as a JSON array, not a string scalar" do
      record = klass.create!(title: "a")
      record.update!(title: "b")
      stored = JSON.parse(raw_column(klass, record, "audit"))
      expect(stored).to be_an(Array)
      expect(stored.last).to include("field" => "title", "from" => "a", "to" => "b")
      expect(record.reload.audit_trail.size).to eq(2)
    end
  end

  describe "Support::NativeJson.column?" do
    let(:klass) do
      model do
        attribute :settings, :json
        serialize :plain, coder: JSON if ActiveRecord.version >= Gem::Version.new("7.1")
      end
    end

    it "is true for a json attribute and false for a plain text column" do
      expect(ConcernsOnRails::Support::NativeJson.column?(klass, :settings)).to be(true)
      expect(ConcernsOnRails::Support::NativeJson.column?(klass, :title)).to be(false)
      expect(ConcernsOnRails::Support::NativeJson.column?(klass, :missing_column)).to be(false)
    end

    it "is true for a `serialize`d column", min_rails: "7.1" do
      expect(ConcernsOnRails::Support::NativeJson.column?(klass, :plain)).to be(true)
    end
  end
end
