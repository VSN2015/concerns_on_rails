require "spec_helper"

describe "Lockable decides from the row, not the instance" do
  before do
    ActiveRecord::Base.logger = nil
    ActiveRecord::Schema.define do
      create_table :data_lk_users, force: true do |t|
        t.integer :failed_attempts, default: 0
        t.datetime :locked_at
        t.integer :lock_version, default: 0, null: false
      end
    end
  end
  after(:each) { ActiveRecord::Base.connection.drop_table(:data_lk_users, if_exists: true) }

  let(:klass) do
    Class.new(TestModel) do
      self.table_name = "data_lk_users"
      attr_reader :events

      include ConcernsOnRails::Models::Lockable

      lockable_by max_attempts: 5

      def before_unlock = (@events ||= []) << :before_unlock
      def after_unlock = (@events ||= []) << :after_unlock
    end
  end

  it "unlock_access! on an instance loaded before the lock unlocks the row and fires hooks" do
    id = klass.create!.id
    admin_view = klass.find(id)
    klass.find(id).lock_access!
    expect(admin_view.unlock_access!).to be(true)
    row = klass.find(id)
    expect(row.locked_at).to be_nil
    expect(row.failed_attempts).to eq(0)
    expect(admin_view.events).to eq(%i[before_unlock after_unlock])
    expect(admin_view.access_locked?).to be(false)
  end

  it "stays a hook-free true when neither the instance nor the row is locked" do
    user = klass.create!
    expect(user.unlock_access!).to be(true)
    expect(user.events).to be_nil
  end

  it "does not fire hooks again from a stale locked instance once the row is unlocked" do
    id = klass.create!.id
    klass.find(id).lock_access!
    stale = klass.find(id)
    klass.find(id).unlock_access!
    expect(stale.unlock_access!).to be(true)
    expect(stale.events).to be_nil
    expect(stale.access_locked?).to be(false)
  end

  it "unlocks through an instance locked in memory with a stale lock_version (the old update_columns case)" do
    id = klass.create!.id
    klass.find(id).lock_access!
    stale = klass.find(id)
    klass.find(id).update!(failed_attempts: 2) # bumps lock_version past the stale instance's
    expect(stale.unlock_access!).to be(true)
    expect(klass.find(id).locked_at).to be_nil
    expect(klass.find(id).failed_attempts).to eq(0)
    expect(stale.events).to eq(%i[before_unlock after_unlock])
  end
end
