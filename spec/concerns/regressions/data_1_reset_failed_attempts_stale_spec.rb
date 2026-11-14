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

  it "reset_failed_attempts! on an instance loaded before concurrent failures still zeroes the row" do
    id = klass.create!.id
    login = klass.find(id)
    3.times { klass.find(id).register_failed_attempt! }
    expect(login.reset_failed_attempts!).to be(true)
    expect(klass.find(id).failed_attempts).to eq(0)
    expect(login.failed_attempts).to eq(0)
    expect(login).not_to be_changed
  end

  it "does not bump lock_version or touch the lock" do
    id = klass.create!.id
    login = klass.find(id)
    3.times { klass.find(id).register_failed_attempt! }
    before = klass.find(id).lock_version
    login.reset_failed_attempts!
    expect(klass.find(id).lock_version).to eq(before)
    expect { login.save! }.not_to raise_error
  end

  it "stays a hook-free true when the row is already zero" do
    user = klass.create!
    expect(user.reset_failed_attempts!).to be(true)
    expect(user.events).to be_nil
  end
end
