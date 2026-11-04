require "spec_helper"

# Audit 2026-10-29 DATA-3: a NUL byte in a looked-up token (`?token=%00`;
# Rack decodes it, Rails' parameter check only refuses invalid UTF-8) made
# authenticate_by_<field>, consume_<field> and unlock_by_token raise on
# PostgreSQL, whose driver refuses NUL in a bound text parameter (a 500
# instead of the documented nil "like a wrong token"). Filterable got
# ScalarParam.nul_free? in 1.33.0 (#152); these lookups now answer nil before
# any query. SQLite binds NUL without error, so the spec asserts the
# observable half that holds on every adapter: nil, and no SQL touching the
# table at all.
describe "Token lookups with a NUL byte" do
  before do
    ActiveRecord::Schema.define do
      create_table :nul_token_users, force: true do |t|
        t.string :api_token
        t.integer :failed_attempts, default: 0
        t.datetime :locked_at
        t.string :unlock_token
      end
    end
  end

  after(:each) { ActiveRecord::Base.connection.drop_table(:nul_token_users, if_exists: true) }

  let(:klass) do
    Class.new(TestModel) do
      self.table_name = "nul_token_users"
      include ConcernsOnRails::Models::Tokenizable
      include ConcernsOnRails::Models::Lockable

      tokenizable_by :api_token
      lockable_by unlock_token: :unlock_token
    end
  end

  def statements_on_table(&block)
    statements = []
    callback = lambda do |*, payload|
      statements << payload[:sql] if payload[:name] != "SCHEMA" && payload[:sql].include?("nul_token_users")
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)
    statements
  end

  it "authenticate_by_<field> answers nil without querying" do
    klass.create!
    expect(statements_on_table { expect(klass.authenticate_by_api_token("a\u0000b")).to be_nil }).to be_empty
    expect(statements_on_table { expect(klass.authenticate_by_api_token("\u0000")).to be_nil }).to be_empty
  end

  it "consume_<field> answers nil without querying" do
    klass.create!
    expect(statements_on_table { expect(klass.consume_api_token("a\u0000b")).to be_nil }).to be_empty
  end

  it "unlock_by_token answers nil without querying" do
    klass.create!(locked_at: Time.current, unlock_token: "tok")
    expect(statements_on_table { expect(klass.unlock_by_token("a\u0000b")).to be_nil }).to be_empty
    expect(klass.find_by(unlock_token: "tok").locked_at).not_to be_nil
  end

  it "ordinary tokens, and an Integer code, still authenticate" do
    user = klass.create!
    expect(klass.authenticate_by_api_token(user.api_token)).to eq(user)
    expect(klass.consume_api_token(user.api_token)).to eq(user)

    locked = klass.create!(locked_at: Time.current, unlock_token: "tok")
    expect(klass.unlock_by_token("tok")).to eq(locked)
  end
end
