require "spec_helper"

RSpec.describe ConcernsOnRails::Support::ColumnGuard do
  before do
    ActiveRecord::Schema.define do
      create_table :column_guard_rows, force: true do |t|
        t.boolean :active
        t.string :name
      end
    end
  end

  after { ActiveRecord::Base.connection.drop_table(:column_guard_rows) }

  let(:klass) do
    Class.new(TestModel) do
      self.table_name = "column_guard_rows"
      include ConcernsOnRails::Models::Activatable
    end
  end

  it "still raises the labeled error for a missing column when the schema is reachable" do
    expect { klass.activatable_by(:nope) }.to raise_error(ArgumentError, /does not exist/)
  end

  it "returns true when every column exists" do
    expect(klass.ensure_columns!("Spec", :name, :active)).to be(true)
  end

  it "skips (returns false) for a not-yet-migrated table so class loading survives (1.22)" do
    pending_table = Class.new(TestModel) do
      self.table_name = "not_migrated_yet"
      include ConcernsOnRails::Models::Activatable
    end
    expect { pending_table.activatable_by(:whatever) }.not_to raise_error
    expect(pending_table.ensure_columns!("Spec", :whatever)).to be(false)
  end

  it "skips when the connection is unavailable — the db:create / assets:precompile scenario (1.22)" do
    allow(klass).to receive(:table_exists?).and_raise(ActiveRecord::ConnectionNotEstablished)
    expect(klass.ensure_columns!("Spec", :name)).to be(false)
  end

  it "lets real bugs surface — the rescue is scoped to ActiveRecord errors" do
    allow(klass).to receive(:table_exists?).and_return(true)
    allow(klass).to receive(:column_names).and_raise(NameError, "a real bug")
    expect { klass.ensure_columns!("Spec", :name) }.to raise_error(NameError)
  end

  it "validates columns on another class via ensure_columns_on!" do
    expect(klass.ensure_columns_on!("Spec", klass, :name)).to be(true)
    expect { klass.ensure_columns_on!("Spec", klass, :nope) }.to raise_error(ArgumentError, /does not exist/)
  end

  describe "migration hints (the teaching error)" do
    it "appends a ready-to-paste generator command with the concern's expected type" do
      expect { klass.activatable_by(:enabled) }.to raise_error(
        ArgumentError,
        %r{Add it with: bin/rails generate migration AddEnabledToColumnGuardRows enabled:boolean}
      )
    end

    it "supports per-field types (and generator modifiers) via a types: Hash" do
      expect do
        klass.ensure_columns!("Spec", :nope_at, :token, types: { nope_at: :datetime, token: "string:uniq" })
      end.to raise_error(ArgumentError, /AddSpecColumnsToColumnGuardRows nope_at:datetime token:string:uniq\z/)
    end

    it "emits a bare column name when no type is known (generator defaults to string)" do
      expect { klass.ensure_columns!("Spec", :mystery) }.to raise_error(
        ArgumentError,
        %r{Add it with: bin/rails generate migration AddMysteryToColumnGuardRows mystery\z}
      )
    end
  end
  # One ensure_columns! call used to raise on the FIRST missing column, so a
  # fresh model with five absent columns meant five boot failures. Now every
  # missing column is reported at once, with ONE combined migration command.
  describe "reporting every missing column at once" do
    it "lists all missing columns in one error, grammatically, with a single combined migration command" do
      expect do
        klass.ensure_columns!("ConcernsOnRails::Models::Addressable", :street, :name, :city, :zip,
                              types: { street: :string, city: :string, zip: "string:index" })
      end.to raise_error(ArgumentError) { |error|
        expect(error.message).to eq(
          "ConcernsOnRails::Models::Addressable: 'street', 'city' and 'zip' do not exist in the database " \
          "(table: column_guard_rows). Add them with: bin/rails generate migration " \
          "AddAddressableColumnsToColumnGuardRows street:string city:string zip:string:index"
        )
      }
    end

    it "keeps the single-column wording and generator name unchanged" do
      expect { klass.ensure_columns!("Spec", :name, :nope, types: :datetime) }.to raise_error(
        ArgumentError,
        "Spec: 'nope' does not exist in the database (table: column_guard_rows). " \
        "Add it with: bin/rails generate migration AddNopeToColumnGuardRows nope:datetime"
      )
    end

    it "applies a scalar types: to every missing column and dedupes repeated fields" do
      expect { klass.ensure_columns!("Spec", :a_at, :b_at, :a_at, types: :datetime) }.to raise_error(
        ArgumentError,
        /'a_at' and 'b_at' do not exist.*AddSpecColumnsToColumnGuardRows a_at:datetime b_at:datetime\z/
      )
    end

    it "names the combined migration after the concern (demodulized), bare columns when no type is known" do
      expect { klass.ensure_columns!("ConcernsOnRails::Models::Lockable", :x, :y) }
        .to raise_error(ArgumentError, %r{Add them with: bin/rails generate migration AddLockableColumnsToColumnGuardRows x y\z})
    end

    it "works through ensure_columns_on! against another class" do
      expect { klass.ensure_columns_on!("Spec", klass, :p, :q) }
        .to raise_error(ArgumentError, /'p' and 'q' do not exist/)
    end

    it "column_migration_hint still accepts a single field (helper contract)" do
      expect(klass.column_migration_hint(klass, :deleted_at, :datetime))
        .to eq(" Add it with: bin/rails generate migration AddDeletedAtToColumnGuardRows deleted_at:datetime")
    end
  end
end
