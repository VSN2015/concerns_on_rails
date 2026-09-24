require "bigdecimal"

module ConcernsOnRails
  module Support
    # Formats an integer subunit amount (e.g. cents) as a human-readable money
    # string. Pure and stateless; used by Models::Monetizable. Uses BigDecimal
    # throughout so there is no binary-float rounding drift.
    module Money
      FORMAT_OPTIONS = %i[unit precision delimiter separator subunit_to_unit].freeze

      module_function

      # format(199999) => "$1,999.99"
      # format(-500, unit: "£") => "-£5.00"
      # format(1234, unit: "¥", precision: 0, subunit_to_unit: 1) => "¥1,234"
      def format(cents, options = {})
        unit      = options.fetch(:unit, "$")
        precision = options.fetch(:precision, 2)
        delimiter = options.fetch(:delimiter, ",")
        separator = options.fetch(:separator, ".")
        subunit   = options.fetch(:subunit_to_unit, 100)

        decimal = BigDecimal(cents.to_s) / subunit
        # BigDecimal#round returns an Integer for precision <= 0, so re-wrap it
        # in a BigDecimal before #to_s("F") (Integer#to_s would read "F" as a radix).
        rounded = BigDecimal(decimal.abs.round(precision).to_s)
        whole, _, frac = rounded.to_s("F").partition(".")
        whole = delimit(whole, delimiter)
        number = precision.positive? ? "#{whole}#{separator}#{frac.ljust(precision, '0')[0, precision]}" : whole

        # Take the sign from the ROUNDED magnitude so a value that rounds to zero
        # (e.g. -0.001 at precision 2) never prints a spurious "-".
        sign = decimal.negative? && !rounded.zero? ? "-" : ""
        "#{sign}#{unit}#{number}"
      end

      # Merge per-call display overrides into a field's formatting config,
      # rejecting typos (`units:`) instead of silently ignoring them. Numeric
      # overrides are coerced exactly as the macro coerces them — a String
      # `subunit_to_unit: "100"` used to TypeError inside format().
      def format_options(config, overrides, label)
        return config if overrides.empty?

        unknown = overrides.keys - FORMAT_OPTIONS
        raise ArgumentError, "#{label}: unknown formatting option(s): #{unknown.join(', ')}" if unknown.any?

        coerce_numeric_options(config.merge(overrides), label)
      end

      # :subunit_to_unit to a positive Integer, :precision to an Integer
      # (a String "2" is fine; "two" or 1.5 raises). Returns a new Hash.
      def coerce_numeric_options(options, label)
        subunit = options.key?(:subunit_to_unit) ? options[:subunit_to_unit].to_i : 100
        raise ArgumentError, "#{label}: :subunit_to_unit must be a positive integer" unless subunit.positive?

        precision = options.key?(:precision) ? coerce_precision(options[:precision], label) : 2
        options.merge(subunit_to_unit: subunit, precision: precision)
      end

      def coerce_precision(value, label)
        precision = value.is_a?(Float) ? nil : Integer(value, exception: false)
        return precision if precision

        raise ArgumentError, "#{label}: :precision must be an integer, got #{value.inspect}"
      end

      # Writer input longer than this (after trimming) is rejected before any
      # BigDecimal work — no real amount needs it, and it bounds the cost.
      MAX_INPUT_LENGTH = 64
      # Largest accepted magnitude: < 10**MAX_EXPONENT major units (far past
      # any 64-bit cents column). Bigger finite values used to raise
      # FloatDomainError from the cents rounding.
      MAX_EXPONENT = 24
      # A written exponent of three or more digits ("1e100000000") is absurd.
      OVERSIZED_EXPONENT = /[eE][+-]?\d{3}/
      # "1.234" / "-1.234.567": "."-grouped thousands.
      DOTTED_THOUSANDS = /\A[+-]?\d{1,3}(?:\.\d{3})+\z/

      # Parse a writer's input into a finite BigDecimal amount (major units),
      # or nil. A String has its unit removed (only at the start or the end),
      # then is read canonically ("19.99", "5", "1e3" — the pre-existing
      # behaviour), then in the field's own display format, so formatted
      # output reads back: "$1,234.50" / "€1.234,50" / "-$5.00". Non-finite,
      # oversized and garbage input is nil, never raised.
      def parse(amount, options = {})
        decimal = amount.is_a?(String) ? parse_string(amount, options) : BigDecimal(amount.to_s)
        decimal&.finite? && decimal.exponent <= MAX_EXPONENT ? decimal : nil
      rescue ArgumentError, TypeError, FloatDomainError
        nil
      end

      # Major units to whole subunits (half-up), nil if that cannot be done.
      def subunits(decimal, subunit)
        (decimal * subunit).round
      rescue FloatDomainError
        nil
      end

      def parse_string(amount, options)
        stripped = strip_space(amount)
        return nil unless plausible_input?(stripped)

        body = strip_unit(stripped, options.fetch(:unit, "$").to_s)
        return nil unless body

        body = body.delete(".") if dotted_thousands?(body, options)
        canonical = BigDecimal(body, exception: false)
        return canonical if canonical

        localized = localized_to_canonical(body, options)
        localized && BigDecimal(localized, exception: false)
      end

      # Non-empty, bounded in length, and no three-digit written exponent.
      def plausible_input?(string)
        !string.empty? && string.length <= MAX_INPUT_LENGTH && !string.match?(OVERSIZED_EXPONENT)
      end

      # Remove the unit where the formatter puts it — the start (after an
      # optional sign) or the end. A unit anywhere else ("5$5") is garbage.
      def strip_unit(string, unit)
        unit = strip_space(unit)
        return string if unit.empty?

        sign = string[/\A[+-]/].to_s
        rest = strip_space(string.delete_prefix(sign))
        rest = rest.start_with?(unit) ? rest.delete_prefix(unit) : rest.delete_suffix(unit)
        rest.include?(unit) ? nil : "#{sign}#{strip_space(rest)}"
      end

      # In a field that groups with "." and separates with something else,
      # "1.234" is one thousand two hundred thirty-four — the same amount as
      # "€1.234" — not the decimal 1.234. Other "." decimals ("19.99", "1.5")
      # are still read canonically.
      def dotted_thousands?(body, options)
        options.fetch(:delimiter, ",").to_s == "." && options.fetch(:separator, ".").to_s != "." &&
          body.match?(DOTTED_THOUSANDS)
      end

      # Split on the separator and remove the delimiter from the whole part —
      # only where it groups digits in threes, so a wrong-locale "1,5" in a
      # "." field is garbage (nil), not 15.
      def localized_to_canonical(string, options)
        separator = options.fetch(:separator, ".").to_s
        sign = string.start_with?("-", "+") ? string[0] : ""
        whole, sep, frac = separator.empty? ? [string.delete_prefix(sign), "", ""] : string.delete_prefix(sign).partition(separator)
        whole = ungroup(strip_space(whole), options.fetch(:delimiter, ",").to_s)
        whole && "#{sign}#{whole}#{'.' unless sep.empty?}#{frac}"
      end

      def ungroup(whole, delimiter)
        return whole if delimiter.empty? || !whole.include?(delimiter)
        return nil unless whole.match?(/\A\d{1,3}(?:#{Regexp.escape(delimiter)}\d{3})+\z/)

        whole.gsub(delimiter, "")
      end

      # String#strip misses Unicode whitespace such as a no-break space.
      def strip_space(string)
        string.gsub(/\A[[:space:]]+|[[:space:]]+\z/, "")
      end

      # Subunits to a BigDecimal amount. A grouped relation's aggregate is a
      # Hash keyed by the GROUP BY value, so map over it rather than feeding
      # the whole Hash to BigDecimal().
      def decimal(cents, subunit)
        return cents.transform_values { |value| decimal(value, subunit) } if cents.is_a?(Hash)

        cents.nil? ? nil : BigDecimal(cents.to_s) / subunit
      end

      # format() that is likewise grouped-relation aware and nil-safe.
      def format_each(cents, options)
        return cents.transform_values { |value| format_each(value, options) } if cents.is_a?(Hash)

        cents.nil? ? nil : format(cents, options)
      end

      # Insert the thousands delimiter into a non-negative integer string.
      # Single lookahead pass — the old reverse/gsub/reverse allocated three
      # strings per formatted amount.
      def delimit(integer_string, delimiter)
        integer_string.gsub(/(\d)(?=(?:\d{3})+\z)/, "\\1#{delimiter}")
      end
    end
  end
end
