require "spec_helper"

describe ConcernsOnRails::Schedulable do
  before do
    ActiveRecord::Schema.define do
      create_table :promotions, force: true do |t|
        t.string :name
        t.datetime :starts_at
        t.datetime :ends_at
      end
    end

    class Promotion < TestModel
      include ConcernsOnRails::Schedulable

      schedulable_by
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  describe "instance predicates" do
    it "is not current when starts_at is nil" do
      promo = Promotion.create!(name: "Draft")
      expect(promo.current?).to be false
      expect(promo.upcoming?).to be false
      expect(promo.expired?).to be false
    end

    it "is current when started in the past and ends_at is nil" do
      promo = Promotion.create!(name: "Open-ended", starts_at: 1.hour.ago)
      expect(promo.current?).to be true
      expect(promo.upcoming?).to be false
      expect(promo.expired?).to be false
    end

    it "is current when started in the past and ends_at is in the future" do
      promo = Promotion.create!(name: "Active", starts_at: 1.hour.ago, ends_at: 1.hour.from_now)
      expect(promo.current?).to be true
    end

    it "is upcoming when starts_at is in the future" do
      promo = Promotion.create!(name: "Soon", starts_at: 1.hour.from_now)
      expect(promo.upcoming?).to be true
      expect(promo.current?).to be false
      expect(promo.expired?).to be false
    end

    it "is expired when ends_at is in the past" do
      promo = Promotion.create!(name: "Over", starts_at: 2.hours.ago, ends_at: 1.hour.ago)
      expect(promo.expired?).to be true
      expect(promo.current?).to be false
      expect(promo.upcoming?).to be false
    end
  end

  describe "boundary semantics (inclusive start, exclusive end)" do
    it "is active at exactly the start instant" do
      freeze_time do
        promo = Promotion.create!(name: "Boundary", starts_at: Time.zone.now, ends_at: 1.hour.from_now)
        expect(promo.current?).to be true
      end
    end

    it "is not active at exactly the end instant" do
      freeze_time do
        promo = Promotion.create!(name: "Boundary", starts_at: 1.hour.ago, ends_at: Time.zone.now)
        expect(promo.current?).to be false
        expect(promo.expired?).to be true
      end
    end
  end

  describe "scopes" do
    it ".current returns only currently-active records" do
      active = Promotion.create!(name: "Active", starts_at: 1.hour.ago)
      Promotion.create!(name: "Future", starts_at: 1.hour.from_now)
      Promotion.create!(name: "Past", starts_at: 2.hours.ago, ends_at: 1.hour.ago)
      Promotion.create!(name: "Unstarted")
      expect(Promotion.current.map(&:name)).to eq([active.name])
    end

    it ".upcoming returns only future records" do
      Promotion.create!(name: "Active", starts_at: 1.hour.ago)
      future = Promotion.create!(name: "Future", starts_at: 1.hour.from_now)
      Promotion.create!(name: "Past", starts_at: 2.hours.ago, ends_at: 1.hour.ago)
      expect(Promotion.upcoming.map(&:name)).to eq([future.name])
    end

    it ".expired returns only past records" do
      Promotion.create!(name: "Active", starts_at: 1.hour.ago)
      Promotion.create!(name: "Future", starts_at: 1.hour.from_now)
      past = Promotion.create!(name: "Past", starts_at: 2.hours.ago, ends_at: 1.hour.ago)
      expect(Promotion.expired.map(&:name)).to eq([past.name])
    end

    it ".active_at(time) accepts an arbitrary time" do
      promo = Promotion.create!(name: "Window", starts_at: 2.hours.ago, ends_at: 1.hour.ago)
      expect(Promotion.active_at(90.minutes.ago).map(&:name)).to eq([promo.name])
      expect(Promotion.active_at(Time.zone.now)).to be_empty
    end
  end

  describe "instance mutators" do
    it "#start! sets starts_at to the given time (defaults to now)" do
      promo = Promotion.create!(name: "X")
      freeze_time do
        promo.start!
        expect(promo.starts_at).to eq(Time.zone.now)
      end
    end

    it "#finish! sets ends_at to the given time (defaults to now)" do
      promo = Promotion.create!(name: "X", starts_at: 1.hour.ago)
      freeze_time do
        promo.finish!
        expect(promo.ends_at).to eq(Time.zone.now)
        expect(promo.expired?).to be true
      end
    end

    it "#reschedule! updates both fields" do
      promo = Promotion.create!(name: "X")
      starts = 1.day.from_now.change(usec: 0)
      ends = 2.days.from_now.change(usec: 0)
      promo.reschedule!(starts_at: starts, ends_at: ends)
      expect(promo.starts_at.to_i).to eq(starts.to_i)
      expect(promo.ends_at.to_i).to eq(ends.to_i)
    end
  end

  describe "custom field configuration" do
    it "supports custom starts_at / ends_at column names" do
      ActiveRecord::Schema.define do
        create_table :events, force: true do |t|
          t.string :name
          t.datetime :starts_on
          t.datetime :ends_on
        end
      end

      class Event < TestModel
        include ConcernsOnRails::Schedulable

        schedulable_by starts_at: :starts_on, ends_at: :ends_on
      end

      Event.create!(name: "Active", starts_on: 1.hour.ago, ends_on: 1.hour.from_now)
      Event.create!(name: "Future", starts_on: 1.hour.from_now)
      expect(Event.current.map(&:name)).to eq(["Active"])
    end

    it "supports a configuration with only ends_at (open-ended start)" do
      ActiveRecord::Schema.define do
        create_table :coupons, force: true do |t|
          t.string :code
          t.datetime :expires_at
        end
      end

      class Coupon < TestModel
        include ConcernsOnRails::Schedulable

        schedulable_by starts_at: nil, ends_at: :expires_at
      end

      active = Coupon.create!(code: "ACTIVE", expires_at: 1.hour.from_now)
      Coupon.create!(code: "EXPIRED", expires_at: 1.hour.ago)
      expect(Coupon.current.map(&:code)).to eq([active.code])
    end
  end

  describe "validation" do
    it "raises ArgumentError when starts_at column does not exist" do
      ActiveRecord::Schema.define do
        create_table :bad_promotions, force: true do |t|
          t.string :name
        end
      end

      expect do
        class BadPromotion < TestModel
          include ConcernsOnRails::Schedulable

          schedulable_by
        end
      end.to raise_error(ArgumentError, /does not exist/)
    end

    it "raises ArgumentError when both starts_at and ends_at are nil" do
      expect do
        Promotion.schedulable_by(starts_at: nil, ends_at: nil)
      end.to raise_error(ArgumentError, /at least one/)
    end
  end

  it "allows reconfiguration on the same model" do
    ActiveRecord::Schema.define do
      create_table :reconfig_promos, force: true do |t|
        t.string :name
        t.datetime :starts_at
        t.datetime :ends_at
        t.datetime :starts_on
        t.datetime :ends_on
      end
    end

    class ReconfigPromo < TestModel
      include ConcernsOnRails::Schedulable
    end

    ReconfigPromo.schedulable_by
    expect(ReconfigPromo.schedulable_starts_at_field).to eq(:starts_at)

    ReconfigPromo.schedulable_by starts_at: :starts_on, ends_at: :ends_on
    expect(ReconfigPromo.schedulable_starts_at_field).to eq(:starts_on)
    expect(ReconfigPromo.schedulable_ends_at_field).to eq(:ends_on)
  end
end
