require "spec_helper"

# Audit 2026-10-29 DATA-4: register_failed_attempt! on a readonly! record
# incremented the counter in SQL (a class-level update_counters, which ignores
# readonly?) and only then raised ReadOnlyRecord from lock_access!, leaving
# the row at max_attempts and unlocked. lock_access! and the lapsed-lock clear
# already replicate update_columns' readonly/destroyed preconditions; the
# increment now does too, before anything is written.
describe "Lockable#register_failed_attempt! on a readonly or destroyed record" do
  before do
    ActiveRecord::Schema.define do
      create_table :lk_ro_users, force: true do |t|
        t.integer :failed_attempts, default: 0
        t.datetime :locked_at
      end
    end
  end

  after(:each) { ActiveRecord::Base.connection.drop_table(:lk_ro_users, if_exists: true) }

  let(:klass) do
    Class.new(TestModel) do
      self.table_name = "lk_ro_users"
      include ConcernsOnRails::Models::Lockable

      lockable_by max_attempts: 1
    end
  end

  it "raises ReadOnlyRecord and writes nothing for a readonly! record below the threshold" do
    below = Class.new(klass) { lockable_by max_attempts: 5 }
    id = below.create!.id
    record = below.find(id)
    record.readonly!

    expect { record.register_failed_attempt! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    expect(below.find(id).failed_attempts).to eq(0)
  end

  it "raises ReadOnlyRecord and leaves the row unlocked AND uncounted at the threshold" do
    id = klass.create!.id
    record = klass.find(id)
    record.readonly!

    expect { record.register_failed_attempt! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    row = klass.find(id)
    expect(row.failed_attempts).to eq(0)
    expect(row.locked_at).to be_nil
  end

  it "raises and writes nothing for a destroyed record" do
    record = klass.create!
    record.destroy
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql] =~ /UPDATE/i }

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      expect { record.register_failed_attempt! }.to raise_error(ActiveRecord::ActiveRecordError, /destroyed/)
    end
    expect(queries).to be_empty
  end

  it "still counts on a writable record" do
    record = klass.create!
    expect(record.register_failed_attempt!).to eq(1)
    expect(klass.find(record.id).locked_at).not_to be_nil
  end

  it "keeps answering the count (no write, no raise) for an already-locked readonly record" do
    record = klass.create!
    record.lock_access!
    readonly = klass.find(record.id)
    readonly.readonly!

    expect { readonly.register_failed_attempt! }.not_to raise_error
  end
end
