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
      # or date raises ArgumentError. Before this check, "junk" cast to nil and
      # the verb wrote NULL but still reported success.
      def cast_argument!(klass, field, value, label:, accepts: "a Time or a parseable String")
        return value if value.blank?

        cast = klass.type_for_attribute(field.to_s).cast(value)
        return cast if temporal?(cast)

        raise ArgumentError,
              "#{label}: #{value.inspect} cannot be parsed as a time for '#{field}' — pass #{accepts}"
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
      # decoded. A String that is not ISO8601 raises ArgumentError (callers
      # keep their own nil-on-garbage rule).
      def read(raw, zone_aware:)
        present(raw.is_a?(::Time) ? raw : ::Time.iso8601(raw.to_s), zone_aware: zone_aware)
      end

      def present(time, zone_aware:)
        zone = zone_aware ? ::Time.zone : nil
        return time.in_time_zone(zone) if zone

        default_timezone == :local ? time.getlocal : time
      end

      def cast_in_zone(value, zone)
        case value
        when ::String then parse_in_zone(value, zone)
        when ::DateTime then value.to_time.in_time_zone(zone)
        when ::Date then zone.local(value.year, value.month, value.day)
        else cast_in_default_timezone(value)&.in_time_zone(zone)
        end
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
