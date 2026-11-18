require "spec_helper"

describe "Lockable decides from the row for an instance loaded LOCKED" do
  before do
    ActiveRecord::Base.logger = nil
    ActiveRecord::Schema.define do
      create_table :data_lk_stale_locked, force: true do |t|
        t.integer :failed_attempts, default: 0
        t.datetime :locked_at
      end
    end
  end
  after(:each) { ActiveRecord::Base.connection.drop_table(:data_lk_stale_locked, if_exists: true) }

  let(:klass) do
    Class.new(TestModel) do
      self.table_name = "data_lk_stale_locked"
      attr_reader :events

      include ConcernsOnRails::Models::Lockable

      lockable_by max_attempts: 5

      def after_lock = (@events ||= []) << :after_lock
    end
  end

  it "register_failed_attempt! counts once the row was unlocked by someone else" do
    id = klass.create!.id
    klass.find(id).lock_access!
    login = klass.find(id)
    klass.find(id).unlock_access!
    expect(login.register_failed_attempt!).to eq(1)
    expect(klass.find(id).failed_attempts).to eq(1)
    expect(login.access_locked?).to be(false)
  end

  it "lock_access! really locks a row unlocked since the instance was loaded" do
    id = klass.create!.id
    klass.find(id).lock_access!
    admin = klass.find(id)
    klass.find(id).unlock_access!
    expect(admin.lock_access!).to be(true)
    expect(klass.find(id).locked_at).not_to be_nil
    expect(admin.events).to eq([:after_lock])
  end

  it "lock_access! on a row that is still locked fires no hooks" do
    id = klass.create!.id
    klass.find(id).lock_access!
    admin = klass.find(id)
    expect(admin.lock_access!).to be(true)
    expect(admin.events).to be_nil
  end

  it "register_failed_attempt! still adopts a row that is still locked" do
    id = klass.create!.id
    klass.find(id).lock_access!
    expect(klass.find(id).register_failed_attempt!).to eq(0)
    expect(klass.find(id).failed_attempts).to eq(0)
  end
end
