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

  it "register_failed_attempt! on a stale unlocked instance does not count while the row is locked" do
    id = klass.create!.id
    stale = klass.find(id)
    klass.find(id).lock_access!
    expect(stale.register_failed_attempt!).to eq(0)
    expect(klass.find(id).failed_attempts).to eq(0)
    expect(stale.access_locked?).to be(true)
  end

  it "still counts while the row is unlocked" do
    user = klass.create!
    expect(user.register_failed_attempt!).to eq(1)
    expect(klass.find(user.id).failed_attempts).to eq(1)
  end
end
