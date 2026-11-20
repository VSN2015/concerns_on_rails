require "spec_helper"

# unlock_expired's per-record path (taken whenever an unlock hook is
# overridden, or on any STI table) never re-checks that the lock is still
# lapsed: unlock_access! adopts the row's CURRENT lock and clears it. A row
# re-locked (fresh lock) after the batch SELECT loaded it is unlocked anyway;
# the fast path's UPDATE ... WHERE locked_at <= cutoff would leave it locked.
describe "D unlock_expired per-record path wipes a fresh lock" do
  before do
    ActiveRecord::Schema.define do
      create_table :d_accounts, force: true do |t|
        t.integer :failed_attempts, default: 0
        t.datetime :locked_at
      end
    end
  end

  after { ActiveRecord::Base.connection.drop_table(:d_accounts) }

  it "leaves a row re-locked mid-batch locked" do
    klass = Class.new(TestModel) do
      self.table_name = "d_accounts"
      include ConcernsOnRails::Lockable

      lockable_by unlock_in: 15.minutes
      cattr_accessor :relock_id

      # Stands in for a concurrent request that locks B (5 failed logins)
      # while the sweep is still working through the batch it loaded.
      def after_unlock
        return unless relock_id && id != relock_id

        self.class.unscoped.where(id: relock_id).update_all(locked_at: Time.current, failed_attempts: 5)
        self.relock_id = nil
      end
    end
    a = klass.create!(failed_attempts: 5, locked_at: 1.hour.ago)
    b = klass.create!(failed_attempts: 5, locked_at: 1.hour.ago)
    klass.relock_id = b.id

    count = klass.unlock_expired

    expect(b.reload.locked_at).not_to be_nil # FAILS: the fresh lock was cleared
    expect(count).to eq(1)
    expect(a.reload.locked_at).to be_nil
  end
end
