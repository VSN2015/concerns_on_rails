require "spec_helper"

RSpec.describe ConcernsOnRails::Support::TimeValue do
  describe ".utc" do
    # Time#utc (alias #gmtime) converts its receiver IN PLACE.
    it "returns a UTC copy and never converts the receiver" do
      local = Time.new(2026, 1, 2, 10, 4, 5, "+07:00")
      expect(described_class.utc(local)).to eq(Time.utc(2026, 1, 2, 3, 4, 5))
      expect(described_class.utc(local)).to be_utc
      expect(local.utc_offset).to eq(7 * 3600)
    end

    it "handles a frozen Time, a TimeWithZone (without touching its #to_time memo) and a DateTime" do
      frozen = Time.new(2026, 1, 2, 10, 4, 5, "+07:00").freeze
      expect(described_class.utc(frozen).iso8601).to eq("2026-01-02T03:04:05Z")

      zoned = Time.utc(2026, 1, 2, 3, 4, 5).in_time_zone("Tokyo")
      offset = zoned.to_time.utc_offset
      expect(described_class.utc(zoned).iso8601).to eq("2026-01-02T03:04:05Z")
      expect(zoned.to_time.utc_offset).to eq(offset)

      expect(described_class.utc(DateTime.new(2026, 1, 2, 10, 4, 5, "+07:00")).iso8601).to eq("2026-01-02T03:04:05Z")
    end
  end

  describe ".cast_argument!" do
    before do
      ActiveRecord::Schema.define do
        create_table :time_value_records, force: true do |t|
          t.datetime :happened_at
        end
      end
    end

    after { ActiveRecord::Base.connection.drop_table(:time_value_records) }

    let(:klass) { Class.new(TestModel) { self.table_name = "time_value_records" } }

    def cast!(value, **)
      described_class.cast_argument!(klass, :happened_at, value, label: "Label", **)
    end

    it "casts through the column's own type" do
      expect(cast!("2020-01-01 00:00:00")).to eq(Time.utc(2020, 1, 1))
      expect(cast!(Time.utc(2020, 1, 1))).to eq(Time.utc(2020, 1, 1))
    end

    it "returns blank values untouched, leaving their meaning to the verb" do
      [nil, "", "   ", false, []].each { |blank| expect(cast!(blank)).to eq(blank) }
    end

    it "raises on anything that casts to no time, naming the field" do
      ["junk", "2026-13-45 99:99", 42, 1.hour].each do |bad|
        expect { cast!(bad) }
          .to raise_error(ArgumentError, /\ALabel: .* cannot be parsed as a time for 'happened_at' — pass a Time or a parseable String\z/)
      end
      expect { cast!("junk", accepts: "a Time, or nil for now") }.to raise_error(ArgumentError, /pass a Time, or nil for now\z/)
    end

    # Under time-zone awareness the column's cast is Time.zone.parse, which
    # finds a date in almost anything: "junk" is June 1st ("jun"), "Monday"
    # and "10:30" are today. A String argument must name a year.
    context "when the model is time-zone-aware" do
      around { |example| Time.use_zone("America/New_York") { example.run } }

      let(:klass) do
        Class.new(TestModel) do
          self.table_name = "time_value_records"
          self.time_zone_aware_attributes = true
        end
      end

      it "refuses a String without a year, however leniently Time.zone.parse would read it" do
        (%w[junk maybe decimal marching Monday 10:30 tomorrow 2026 99999] +
         ["1 Oct", "x" * 200, "junk 2026", "2026-10-01 10:00 junk", "99999-01-01", "2026 (junk)",
          "2026-10-01 (junk)", "(junk) 2026"]).each do |word|
          expect { cast!(word) }.to raise_error(ArgumentError, /cannot be parsed as a time for 'happened_at'/), word
        end
      end

      # Time.zone.parse keeps a two-digit year as written (year 26 AD) and
      # ignores an ordinal day, so neither may reach it.
      it "refuses a two-digit year and an ordinal date, which Time.zone.parse would misread" do
        ["10/1/26", "Oct 1 26", "01-Oct-26", "Thursday, 01-Oct-26 10:30:00 GMT", "2026-032"].each do |string|
          expect { cast!(string) }.to raise_error(ArgumentError, /cannot be parsed as a time/), string
        end
      end

      it "still accepts ISO 8601, RFC 2822, HTTP dates and the everyday spellings" do
        ["2026-10-01T10:30:00Z", "2026-10-01T10:30:00.5+09:00", "Thu, 01 Oct 2026 10:30:00 +0000",
         "Thu, 01 Oct 2026 10:30:00 GMT", "Oct 1 2026", "2026-10-01 10:30", "2026-10-01",
         "2026-10-01 10:30 EST", "October 1st, 2026 10:30 p.m.", "Thursday, Oct. 1 2026", "20261001"].each do |ok|
          expect(cast!(ok)).to be_a(ActiveSupport::TimeWithZone), ok
        end
        expect(cast!("2026-10-01 10:30").hour).to eq(10)
      end

      # PR #125 review round 3 (R3-01): a zone name after an offset, and the
      # trailing comments of RFC 2822 and JavaScript, are not garbage.
      it "accepts zone names and trailing comments, at the instant they name" do
        {
          "Thu, 13 Feb 1969 23:32 -0330 (Newfoundland Time)" => Time.utc(1969, 2, 14, 3, 2), # RFC 2822 A.5
          "Thu, 1 Oct 2026 10:30:00 -0700 (PDT)" => Time.utc(2026, 10, 1, 17, 30),
          "Thu Oct 01 2026 10:30:00 GMT-0400 (Eastern Daylight Time)" => Time.utc(2026, 10, 1, 14, 30), # Date#toString
          "2026-10-01 10:30:00 -0400 EDT" => Time.utc(2026, 10, 1, 14, 30), # Go
          "2026-10-01T10:30:00-04:00[America/New_York]" => Time.utc(2026, 10, 1, 14, 30), # RFC 9557
          "October 1, 2026 at 10:30:00 AM EDT" => Time.utc(2026, 10, 1, 14, 30) # ICU
        }.each do |string, instant|
          expect(cast!(string)).to eq(instant), string
        end
      end
    end
  end

  describe ".zone_aware?" do
    it "mirrors ActiveRecord's time_zone_aware_attributes / skip list for the :datetime type" do
      klass = Class.new(TestModel) { self.abstract_class = true }
      expect(described_class.zone_aware?(klass, :starts_at)).to be(false)

      klass.time_zone_aware_attributes = true
      expect(described_class.zone_aware?(klass, :starts_at)).to be(true)

      klass.skip_time_zone_conversion_for_attributes = [:starts_at]
      expect(described_class.zone_aware?(klass, :starts_at)).to be(false)
      expect(described_class.zone_aware?(klass, "ends_at")).to be(true)

      klass.time_zone_aware_types = [:time]
      expect(described_class.zone_aware?(klass, :ends_at)).to be(false)
    end
  end

  describe ".cast / .read" do
    around { |example| Time.use_zone("America/New_York") { example.run } }

    context "when zone-aware" do
      it "reads a zone-less String as wall-clock time in Time.zone, and an offset as given" do
        cast = described_class.cast("2026-10-01T09:00", zone_aware: true)
        expect(cast).to be_a(ActiveSupport::TimeWithZone)
        expect(cast.time_zone.name).to eq("America/New_York")
        expect(cast.getutc).to eq(Time.utc(2026, 10, 1, 13))
        expect(described_class.cast("2026-10-01T09:00:00Z", zone_aware: true).getutc).to eq(Time.utc(2026, 10, 1, 9))
      end

      it "makes a Date midnight in Time.zone and moves a Time into Time.zone" do
        expect(described_class.cast(Date.new(2026, 10, 1), zone_aware: true).getutc).to eq(Time.utc(2026, 10, 1, 4))
        time = Time.utc(2026, 10, 1, 13)
        expect(described_class.cast(time, zone_aware: true).hour).to eq(9)
        expect(described_class.cast(DateTime.new(2026, 10, 1, 13), zone_aware: true).hour).to eq(9)
      end

      it "reads multiparameter (datetime_select) input as wall-clock time in Time.zone" do
        cast = described_class.cast({ 1 => 2026, 2 => 10, 3 => 1, 4 => 9, 5 => 0 }, zone_aware: true)
        expect(cast).to be_a(ActiveSupport::TimeWithZone)
        expect(cast.getutc).to eq(Time.utc(2026, 10, 1, 13))
      end

      it "casts garbage and impossible dates to nil" do
        expect(described_class.cast("garbage", zone_aware: true)).to be_nil
        expect(described_class.cast("2026-13-45", zone_aware: true)).to be_nil
        expect(described_class.cast("", zone_aware: true)).to be_nil
        expect(described_class.cast(42, zone_aware: true)).to be_nil
      end

      it "reads a stored UTC ISO8601 String back as a TimeWithZone in Time.zone" do
        read = described_class.read("2026-10-01T13:00:00.123456Z", zone_aware: true)
        expect(read).to be_a(ActiveSupport::TimeWithZone)
        expect([read.hour, read.usec]).to eq([9, 123_456])
        expect(described_class.read("not a time", zone_aware: true)).to be_nil
      end

      # A stored value without Z or an offset is a database value: UTC under
      # default_timezone :utc, never the server's zone (Time.iso8601's reading).
      it "reads a zone-less stored value in default_timezone, whatever the server's zone" do
        previous_tz = ENV.fetch("TZ", nil)
        ENV["TZ"] = "Asia/Tokyo"
        %w[2026-10-01T13:00:00 2026-10-01T13:00:00.000000].push("2026-10-01 13:00:00").each do |stored|
          expect(described_class.read(stored, zone_aware: true)).to eq(Time.utc(2026, 10, 1, 13)), stored
          expect(described_class.read(stored, zone_aware: false)).to eq(Time.utc(2026, 10, 1, 13)), stored
        end
        expect(described_class.read("2026-10-01T22:00:00+09:00", zone_aware: false)).to eq(Time.utc(2026, 10, 1, 13))
      ensure
        ENV["TZ"] = previous_tz
      end
    end

    context "when not zone-aware (default_timezone :utc)" do
      it "keeps the pre-existing UTC semantics" do
        expect(described_class.cast("2026-10-01T09:00", zone_aware: false)).to eq(Time.utc(2026, 10, 1, 9))
        expect(described_class.cast(Date.new(2026, 10, 1), zone_aware: false)).to eq(Time.utc(2026, 10, 1))
        local = Time.new(2026, 10, 1, 9, 0, 0, "+07:00")
        expect(described_class.cast(local, zone_aware: false)).to equal(local)
        expect(described_class.read("2026-10-01T13:00:00.000000Z", zone_aware: false)).to eq(Time.utc(2026, 10, 1, 13))
        expect(described_class.read("2026-10-01T13:00:00.000000Z", zone_aware: false)).to be_utc
      end
    end
  end

  describe ".range_status / .representable?" do
    it "places a date or time against years 0001..9999, in UTC" do
      expect(described_class.range_status(Time.utc(9999, 12, 31, 23, 59, 59))).to eq(:within)
      expect(described_class.range_status(Time.utc(1, 1, 1))).to eq(:within)
      expect(described_class.range_status(Time.utc(10_000, 1, 1))).to eq(:above)
      expect(described_class.range_status(Time.utc(300_000, 1, 1))).to eq(:above)
      expect(described_class.range_status(Time.utc(0, 12, 31))).to eq(:below)
      # 9999-12-31 23:00 in UTC-05:00 is already year 10000 in UTC, where it binds.
      expect(described_class.range_status(Time.new(9999, 12, 31, 23, 0, 0, "-05:00"))).to eq(:above)
      expect(described_class.range_status(Time.utc(10_000, 1, 1).in_time_zone("Tokyo"))).to eq(:above)

      expect(described_class.range_status(Date.new(9999, 12, 31))).to eq(:within)
      expect(described_class.range_status(Date.new(10_000, 1, 1))).to eq(:above)
      expect(described_class.range_status(Date.new(0, 1, 1))).to eq(:below)
      expect(described_class.range_status(DateTime.new(10_000, 1, 1))).to eq(:above)
    end

    it "has nothing to say about a value that is not a date or time" do
      [nil, 42, "2026-01-01", Float::INFINITY].each do |value|
        expect(described_class.range_status(value)).to be_nil
        expect(described_class.representable?(value)).to be(true)
      end
      expect(described_class.representable?(Time.utc(2026))).to be(true)
      expect(described_class.representable?(Time.utc(10_000))).to be(false)
    end
  end
end
