require "spec_helper"

# unlock_access! on an instance that reads locked whose row has been deleted:
# lockable_adopt_current_lock! returns false (row gone) but the in-memory
# locked_at is still set, so the method writes to 0 rows, fires the unlock
# hooks and reports success. lock_access! answers false for a gone row.
describe "D unlock_access! on a deleted row" do
  before do
    ActiveRecord::Schema.define do
      create_table :d_gone_accounts, force: true do |t|
        t.integer :failed_attempts, default: 0
        t.datetime :locked_at
      end
    end
  end

  after { ActiveRecord::Base.connection.drop_table(:d_gone_accounts) }

  it "fires no unlock hooks and does not report success" do
    klass = Class.new(TestModel) do
      self.table_name = "d_gone_accounts"
      include ConcernsOnRails::Lockable

      lockable_by
      attr_accessor :events

      def after_unlock = (self.events ||= []) << :after_unlock
    end
    user = klass.create!
    user.lock_access!
    klass.where(id: user.id).delete_all

    result = user.unlock_access!

    expect(user.events).to be_nil # FAILS: [:after_unlock] — an "account unlocked" mail for a deleted row
    expect(result).to be(false)
  end
end
