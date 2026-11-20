require "spec_helper"

# json >= 3 raises on a duplicate object key (2.x: last wins), and String#strip raises on invalid
# UTF-8; both used to turn a stored column into {} / [] (Storable then erased every other key on
# the next write). Spec Hashes with String keys were accepted but ignored. Auditable raised
# JSON::GeneratorError on a tracked binary value that is not UTF-8. Taggable#tagged_with?
# mangled an Array argument.
describe "JSON data handling fixes" do
  describe ConcernsOnRails::Storable do
    before do
      ActiveRecord::Schema.define do
        create_table :json_data_rows, force: true do |t|
          t.text :settings
        end
      end
    end
    after { ActiveRecord::Base.connection.drop_table(:json_data_rows) }

    let(:klass) do
      Class.new(TestModel) do
        self.table_name = "json_data_rows"
        include ConcernsOnRails::Storable
        storable_by :settings, theme: { type: :string, default: "light" }, plan: { type: :string }
      end
    end

    it "keeps the other keys when a stored duplicate key is read and one key is written" do
      record = klass.create!
      record.update_column(:settings, '{"plan":"pro","theme":"dark","theme":"blue"}')
      record.reload
      expect(record.theme).to eq("blue") # last duplicate wins, as on json 2.x
      record.update!(theme: "light")
      expect(JSON.parse(klass.connection.select_value("SELECT settings FROM json_data_rows"))).to eq("plan" => "pro", "theme" => "light")
    end

    it "reads invalid UTF-8 column bytes as {} instead of raising" do
      record = klass.new
      record.settings = "\xff {}".dup.force_encoding("UTF-8")
      expect(record.theme).to eq("light")
    end

    it "honours type:/default: given as String keys" do
      string_keyed = Class.new(TestModel) do
        self.table_name = "json_data_rows"
        include ConcernsOnRails::Storable
        storable_by :settings, { beta: { "type" => :boolean, "default" => true } }
      end
      record = string_keyed.new
      expect(record.beta).to eq(true)
      record.beta = "0"
      expect(record.beta).to eq(false)
    end
  end

  describe ConcernsOnRails::Models::Auditable do
    before do
      ActiveRecord::Schema.define do
        create_table :json_data_audits, force: true do |t|
          t.binary :digest
          t.string :name
          t.text :audit_log
        end
      end
    end
    after { ActiveRecord::Base.connection.drop_table(:json_data_audits) }

    let(:klass) do
      Class.new(TestModel) do
        self.table_name = "json_data_audits"
        include ConcernsOnRails::Models::Auditable
        auditable_by :digest, :name
      end
    end

    it "records a tracked binary value that is not UTF-8 as base64 and keeps saving" do
      record = klass.create!(name: "a")
      expect { record.update!(digest: "\xFF\xFE".b) }.not_to raise_error
      expect(record.reload.audit_trail.last).to include("field" => "digest", "to" => "base64://4=")
    end

    it "leaves a binary value that is valid UTF-8 as the text it already was" do
      record = klass.create!(name: "a")
      record.update!(digest: "abc".b)
      expect(record.reload.audit_trail.last["to"]).to eq("abc")
    end

    it "stores a non-ASCII binary value that is valid UTF-8 as that text (not ASCII-8BIT)" do
      record = klass.create!(name: "a")
      expect { record.update!(digest: "café".b) }.not_to raise_error
      expect(record.reload.audit_trail.last["to"]).to eq("café")
    end

    it "truncates a base64 blob on its raw bytes, keeping a decodable payload" do
      limited = Class.new(TestModel) do
        self.table_name = "json_data_audits"
        include ConcernsOnRails::Models::Auditable
        auditable_by :digest, max_value_length: 3
      end
      record = limited.create!
      record.update!(digest: "\xFF\xFE\xFD\xFC\xFB".b)
      to = record.reload.audit_trail.last["to"]
      expect(to).to eq("base64:#{["\xFF\xFE\xFD".b].pack('m0')}…")
    end

    it "stores a non-UTF-8 String nested in an Array value without raising" do
      record = klass.create!(name: "a")
      allow(record).to receive(:auditable_tracked_changes).and_return("digest" => [nil, ["x", "\xFF".b]])
      expect { record.update!(name: "b") }.not_to raise_error
      expect(record.reload.audit_trail.map { |e| e["to"] }).to include(["x", "base64:/w=="])
    end

    it "reads a trail carrying a duplicate key (last wins) instead of dropping it" do
      record = klass.create!(name: "a")
      record.update_column(:audit_log, '[{"field":"name","from":null,"to":"x","to":"a","at":"2020-01-01T00:00:00Z"}]')
      expect(klass.find(record.id).audit_trail.first["to"]).to eq("a")
    end
  end

  describe "native json columns holding a duplicate key (Rails reads them as nil)" do
    before do
      ActiveRecord::Schema.define do
        create_table :json_data_native, force: true do |t|
          t.json :settings
          t.json :audit_log
          t.string :name
        end
      end
    end
    after { ActiveRecord::Base.connection.drop_table(:json_data_native) }

    it "Storable keeps the other keys when one key is written" do
      klass = Class.new(TestModel) do
        self.table_name = "json_data_native"
        include ConcernsOnRails::Storable
        storable_by :settings, theme: { type: :string, default: "light" }, plan: { type: :string }
      end
      record = klass.create!
      klass.connection.execute(%q(UPDATE json_data_native SET settings = '{"plan":"pro","theme":"a","theme":"dark"}'))
      record = klass.find(record.id)
      expect(record.theme).to eq("dark")
      record.update!(theme: "blue")
      expect(klass.find(record.id).settings).to eq("plan" => "pro", "theme" => "blue")
    end

    it "Auditable keeps the existing trail" do
      klass = Class.new(TestModel) do
        self.table_name = "json_data_native"
        include ConcernsOnRails::Models::Auditable
        auditable_by :name
      end
      record = klass.create!(name: "a")
      klass.connection.execute(
        %q(UPDATE json_data_native SET audit_log = '[{"field":"name","from":null,"to":"a","to":"a","at":"2020-01-01T00:00:00Z"}]')
      )
      record = klass.find(record.id)
      expect(record.audit_trail.size).to eq(1)
      record.update!(name: "b")
      expect(klass.find(record.id).audit_trail.map { |e| e["to"] }).to eq(%w[a b])
    end
  end

  describe ConcernsOnRails::Taggable do
    before do
      ActiveRecord::Schema.define { create_table(:json_data_tags, force: true) { |t| t.string :tags } }
    end
    after { ActiveRecord::Base.connection.drop_table(:json_data_tags) }

    let(:klass) do
      Class.new(TestModel) do
        self.table_name = "json_data_tags"
        include ConcernsOnRails::Taggable
        taggable_by :tags
      end
    end

    it "tagged_with? checks every element of an Array, like its siblings" do
      record = klass.new(tag_list: %w[ruby rails])
      expect(record.tagged_with?(%w[ruby rails])).to be(true)
      expect(record.tagged_with?(%w[ruby go])).to be(false)
      expect(record.tagged_with?([])).to be(false)
      expect(record.tagged_with?("ruby,rails")).to be(true)
    end
  end
end
