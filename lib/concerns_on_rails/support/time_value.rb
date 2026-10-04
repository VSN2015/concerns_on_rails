require "date"
require "time"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/time/zones"
require "active_model/type"

module ConcernsOnRails
  module Support
    # The gem's one home for time values it did not construct itself.
    #
    #   * Write-verb ARGUMENTS (`expire!(t)`, `publish_at!(t)`,
    #     `soft_delete!(at: t)`, `start!(t)`, ...): `cast_argument!` casts
    #     through the column's own attribute type and refuses a value that
    #     casts to no time at all. The verbs call it before any hook runs.
    #   * VIRTUAL datetimes (Storable `:datetime` keys, Encryptable
    #     `type: :datetime` fields), which ActiveRecord never sees as datetime
    #     attributes: `cast` (user input) and `read` (the stored ISO8601 String)
    #     mirror ActiveRecord's TimeZoneConversion for the model.
    #   * UTC renderings: `utc` never converts its receiver in place.
    #     Time#utc (alias #gmtime) does, so it rewrote the caller's own Time,
    #     or the record's attribute value, and raised FrozenError on a frozen one.
    #   * The portable RANGE (`range_status`) that Filterable and
    #     CursorPaginatable check untrusted operands against before they reach SQL.
    module TimeValue
      # The SQL standard's DATE/TIMESTAMP range, 0001-01-01 .. 9999-12-31: the
      # four-digit years every supported adapter can store AND order.
      # PostgreSQL goes further (4713 BC .. 294276 AD) and raises
      # DatetimeFieldOverflow beyond that. MySQL's DATETIME officially starts
      # at 1000. SQLite compares the text, so it only orders four-digit years
      # ("10000-01-01" sorts before "2026-01-01"). Year 0 does not exist in
      # SQL, and PostgreSQL rejects it.
      YEARS = (1..9999)
      # A zone designator ending a String: Z, or an offset (+09:00, -0400, +09).
      ZONED = /(?:Z|[+-]\d{2}(?::?\d{2})?)\z/i
      # The words a date String may hold besides a time zone's name: month
      # and day names (full, or the abbreviations Date._parse reads), ordinal
      # suffixes, AM/PM, ISO 8601's T and Z, and the "at" of ICU's long
      # format. Date._parse reads "jun" out of "junk". ("of" is not one:
      # Date._parse drops the day from "15th of October 2026".)
      DATE_WORDS = (
        (::Date::MONTHNAMES + ::Date::ABBR_MONTHNAMES + ::Date::DAYNAMES + ::Date::ABBR_DAYNAMES).compact.map(&:downcase) +
        %w[sept tues thur thurs st nd rd th am pm t z at]
      ).uniq.freeze
      # The ranges a real date or time's parts fall in. Date._parse reads
      # "99999" as day 999 of 1999.
      PART_RANGES = { mon: 1..12, mday: 1..31, wday: 0..6, hour: 0..24, min: 0..59, sec: 0..60 }.freeze
      # Trailing comments and annotations: RFC 2822's "(Newfoundland Time)",
      # JavaScript Date#toString's "(Eastern Daylight Time)", RFC 9557's
      # "[America/New_York]".
      TRAILING_COMMENTS = /(?:\s*(?:\([^()]*\)|\[[^\[\]]*\]))+\s*\z/

      module_function

      # A Time, an ActiveSupport::TimeWithZone (its #is_a? claims Time), a
      # DateTime or a Date. Explicit is_a? checks, not acts_like?: that needs a
      # core_ext a controller-only host may not have loaded.
      def temporal?(value)
        value.is_a?(::Time) || value.is_a?(::Date)
      end

      # A UTC copy of a Time, TimeWithZone or DateTime. The receiver is never
      # changed.
      def utc(value)
        value.is_a?(::DateTime) ? value.to_time.getutc : value.getutc
      end

      # ---- write-verb arguments ------------------------------------------

      # A caller-supplied time for `field`, cast through the column's own
      # attribute type. So time_zone_aware_attributes and Time.zone apply
      # exactly as they do on assignment. A blank value is returned untouched:
      # each verb keeps its own meaning for it (`expire!(nil)` means now,
      # `publish_at!(nil)` writes NULL). Any other value that casts to no time
      # or date raises ArgumentError, and so does a String that names no year
      # (see names_year?). Before this check, "junk" cast to nil and the verb
      # wrote NULL but still reported success.
      def cast_argument!(klass, field, value, label:, accepts: "a Time or a parseable String")
        return value if value.blank?

        cast = names_year?(value) ? klass.type_for_attribute(field.to_s).cast(value) : nil
        return cast if temporal?(cast) && representable?(cast)

        raise ArgumentError,
              "#{label}: #{value.inspect} cannot be parsed as a time for '#{field}' — pass #{accepts}"
      end

      # A String argument must read as a date, the way Time.zone.parse (the
      # zone-aware column cast) will read it:
      #   * it names a four-digit year: "Oct 1 26" is year 26 to
      #     Time.zone.parse, so a two-digit year is refused;
      #   * no ordinal day ("2026-032"): Time.zone.parse ignores it;
      #   * every part is in range ("99999" is day 999 of 1999);
      #   * every word is a date word (DATE_WORDS), part of the zone
      #     Date._parse read ("EDT", "GMT-0400"), or a zone name that only
      #     repeats the offset already given (Go's "-0400 EDT"). Trailing
      #     comments are set aside, only when that changes nothing; any other
      #     bracket refuses the String.
      # Time.zone.parse finds a date in almost anything: "junk" is June 1st
      # ("jun"), "maybe" May 1st, "Monday" and "10:30" today, "junk 2026"
      # June 1st 2026, "mart 2026" (a Marquesas zone abbreviation) March 1st.
      # ISO 8601, RFC 2822 (comments included), HTTP dates, JavaScript's
      # Date#toString, "Oct 1 2026" and "2026-10-01 10:30 EST" all pass.
      # Anything that is not a String is judged by its cast alone. Only the
      # verbs check this: assigning to the column still casts exactly as
      # ActiveRecord does.
      def names_year?(value)
        return true unless value.is_a?(::String)

        bare = value.sub(TRAILING_COMMENTS, "")
        return false if bare.match?(/[()\[\]]/)

        parts = ::Date._parse(bare, false)
        readable_parts?(parts, bare) && parts == ::Date._parse(value, false) && date_words_only?(bare, parts)
      rescue ArgumentError # Date._parse refuses a String longer than 128 characters
        false
      end

      # A four-digit year (Date._parse's two-digit completion changes
      # nothing), no ordinal day, every part in range, and no one-letter
      # military zone but Z: Date._parse reads "7:30p" as 07:30 in zone P
      # (UTC-3), 13 hours from the 19:30 meant.
      def readable_parts?(parts, string)
        parts.key?(:year) && !parts.key?(:yday) && parts_in_range?(parts) &&
          !parts[:zone].to_s.match?(/\A[a-y]\z/i) && parts[:year] == ::Date._parse(string)[:year]
      end

      def parts_in_range?(parts)
        PART_RANGES.all? { |part, range| !parts.key?(part) || range.cover?(parts[part]) }
      end

      def date_words_only?(string, parts)
        # Several letters: a one-letter military zone ("10:30 b") shifts the
        # time by hours, and is never what a person or a program wrote.
        zone_words = parts[:offset].nil? ? [] : parts[:zone].to_s.downcase.scan(/[a-z]{2,}/)
        # "a.m." / "p.m." read as am / pm; a lone a, p or m is not a word
        # ("7p" is dropped by Date._parse, "7:30p" is military zone P).
        string.downcase.gsub(/\b([ap])\.\s?m\b\.?/) { "#{Regexp.last_match(1)}m" }.scan(/[a-z]+/).all? do |word|
          DATE_WORDS.include?(word) || zone_words.include?(word) || redundant_zone?(string, word, parts)
        end
      end

      # A zone name repeating an offset the String already gave ("-0400
      # EDT"): a zone Date._parse knows (several letters, so no military
      # one-letter zone) whose removal changes nothing it read.
      def redundant_zone?(string, word, parts)
        return false if parts[:offset].nil? || word.length < 2 || ::Date._parse("00:00 #{word}")[:offset].nil?

        ::Date._parse(string.sub(/\b#{Regexp.escape(word)}\b/i, " "), false) == parts
      end

      # ---- virtual datetimes (Storable keys, Encryptable fields) ---------

      # Whether `klass` converts a datetime attribute named `name` to
      # Time.zone. This is ActiveRecord's own create_time_zone_conversion_attribute?
      # (time_zone_aware_attributes, minus skip_time_zone_conversion_for_attributes,
      # for the :datetime type). It is read at call time, so the class-body
      # order of those settings does not matter.
      def zone_aware?(klass, name)
        return false unless klass.respond_to?(:time_zone_aware_attributes) && klass.time_zone_aware_attributes
        if klass.respond_to?(:skip_time_zone_conversion_for_attributes) &&
           klass.skip_time_zone_conversion_for_attributes.include?(name.to_sym)
          return false
        end

        !klass.respond_to?(:time_zone_aware_types) || klass.time_zone_aware_types.include?(:datetime)
      end

      # User input → the value a datetime COLUMN on the same model would hold.
      #   zone-aware: a TimeWithZone in Time.zone. A zone-less String (what
      #     <input type="datetime-local"> posts) is wall-clock time in
      #     Time.zone, and a Date is midnight there (TimeZoneConverter#cast).
      #   otherwise: ActiveRecord's own DateTime type under
      #     `ActiveRecord.default_timezone`. A zone-less String and a Date are
      #     UTC (local time under `default_timezone = :local`), and a Time is
      #     kept as given.
      # nil for anything that casts to no time.
      def cast(value, zone_aware:)
        return nil if value.nil?

        zone = zone_aware ? ::Time.zone : nil
        zone ? cast_in_zone(value, zone) : cast_in_default_timezone(value)
      end

      # A stored instant → what a datetime column READS back: a TimeWithZone
      # in Time.zone when zone-aware, a local Time under
      # `default_timezone = :local`, otherwise the instant as stored. Every
      # value the gem writes is UTC ISO8601, so existing rows read unchanged.
      # `raw` is that String, or a Time that a serialized column already
      # decoded. nil for a value that is not a time.
      def read(raw, zone_aware:)
        time = raw.is_a?(::Time) ? raw : stored_time(raw.to_s)
        time && present(time, zone_aware: zone_aware)
      end

      # The gem writes UTC ISO8601 ("...Z"), read strictly by Time.iso8601.
      # Time.iso8601 also reads a zone-less "...T13:00:00", but in the
      # SERVER's zone, so only a String carrying Z or an offset takes that
      # path. Any other form is a database value, read in default_timezone
      # as ActiveRecord reads a datetime column.
      def stored_time(string)
        (ZONED.match?(string) && iso8601(string)) || cast_in_default_timezone(string)
      end

      def iso8601(string)
        ::Time.iso8601(string)
      rescue ArgumentError
        nil
      end

      def present(time, zone_aware:)
        zone = zone_aware ? ::Time.zone : nil
        return time.in_time_zone(zone) if zone

        default_timezone == :local ? time.getlocal : time
      end

      def cast_in_zone(value, zone)
        case value
        when ::Hash then wall_clock_in_zone(cast_in_default_timezone(value), zone)
        when ::String then parse_in_zone(value, zone)
        when ::DateTime then value.to_time.in_time_zone(zone)
        when ::Date then zone.local(value.year, value.month, value.day)
        else cast_in_default_timezone(value)&.in_time_zone(zone)
        end
      end

      # A multiparameter Hash (datetime_select) holds wall-clock fields: cast
      # without a zone, then read those fields in Time.zone, as
      # TimeZoneConverter#cast does (Time.zone.local_to_utc).
      def wall_clock_in_zone(time, zone)
        time && zone.local_to_utc(time).in_time_zone(zone)
      end

      # Time.zone.parse first, as String#in_time_zone does. If it finds no date
      # at all, fall back to the column type, as TimeZoneConverter#cast does.
      # An impossible date ("2026-13-45") is nil, not an ArgumentError.
      def parse_in_zone(string, zone)
        zone.parse(string) || cast_in_default_timezone(string)&.in_time_zone(zone)
      rescue ArgumentError
        nil
      end

      def cast_in_default_timezone(value)
        case value
        when ::ActiveSupport::TimeWithZone, ::Time then value
        when ::DateTime then value.to_time
        when ::Date then ::Time.public_send(default_timezone, value.year, value.month, value.day)
        else
          time = datetime_type.cast(value)
          temporal?(time) ? time : nil
        end
      end

      # ActiveRecord's DateTime type reads `default_timezone` at cast time.
      # ActiveModel's guesses the zone from Time.zone_default instead, and
      # that guess is not what a datetime column in the same app does.
      def datetime_type
        @datetime_type ||=
          defined?(::ActiveRecord::Type::DateTime) ? ::ActiveRecord::Type::DateTime.new : ::ActiveModel::Type::DateTime.new
      end

      # :utc or :local, as ActiveRecord binds and reads times (7.0+ keeps it
      # on the ActiveRecord module, 6.x on ActiveRecord::Base).
      def default_timezone
        return ::ActiveRecord.default_timezone if defined?(::ActiveRecord) && ::ActiveRecord.respond_to?(:default_timezone)
        if defined?(::ActiveRecord::Base) && ::ActiveRecord::Base.respond_to?(:default_timezone)
          return ::ActiveRecord::Base.default_timezone
        end

        :utc
      end

      # ---- the portable range --------------------------------------------

      # Where a CAST operand sits against YEARS: :within, :above (after
      # 9999-12-31) or :below (before 0001-01-01). The check uses the value
      # as it would be bound: in UTC, or in local time under
      # `default_timezone = :local`. nil for a value that is not a date or time.
      def range_status(value)
        year = bound_year(value)
        return nil if year.nil?
        return :above if year > YEARS.end
        return :below if year < YEARS.begin

        :within
      end

      # False only for a date or time outside YEARS. Everything else, a
      # non-time included, is the caller's business.
      def representable?(value)
        status = range_status(value)
        status.nil? || status == :within
      end

      def bound_year(value)
        if value.is_a?(::Time) || value.is_a?(::DateTime)
          time = value.is_a?(::DateTime) ? value.to_time : value
          (default_timezone == :local ? time.getlocal : time.getutc).year
        elsif value.is_a?(::Date)
          value.year
        end
      end
    end
  end
end
