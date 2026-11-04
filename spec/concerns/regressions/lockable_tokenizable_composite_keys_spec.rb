require "spec_helper"

# Audit 2026-10-29 DATA-1: Lockable (register_failed_attempt!, lock_access!,
# unlock_by_token, the lapsed-lock clear, the lost-claim adoption read) and
# Tokenizable's consume_<field> addressed their own row with a hand-built
# `where(primary_key => id)`, which raises ArgumentError on a composite
# primary key (Rails 7.1+). 1.33.0's Support::PrimaryKey fixed the other data
# concerns only. Every site now pairs the key columns up.
describe "Lockable and Tokenizable on a composite primary key", min_rails: "7.1" do
  before do
    ActiveRecord::Schema.define do
      create_table :lt_cpk_users, primary_key: %i[shop_id id], force: true do |t|
        t.integer :shop_id
        t.integer :id
        t.integer :failed_attempts, default: 0
        t.datetime :locked_at
        t.string :unlock_token
        t.string :api_token
      end
    end
  end

  after(:each) { ActiveRecord::Base.connection.drop_table(:lt_cpk_users, if_exists: true) }

  def build_model(**lockable)
    Class.new(TestModel) do
      self.table_name = "lt_cpk_users"
      include ConcernsOnRails::Models::Lockable
      include ConcernsOnRails::Models::Tokenizable

      lockable_by(max_attempts: 2, unlock_token: :unlock_token, **lockable)
      tokenizable_by :api_token
    end
  end

  let(:klass) { build_model }

  it "register_failed_attempt! counts failures on its own row only, and locks at the threshold" do
    user = klass.create!(id: [1, 1])
    other = klass.create!(id: [2, 1])

    expect(user.register_failed_attempt!).to eq(1)
    expect(user.register_failed_attempt!).to eq(2)
    expect(klass.find([1, 1]).locked_at).not_to be_nil
    expect(klass.find([2, 1]).failed_attempts).to eq(0)
    expect(other.reload.locked_at).to be_nil
  end

  it "lock_access! locks only the addressed row" do
    user = klass.create!(id: [1, 1])
    klass.create!(id: [2, 1])

    expect(user.lock_access!).to be(true)
    expect(klass.find([1, 1]).locked_at).not_to be_nil
    expect(klass.find([2, 1]).locked_at).to be_nil
  end

  it "a stale instance that loses the lock claim adopts the row's lock (the locking read)" do
    stale = klass.find(klass.create!(id: [1, 1]).id)
    klass.find([1, 1]).lock_access!

    expect(stale.lock_access!).to be(true)
    expect(stale.locked_at).not_to be_nil
    expect(stale.unlock_token).to eq(klass.find([1, 1]).unlock_token)
  end

  it "unlock_by_token unlocks only the addressed row and consumes its token" do
    user = klass.create!(id: [1, 1], locked_at: Time.current, unlock_token: "tok")
    klass.create!(id: [2, 1], locked_at: Time.current, unlock_token: "tok2")

    expect(klass.unlock_by_token("tok")).to eq(user)
    expect(klass.find([1, 1]).locked_at).to be_nil
    expect(klass.find([1, 1]).unlock_token).to be_nil
    expect(klass.find([2, 1]).locked_at).not_to be_nil
    expect(klass.unlock_by_token("tok")).to be_nil
  end

  it "unlock_by_token retires a token whose lock is gone (lockable_retire_token)" do
    klass.create!(id: [1, 1], locked_at: nil, unlock_token: "stale")

    expect(klass.unlock_by_token("stale")).to be_nil
    expect(klass.find([1, 1]).unlock_token).to be_nil
  end

  it "the lapsed-lock clear in register_failed_attempt! works" do
    expiring = build_model(unlock_in: 1.hour)
    user = expiring.create!(id: [1, 1], locked_at: 2.hours.ago, failed_attempts: 2)

    expect(user.register_failed_attempt!).to eq(1)
    expect(expiring.find([1, 1]).locked_at).to be_nil
    expect(expiring.find([1, 1]).failed_attempts).to eq(1)
  end

  it "Tokenizable consume_<field> consumes only the addressed row's token" do
    user = klass.create!(id: [1, 1])
    other = klass.create!(id: [2, 1])

    expect(klass.consume_api_token(user.api_token)).to eq(user)
    expect(klass.find([1, 1]).api_token).to be_nil
    expect(klass.find([2, 1]).api_token).to eq(other.api_token)
    expect(klass.consume_api_token(user.api_token)).to be_nil
  end
end
