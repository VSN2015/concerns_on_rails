require "spec_helper"

# Audit 2026-10-10 DATA-5: the 1.32.1 fix read a `""` column default as the
# plaintext "", but any OTHER plaintext default (`default: "none"`) still
# reached the decrypter, so `Model.new.notes` — and every `create!`, whose
# dirty tracking deserializes the default — raised DecryptionError: the model
# could not create a record at all. Such a column is now refused at
# declaration (a plaintext default can never be a valid envelope).
describe "Encryptable: a non-empty database default on an encrypted column" do
  before do
    ConcernsOnRails.encryption.key = "concerns-on-rails-column-default-key"
    ConcernsOnRails.encryption.on_missing_key = :raise
    ConcernsOnRails.encryption.raise_on_decrypt_error = true

    ActiveRecord::Schema.define do
      # string, not text: MySQL refuses a default on a TEXT column.
      create_table :encryptable_column_defaults, force: true do |t|
        t.string :notes, default: "none"
        t.string :blank_notes, null: false, default: ""
        t.text :plain_notes
      end
    end
  end

  after(:each) do
    ConcernsOnRails.encryption.key = nil
    ActiveRecord::Base.connection.drop_table(:encryptable_column_defaults, if_exists: true)
  end

  def model_class(table = "encryptable_column_defaults", &declaration)
    klass = Class.new(TestModel) do
      self.table_name = table
      include ConcernsOnRails::Models::Encryptable
    end
    klass.class_eval(&declaration)
    klass
  end

  it "is refused at declaration, naming the column and how to drop the default" do
    expect { model_class { encryptable :notes } }
      .to raise_error(ArgumentError, /':notes' has a database default.*change_column_default :encryptable_column_defaults, :notes/m)
  end

  it "is refused when the field is one of several declared together" do
    expect { model_class { encryptable :plain_notes, :notes } }.to raise_error(ArgumentError, /':notes'/)
  end

  it "keeps a \"\" default (read as the plaintext \"\") and a NULL default working" do
    klass = model_class { encryptable :blank_notes, :plain_notes }

    expect(klass.new.blank_notes).to eq("")
    expect(klass.create!(plain_notes: "x").reload.plain_notes).to eq("x")
    expect(klass.create!(blank_notes: "y").reload.blank_notes).to eq("y")
  end

  it "skips the check while the table does not exist yet, as the column check does" do
    expect { model_class("encryptable_not_migrated_yet") { encryptable :notes } }.not_to raise_error
  end
end
