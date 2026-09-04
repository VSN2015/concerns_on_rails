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

  describe "scope affixing" do
    before do
      ActiveRecord::Schema.define do
        create_table :affixed_events, force: true do |t|
          t.datetime :starts_at
          t.datetime :ends_at
        end
      end
    end

    def affixed_class(**options)
      Class.new(TestModel) do
        self.table_name = "affixed_events"
        include ConcernsOnRails::Schedulable

        schedulable_by(**options)
      end
    end

    it "keeps the default names with no affix" do
      klass = affixed_class
      expect(klass).to respond_to(:current)
      expect(klass).to respond_to(:expired)
    end

    it "defines affixed names and removes the defaults" do
      klass = affixed_class(prefix: :event)

      expect(klass).to respond_to(:event_current)
      expect(klass).to respond_to(:event_active_at)
      expect(klass).not_to respond_to(:current)
      expect(klass).not_to respond_to(:expired)
    end

    it "keeps current delegating to active_at under an affix" do
      klass = affixed_class(prefix: :event)
      live = klass.create!(starts_at: 1.day.ago, ends_at: 1.day.from_now)
      klass.create!(starts_at: 1.day.from_now, ends_at: 2.days.from_now)

      expect(klass.event_current.pluck(:id)).to eq([live.id])
    end

    it "keeps upcoming and expired correct under an affix" do
      klass = affixed_class(suffix: :window)
      soon = klass.create!(starts_at: 1.day.from_now, ends_at: 2.days.from_now)
      over = klass.create!(starts_at: 3.days.ago, ends_at: 1.day.ago)

      expect(klass.upcoming_window.pluck(:id)).to eq([soon.id])
      expect(klass.expired_window.pluck(:id)).to eq([over.id])
    end
  end
  describe ".overlapping / #overlaps? (window intersection)" do
    let(:t0) { Time.utc(2026, 6, 1, 10) }
    let!(:before) { Promotion.create!(name: "before", starts_at: t0 - 3.hours, ends_at: t0 - 1.hour) }
    let!(:touching_start) { Promotion.create!(name: "touching-start", starts_at: t0 - 2.hours, ends_at: t0) }
    let!(:inside) { Promotion.create!(name: "inside", starts_at: t0 + 30.minutes, ends_at: t0 + 1.hour) }
    let!(:spanning) { Promotion.create!(name: "spanning", starts_at: t0 - 1.day, ends_at: t0 + 1.day) }
    let!(:open_ended) { Promotion.create!(name: "open-ended", starts_at: t0 - 1.hour) }
    let!(:touching_end) { Promotion.create!(name: "touching-end", starts_at: t0 + 2.hours, ends_at: t0 + 3.hours) }
    let!(:after) { Promotion.create!(name: "after", starts_at: t0 + 5.hours) }
    let!(:unstarted) { Promotion.create!(name: "unstarted") }

    def names(relation)
      relation.order(:id).map(&:name)
    end

    it "returns records whose window intersects [from, to) — inclusive start, exclusive end" do
      expect(names(Promotion.overlapping(t0, t0 + 2.hours))).to eq(%w[inside spanning open-ended])
    end

    it "excludes windows that only touch the boundaries" do
      result = names(Promotion.overlapping(t0, t0 + 2.hours))
      expect(result).not_to include("touching-start", "touching-end")
    end

    it "accepts a Range, honouring an inclusive end (..) vs an exclusive one (...)" do
      expect(names(Promotion.overlapping(t0...(t0 + 2.hours)))).to eq(%w[inside spanning open-ended])
      expect(names(Promotion.overlapping(t0..(t0 + 2.hours)))).to eq(%w[inside spanning open-ended touching-end])
    end

    it "treats a nil side as unbounded" do
      expect(names(Promotion.overlapping(t0 + 4.hours, nil))).to eq(%w[spanning open-ended after])
      expect(names(Promotion.overlapping(nil, t0 - 90.minutes))).to eq(%w[before touching-start spanning])
      expect(Promotion.overlapping(nil, nil).count).to eq(Promotion.where.not(starts_at: nil).count) # unstarted never overlap
    end

    it "never returns unstarted records (nil starts_at), matching active_at" do
      expect(names(Promotion.overlapping(t0 - 10.years, t0 + 10.years))).not_to include("unstarted")
    end

    it "is chainable and rejects an inverted window" do
      expect(names(Promotion.where(name: "inside").overlapping(t0, t0 + 2.hours))).to eq(%w[inside])
      expect { Promotion.overlapping(t0 + 1.hour, t0) }.to raise_error(ArgumentError, /from must not be after to/)
    end

    it "#overlaps? mirrors the scope, including boundaries and nil sides" do
      expect(inside.overlaps?(t0, t0 + 2.hours)).to be(true)
      expect(spanning.overlaps?(t0, t0 + 2.hours)).to be(true)
      expect(open_ended.overlaps?(t0, t0 + 2.hours)).to be(true)
      expect(touching_start.overlaps?(t0, t0 + 2.hours)).to be(false)
      expect(touching_end.overlaps?(t0, t0 + 2.hours)).to be(false)
      expect(touching_end.overlaps?(t0..(t0 + 2.hours))).to be(true)
      expect(unstarted.overlaps?(t0 - 10.years, t0 + 10.years)).to be(false)
      expect(after.overlaps?(t0 + 4.hours, nil)).to be(true)
      expect(before.overlaps?(nil, t0 - 90.minutes)).to be(true)
    end

    it "is affixable like the other scopes" do
      klass = Class.new(TestModel) do
        self.table_name = "promotions"
        include ConcernsOnRails::Schedulable

        schedulable_by prefix: :promo
      end
      expect(klass).to respond_to(:promo_overlapping)
      expect(klass).not_to respond_to(:overlapping)
      expect(klass.promo_overlapping(t0, t0 + 2.hours).count).to eq(3)
    end

    it "works with an ends_at-only configuration (open-ended start)" do
      ActiveRecord::Schema.define do
        create_table :ending_promos, force: true do |t|
          t.datetime :expires_at
        end
      end
      klass = Class.new(TestModel) do
        self.table_name = "ending_promos"
        include ConcernsOnRails::Schedulable

        schedulable_by starts_at: nil, ends_at: :expires_at
      end
      live = klass.create!(expires_at: t0 + 1.hour)
      klass.create!(expires_at: t0 - 1.hour)
      expect(klass.overlapping(t0, t0 + 2.hours).to_a).to eq([live])
      expect(live.overlaps?(t0, t0 + 2.hours)).to be(true)
    end
  end
end
