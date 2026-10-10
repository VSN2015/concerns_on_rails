require "spec_helper"

# Audit 2026-10-10 DATA-4: `encryptable` attaches its type with `attribute`,
# which REPLACES a type decoration declared earlier on the same field. From
# Rails 6.1 a `serialize :notes, coder: JSON` declared before `encryptable
# :notes` was silently dropped (a Hash was persisted as its Ruby `to_s`), and
# from 7.1 a `normalizes :email` declared before it stopped normalizing.
# Such an order is now refused, naming the order that works: `encryptable`
# first. (Rails 6.0 applies `serialize` after every attribute at schema load,
# so there the earlier `serialize` composes and is left alone.)
describe "Encryptable: a serialize/normalizes declared on the field BEFORE encryptable" do
  before do
    ConcernsOnRails.encryption.key = "concerns-on-rails-decoration-key"
    ConcernsOnRails.encryption.on_missing_key = :raise
    ConcernsOnRails.encryption.raise_on_decrypt_error = true

    ActiveRecord::Schema.define do
      create_table :enc_decorated_records, force: true do |t|
        t.text :notes
        t.text :email
        t.string :email_bidx
      end
    end
  end

  after(:each) do
    ConcernsOnRails.encryption.key = nil
    ActiveRecord::Base.connection.drop_table(:enc_decorated_records, if_exists: true)
  end

  def model(&declaration)
    klass = Class.new(TestModel) do
      self.table_name = "enc_decorated_records"
      include ConcernsOnRails::Models::Encryptable
    end
    klass.class_eval(&declaration)
    klass
  end

  def serialize_json(klass, column)
    ActiveRecord.version >= Gem::Version.new("7.1") ? klass.serialize(column, coder: JSON) : klass.serialize(column, JSON)
  end

  let(:serialize_after_attribute_replaces_it) { ActiveRecord.version >= Gem::Version.new("6.1") }

  it "refuses a serialize declared first (it would be dropped and a Hash stored as its to_s)" do
    spec = self
    declare = lambda do
      model do
        spec.serialize_json(self, :notes)
        encryptable :notes
      end
    end

    if serialize_after_attribute_replaces_it
      expect { declare.call }.to raise_error(ArgumentError, /':notes'.*serialize.*declare `encryptable :notes` first/m)
    else
      record = declare.call.create!(notes: { "a" => 1 }) # Rails 6.0: the decoration is applied last and composes
      expect(record.reload.notes).to eq("a" => 1)
    end
  end

  it "keeps the order that works: encryptable, then serialize" do
    spec = self
    klass = model do
      encryptable :notes
      spec.serialize_json(self, :notes)
    end
    record = klass.create!(notes: { "a" => 1 })

    expect(record.reload.notes).to eq("a" => 1)
    expect(record.notes_ciphertext).not_to include("\"a\"")
  end

  it "refuses re-declaring encryptable after a serialize, which would drop it the same way" do
    spec = self
    declare = lambda do
      model do
        encryptable :notes
        spec.serialize_json(self, :notes)
        encryptable :notes
      end
    end

    if serialize_after_attribute_replaces_it
      expect { declare.call }.to raise_error(ArgumentError, /':notes'.*serialize/m)
    else
      expect(declare.call.create!(notes: { "a" => 1 }).reload.notes).to eq("a" => 1)
    end
  end

  it "leaves other fields' serialize alone" do
    spec = self
    klass = model do
      spec.serialize_json(self, :notes)
      encryptable :email
    end

    expect(klass.create!(notes: { "a" => 1 }, email: "a@b.com").reload.notes).to eq("a" => 1)
  end

  context "with normalizes", min_rails: "7.1" do
    it "refuses a normalizes declared first (it would stop normalizing)" do
      declare = lambda do
        model do
          normalizes :email, with: ->(email) { email.strip.downcase }
          encryptable :email, blind_index: true
        end
      end

      expect { declare.call }.to raise_error(ArgumentError, /':email'.*normalizes.*declare `encryptable :email` first/m)
    end

    it "keeps the order that works: encryptable, then normalizes" do
      klass = model do
        encryptable :email, blind_index: true
        normalizes :email, with: ->(email) { email.strip.downcase }
      end
      record = klass.create!(email: " Alice@Example.COM ")

      expect(record.reload.email).to eq("alice@example.com")
      expect(klass.find_by_email(" ALICE@example.com")).to eq(record)
    end
  end
end
