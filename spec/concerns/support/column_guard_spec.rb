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
      end.to raise_error(ArgumentError, /AddNopeAtToColumnGuardRows nope_at:datetime/)
    end

    it "emits a bare column name when no type is known (generator defaults to string)" do
      expect { klass.ensure_columns!("Spec", :mystery) }.to raise_error(
        ArgumentError,
        %r{Add it with: bin/rails generate migration AddMysteryToColumnGuardRows mystery\z}
      )
    end
  end
end
