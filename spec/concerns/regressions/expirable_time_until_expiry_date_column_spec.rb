require "spec_helper"

# Audit 2026-10-29 (STATE-1): `time_until_expiry` subtracted the Time.zone
# instant from a `date` column's Date, which raises TypeError for a future
# date (only the past/today branch worked, through Date#<=> coercion). It now
# agrees with `expired?`: a date is expired from the start of that day in
# Time.zone, so the time left is measured to that instant.
describe "Expirable#time_until_expiry on a date column" do
  # 08:00 on Oct 10 in Tokyo is 23:00 on Oct 9 in UTC.
  let(:tokyo_morning) { Time.find_zone("Tokyo").local(2026, 10, 10, 8, 0) }
  let(:today) { Date.new(2026, 10, 10) }

  around do |example|
    Time.use_zone("Tokyo") { example.run }
  end

  before do
    ActiveRecord::Schema.define do
      create_table :tue_tokens, force: true do |t|
        t.date :expires_on
        t.datetime :expires_at
      end
    end
  end

  after do
    ActiveRecord::Base.connection.drop_table(:tue_tokens, if_exists: true)
  end

  let(:model) do
    Class.new(TestModel) do
      self.table_name = "tue_tokens"
      include ConcernsOnRails::Expirable

      expirable_by :expires_on
    end
  end

  it "answers the time left to the start of a future date in Time.zone" do
    travel_to(tokyo_morning) do
      token = model.create!(expires_on: today + 3)
      remaining = nil

      expect { remaining = token.time_until_expiry }.not_to raise_error
      expect(token).not_to be_expired
      expect(remaining).to be_within(1).of(Time.zone.local(2026, 10, 13) - tokyo_morning)
      expect(remaining).to be > 0
    end
  end

  it "answers the time left for a date that is tomorrow" do
    travel_to(tokyo_morning) do
      token = model.create!(expires_on: today + 1)

      expect(token.time_until_expiry).to be_within(1).of(16.hours)
    end
  end

  it "is 0 for today, as expired? says (expired from the start of the day in Time.zone)" do
    travel_to(tokyo_morning) do
      token = model.create!(expires_on: today)

      expect(token).to be_expired
      expect(token.time_until_expiry).to eq(0.seconds)
    end
  end

  it "is 0 for a past date" do
    travel_to(tokyo_morning) do
      token = model.create!(expires_on: today - 5)

      expect(token).to be_expired
      expect(token.time_until_expiry).to eq(0.seconds)
    end
  end

  it "is nil without an expiry" do
    travel_to(tokyo_morning) do
      expect(model.create!.time_until_expiry).to be_nil
    end
  end

  it "agrees with expired? for the date the zone is on while UTC is still the day before" do
    # 23:00 UTC Oct 9 = 08:00 Oct 10 Tokyo; today (Tokyo) is Oct 10.
    travel_to(tokyo_morning) do
      token = model.create!(expires_on: Date.new(2026, 10, 10))

      expect(token.expired?).to be(true)
      expect(token.time_until_expiry).to eq(0.seconds)
    end
  end

  it "keeps answering a Duration on a datetime column" do
    datetime_model = Class.new(TestModel) do
      self.table_name = "tue_tokens"
      include ConcernsOnRails::Expirable

      expirable_by :expires_at
    end

    travel_to(tokyo_morning) do
      token = datetime_model.create!(expires_at: tokyo_morning + 90.minutes)

      expect(token.time_until_expiry).to be_within(1).of(90.minutes)
      expect(datetime_model.create!(expires_at: tokyo_morning - 1.minute).time_until_expiry).to eq(0.seconds)
    end
  end
end
