require "spec_helper"

# Audit 2026-10-10 PARAM-8. `type: :datetime` resolved to
# ActiveModel::Type::DateTime, which reads a zone-less String in the SERVER's
# system zone (ENV["TZ"]) whenever Time.zone_default is set and not UTC — i.e.
# in every app with `config.time_zone` — while the same filter without `type:`
# (the column's own ActiveRecord type) reads it in ActiveRecord.default_timezone
# (UTC). So `?happened_at_gte=2026-01-01 10:00` meant 10:00 in whatever TZ the
# host or container ran in. `type: :datetime` / `:time` / `:date` now resolve
# to ActiveRecord's own types (no connection needed at class load).
describe ConcernsOnRails::Controllers::Filterable do
  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :zone_events, force: true do |t|
        t.string :title
        t.datetime :happened_at
      end
    end
    stub_const("ZoneEvent", Class.new(TestModel) { self.table_name = "zone_events" })
    ZoneEvent.create!(title: "early", happened_at: Time.utc(2026, 1, 1, 5, 0, 0))
    ZoneEvent.create!(title: "late", happened_at: Time.utc(2026, 1, 1, 6, 0, 0))
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  around do |example|
    old_tz = ENV.fetch("TZ", nil)
    old_default = Time.zone_default
    ENV["TZ"] = "Asia/Tokyo"
    Time.zone_default = Time.find_zone!("Eastern Time (US & Canada)")
    # spec_helper pins Time.zone (thread-local) to UTC; the request zone here
    # is Eastern, like config.time_zone in the app the audit describes.
    Time.use_zone("Eastern Time (US & Canada)") { example.run }
  ensure
    ENV["TZ"] = old_tz
    Time.zone_default = old_default
  end

  def filter_class(**options)
    Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Filterable

      filter_by :happened_at, operators: %i[gte], **options
    end
  end

  it "reads a zone-less operand under type: :datetime like the column does, not in the server's TZ" do
    params = { happened_at_gte: "2026-01-01 10:00" }

    expect(filter_class.new(params: params).filtered(ZoneEvent.all).pluck(:title)).to eq([])
    expect(filter_class(type: :datetime).new(params: params).filtered(ZoneEvent.all).pluck(:title)).to eq([])
  end

  # Review follow-up: "the column's own type" depends on the column. A
  # non-zone-aware one reads a zone-less operand in default_timezone (UTC)...
  it "reads a zone-less operand in default_timezone on a non-zone-aware model, as the untyped filter does" do
    params = { happened_at_gte: "2026-01-01 05:30" }

    expect(filter_class.new(params: params).filtered(ZoneEvent.all).pluck(:title)).to eq(%w[late])
    expect(filter_class(type: :datetime).new(params: params).filtered(ZoneEvent.all).pluck(:title)).to eq(%w[late])
  end

  # ...a zone-aware one (every Rails app) reads it in Time.zone, which is what
  # the untyped filter does, per-request zone included. 00:30 Eastern is
  # 05:30 UTC (the late row only); read as UTC it would keep both rows.
  context "on a zone-aware model" do
    before do
      stub_const("AwareZoneEvent", Class.new(TestModel) do
        self.table_name = "zone_events"
        self.time_zone_aware_attributes = true
      end)
    end

    def titles(klass, **options)
      params = options.delete(:params) || { happened_at_gte: "2026-01-01 00:30" }
      filter_class(**options).new(params: params).filtered(klass.all).pluck(:title).sort
    end

    it "reads a zone-less operand under type: :datetime in Time.zone, like the untyped filter" do
      expect(titles(AwareZoneEvent)).to eq(%w[late])
      expect(titles(AwareZoneEvent, type: :datetime)).to eq(%w[late])
    end

    it "follows a per-request Time.zone (Timezoneable)" do
      Time.use_zone("Tokyo") do
        # 14:30 Tokyo is 05:30 UTC.
        params = { happened_at_gte: "2026-01-01 14:30" }

        expect(titles(AwareZoneEvent, params: params)).to eq(%w[late])
        expect(titles(AwareZoneEvent, type: :datetime, params: params)).to eq(%w[late])
      end
    end

    it "reads a zone-less Date operand as midnight in Time.zone" do
      params = { happened_at_gte: "2026-01-01" }

      expect(titles(AwareZoneEvent, type: :datetime, params: params)).to eq(titles(AwareZoneEvent, params: params))
    end

    it "keeps an explicit offset exact" do
      params = { happened_at_gte: "2026-01-01T05:30:00Z" }

      expect(titles(AwareZoneEvent, type: :datetime, params: params)).to eq(%w[late])
    end

    it "still fails an unreadable operand closed" do
      expect(titles(AwareZoneEvent, type: :datetime, params: { happened_at_gte: "twelve" })).to eq([])
      expect(titles(AwareZoneEvent, type: :datetime, params: { happened_at_gte: "x" * 200 })).to eq([])
    end

    it "hands a with: lambda the value read in Time.zone when time_zone_aware_attributes is on" do
      received = nil
      klass = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable

        filter_by :since, type: :datetime, with: ->(rel, value) { rel.tap { received = value } }
      end
      klass.new(params: { since: "2026-01-01 00:30" }).filtered(AwareZoneEvent.all)

      expect(received).to eq(Time.utc(2026, 1, 1, 5, 30, 0))
      expect(received.time_zone.name).to eq("Eastern Time (US & Canada)")
    end
  end

  it "hands a with: lambda a type: :datetime / :time value read in default_timezone (UTC)" do
    received = {}
    capture = ->(key) { ->(rel, value) { rel.tap { received[key] = value } } }
    klass = Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Filterable

      filter_by :since, type: :datetime, with: capture.call(:since)
      filter_by :opens, type: :time, with: capture.call(:opens)
    end
    klass.new(params: { since: "2026-01-01 10:00", opens: "10:30" }).filtered(ZoneEvent.all)

    expect(received[:since]).to eq(Time.utc(2026, 1, 1, 10, 0, 0))
    expect(received[:since].utc_offset).to eq(0)
    expect([received[:opens].hour, received[:opens].min, received[:opens].utc_offset]).to eq([10, 30, 0])
  end

  it "keeps type: :date and an unknown type: name behaving as before" do
    expect(filter_class(type: :date).filterable_rules[:happened_at][:type].type).to eq(:date)
    expect { filter_class(type: :nope) }.to raise_error(ArgumentError, /not an ActiveModel type/)
  end
end
