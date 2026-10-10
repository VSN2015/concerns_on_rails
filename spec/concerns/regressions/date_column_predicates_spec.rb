require "spec_helper"

# Audit 2026-10-10 (STATE-12): on a DATE column, the instance predicates of
# Schedulable / Expirable / Publishable compared the stored Date with
# Time.zone.now, and ActiveSupport compares a Date at UTC midnight. Their
# scopes bind the instant through the column's Date type (today in
# Time.zone), so outside UTC the two disagreed for the zone's offset hours
# every day. The predicates now cast the instant the way the scopes do.
describe "date-column predicates agree with their scopes outside UTC" do
  # 08:00 on Oct 10 in Tokyo is 23:00 on Oct 9 in UTC.
  let(:tokyo_morning) { Time.find_zone("Tokyo").local(2026, 10, 10, 8, 0) }
  let(:today) { Date.new(2026, 10, 10) }

  around do |example|
    Time.use_zone("Tokyo") { example.run }
  end

  before do
    ActiveRecord::Schema.define do
      create_table :dcp_events, force: true do |t|
        t.date :starts_on
        t.date :ends_on
      end
      create_table :dcp_passes, force: true do |t|
        t.date :valid_until
      end
      create_table :dcp_posts, force: true do |t|
        t.date :published_on
      end
      create_table :dcp_slots, force: true do |t|
        t.datetime :starts_at
        t.datetime :ends_at
      end
    end
  end

  after do
    %i[dcp_events dcp_passes dcp_posts dcp_slots].each do |table|
      ActiveRecord::Base.connection.drop_table(table, if_exists: true)
    end
  end

  let(:event_model) do
    Class.new(TestModel) do
      self.table_name = "dcp_events"
      include ConcernsOnRails::Schedulable

      schedulable_by starts_at: :starts_on, ends_at: :ends_on
    end
  end

  let(:pass_model) do
    Class.new(TestModel) do
      self.table_name = "dcp_passes"
      include ConcernsOnRails::Expirable

      expirable_by :valid_until
    end
  end

  let(:post_model) do
    Class.new(TestModel) do
      self.table_name = "dcp_posts"
      include ConcernsOnRails::Publishable

      publishable_by :published_on
    end
  end

  describe "Schedulable" do
    it "treats an event starting today (in Time.zone) as current, not upcoming" do
      travel_to(tokyo_morning) do
        event = event_model.create!(starts_on: today, ends_on: today + 2)

        expect(event_model.current.to_a).to eq([event])
        expect(event_model.upcoming.to_a).to eq([])
        expect(event).to be_current
        expect(event).not_to be_upcoming
        expect(event.active_at?(Time.zone.now)).to be(true)
      end
    end

    it "treats an event whose exclusive end date is today as expired" do
      travel_to(tokyo_morning) do
        event = event_model.create!(starts_on: today - 9, ends_on: today)

        expect(event_model.expired.to_a).to eq([event])
        expect(event).to be_expired
        expect(event).not_to be_current
      end
    end

    it "answers overlaps? on the same calendar days the overlapping scope uses" do
      travel_to(tokyo_morning) do
        event = event_model.create!(starts_on: today, ends_on: today + 2)
        window_end = Time.zone.now # 08:00 Oct 10 in Tokyo: the event has started

        expect(event_model.overlapping(Time.zone.now - 1.day, window_end).to_a).to eq([])
        expect(event.overlaps?(Time.zone.now - 1.day, window_end)).to be(false)
        expect(event_model.overlapping((Time.zone.now - 1.day)..window_end).to_a).to eq([event])
        expect(event.overlaps?((Time.zone.now - 1.day)..window_end)).to be(true)
      end
    end
  end

  describe "Expirable" do
    it "reports expired? for a date that is today in Time.zone, as .expired does" do
      travel_to(tokyo_morning) do
        pass = pass_model.create!(valid_until: today)

        expect(pass_model.expired.to_a).to eq([pass])
        expect(pass).to be_expired
        expect(pass).not_to be_active
      end
    end

    it "keeps tomorrow's date live" do
      travel_to(tokyo_morning) do
        pass = pass_model.create!(valid_until: today + 1)

        expect(pass_model.expired.to_a).to eq([])
        expect(pass).not_to be_expired
      end
    end
  end

  describe "Publishable" do
    it "reports published? for a date that is today in Time.zone, as .published does" do
      travel_to(tokyo_morning) do
        post = post_model.create!(published_on: today)

        expect(post_model.published.to_a).to eq([post])
        expect(post_model.scheduled.to_a).to eq([])
        expect(post).to be_published
        expect(post).not_to be_scheduled
      end
    end
  end

  describe "datetime columns (unchanged)" do
    let(:slot_model) do
      Class.new(TestModel) do
        self.table_name = "dcp_slots"
        include ConcernsOnRails::Schedulable

        schedulable_by
      end
    end

    it "still compares the exact instant, boundaries included" do
      travel_to(tokyo_morning) do
        now = Time.zone.now
        starting = slot_model.create!(starts_at: now, ends_at: now + 1.hour)
        later = slot_model.create!(starts_at: now + 1.second, ends_at: now + 1.hour)
        ended = slot_model.create!(starts_at: now - 1.hour, ends_at: now)

        expect(starting).to be_current
        expect(later).to be_upcoming
        expect(ended).to be_expired
        expect(slot_model.current.to_a).to eq([starting])
      end
    end

    it "still accepts String bounds, the way the scopes do" do
      event = slot_model.create!(starts_at: Time.zone.parse("2026-01-10"), ends_at: Time.zone.parse("2026-01-20"))

      expect(event.active_at?("2026-01-15")).to be(true)
      expect(event.overlaps?("2026-01-15", "2026-01-25")).to be(true)
      expect(slot_model.overlapping("2026-01-15", "2026-01-25").to_a).to eq([event])
    end
  end
end
