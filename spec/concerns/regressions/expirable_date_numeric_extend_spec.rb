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

  # Guard, not a regression: expire_in! adds to a Time and was always right.
  it "expire_in! with a Numeric is seconds too" do
    token = klass.create!(expires_at: Date.current)
    token.expire_in!(3 * 86_400)
    expect(token.reload.expires_at).to eq(Date.current + 3)
  end

  it "adds a calendar day on a DST fall-back day (25-hour day)" do
    Time.use_zone("America/New_York") do
      travel_to Time.zone.local(2026, 10, 31, 12) do
        token = klass.create!(expires_at: Date.new(2026, 11, 1))
        expect(token.extend_expiry!(by: 86_400)).to be(true)
        expect(token.reload.expires_at).to eq(Date.new(2026, 11, 2))
      end
    end
  end

  it "keeps adding exact seconds on a datetime column across the same day" do
    ActiveRecord::Schema.define { create_table(:c_dt_tokens, force: true) { |t| t.datetime :expires_at } }
    dt = Class.new(TestModel) do
      self.table_name = "c_dt_tokens"
      include ConcernsOnRails::Expirable

      expirable_by
    end
    Time.use_zone("America/New_York") do
      travel_to Time.zone.local(2026, 10, 31, 12) do
        start = Time.zone.local(2026, 11, 1, 0, 30)
        record = dt.create!(expires_at: start)
        record.extend_expiry!(by: 86_400)
        expect(record.reload.expires_at).to be_within(1).of(start + 86_400)
      end
    end
  ensure
    ActiveRecord::Base.connection.drop_table(:c_dt_tokens)
  end
end
