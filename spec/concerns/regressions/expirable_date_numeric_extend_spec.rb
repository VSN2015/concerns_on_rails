require "spec_helper"

describe "Expirable extend_expiry!(by: Numeric) on a date column" do
  before do
    ActiveRecord::Schema.define do
      create_table :c_date_tokens, force: true do |t|
        t.date :expires_at
      end
    end
  end
  after { ActiveRecord::Base.connection.drop_table(:c_date_tokens) }

  let(:klass) do
    Class.new(TestModel) do
      self.table_name = "c_date_tokens"
      include ConcernsOnRails::Expirable

      expirable_by
    end
  end

  it "treats a Numeric `by:` as SECONDS (one day = 86_400), as documented" do
    token = klass.create!(expires_at: Date.current + 10)
    token.extend_expiry!(by: 86_400)
    expect(token.reload.expires_at).to eq(Date.current + 11)
  end

  it "agrees with the Duration form" do
    a = klass.create!(expires_at: Date.current + 10)
    b = klass.create!(expires_at: Date.current + 10)
    a.extend_expiry!(by: 1.day)
    b.extend_expiry!(by: 1.day.to_i)
    expect(b.reload.expires_at).to eq(a.reload.expires_at)
  end

  it "extends an expired date expiry from today by the seconds given" do
    token = klass.create!(expires_at: Date.current - 5)
    token.extend_expiry!(by: 2 * 86_400)
    expect(token.reload.expires_at).to eq(Date.current + 2)
  end

  it "expire_in! with a Numeric is seconds too" do
    token = klass.create!(expires_at: Date.current)
    token.expire_in!(3 * 86_400)
    expect(token.reload.expires_at).to eq(Date.current + 3)
  end
end
