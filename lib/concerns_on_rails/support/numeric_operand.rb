require "bigdecimal"
require "bigdecimal/util"
require "active_model/type"

module ConcernsOnRails
  module Support
    # Reads an untrusted filter operand (a query-string String, or a JSON-body
    # number) against a plain numeric attribute type WITHOUT the lossy casts
    # ActiveModel applies on the way to SQL:
    #
    #   * Integer#cast is `to_i`, so "1e3" became 1 and "5.5" became 5;
    #   * Decimal#cast rounds to the column's scale, so 99.985 became 99.99;
    #   * an integer beyond the column's range casts fine but cannot be bound
    #     (Arel turns it into 1=0 — every comparison empty, even `<`), and a
    #     Float overflow ("1e400") is Infinity, which adapters quote
    #     inconsistently.
    #
    # Every operand is read as an exact decimal first — an integer column is
    # just a decimal column of scale 0 — then judged against the COLUMN it
    # binds to. `classify` answers an Operand whose status says what the value
    # means there, and callers pick the SQL per operator:
    #
    #   :exact      — representable as-is; bind `value` normally.
    #   :inexact    — finer than the column's scale (5.5 on an integer column,
    #                 99.985 on a scale-2 decimal): no stored value can EQUAL
    #                 it. `floor` is the largest representable value below it,
    #                 so `> v` / `>= v` are exactly `> floor` and `< v` /
    #                 `<= v` exactly `<= floor`.
    #   :above      — beyond the largest value the column can hold.
    #   :below      — beyond the smallest.
    #   :uncastable — not a number at all ("twelve", "0x10", "1_000"), or one
    #                 too long / with too wide an exponent to read safely.
    #
    # `classify` returns nil for anything that is not a PLAIN numeric type —
    # enums (EnumType reports `type == :integer`), serialized or custom types —
    # so callers keep their existing path for those.
    module NumericOperand
      NUMERIC_STRING = /\A\s*[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?\s*\z/
      EXPONENT = /[eE]([-+]?\d+)\s*\z/
      # Operands are bounded BEFORE a BigDecimal is built: on a decimal column
      # with no declared precision (PostgreSQL's plain numeric, SQLite's bare
      # decimal) nothing else limits them, and binding BigDecimal("1e99999999")
      # expands it through to_s("F") — 1.3 s and 476 MB for a 12-byte param.
      # Within these bounds a value has at most ~1,100 digits either side of
      # the point, far inside PostgreSQL's numeric limits (131,072 / 16,383).
      MAX_LENGTH = 100
      MAX_EXPONENT = 1000
      # A JSON-body Integer beyond ~10**1000 can only be beyond the column.
      MAX_INTEGER_BITS = 3322
      NUMERIC_CLASSES = [ActiveModel::Type::Integer, ActiveModel::Type::Decimal, ActiveModel::Type::Float].freeze
      KINDS = %i[integer decimal float].freeze

      Operand = Struct.new(:status, :value, :floor)
      UNCASTABLE = Operand.new(:uncastable).freeze

      module_function

      # :integer / :decimal / :float for a plain numeric type, else nil. The
      # kind is the type's own `type` (NOT its class): AR's
      # DecimalWithoutScale — a `decimal(10,0)`, MySQL's default decimal — is
      # a BigInteger subclass that reports :decimal.
      def kind(type)
        return nil unless type && NUMERIC_CLASSES.any? { |klass| type.is_a?(klass) }

        KINDS.find { |candidate| candidate == type.type }
      end

      # `type` (a declared `type:`, or the column's own) decides THAT the
      # operand is read as a number; the column it binds to decides what it
      # can hold, whatever numeric `type:` was declared — `type: :decimal` on
      # an integer column must not bind 5.5 through the integer type's
      # truncation. A column that is not plain numeric (a virtual field, a
      # column missing from attribute_types, or a numeric `type:` over a
      # string column) falls back to `type` for the SCALE only: range and
      # precision limits come from a real numeric column or not at all —
      # ActiveModel::Type.lookup(:integer)'s 4-byte range says nothing about a
      # string column, and read 4_000_000_000 there as "beyond every value".
      # `column_type: nil` means "no column" (a with: lambda's value).
      def classify(raw, type, column_type: type)
        return nil unless kind(type)

        bounded = !kind(column_type).nil?
        limits = bounded ? column_type : type
        return out_of_range(raw) if beyond_any_column?(raw)

        kind(limits) == :float ? float_operand(raw) : decimal_operand(raw, limits, bounded)
      end

      # A JSON-body Integer past ~10**1000, or a Float infinity (a JSON 1e400,
      # answered exactly like the query-string "1e400").
      def beyond_any_column?(raw)
        return raw.abs.bit_length > MAX_INTEGER_BITS if raw.is_a?(Integer)

        raw.is_a?(Float) && raw.infinite?
      end

      def decimal_operand(raw, limits, bounded)
        value = decimal_value(raw)
        return UNCASTABLE if value.nil?

        scale = decimal_scale(limits)
        inexact = scale && value.round(scale) != value
        bound = bindable(inexact ? value.floor(scale) : value, scale)
        return out_of_range(value) if bounded && beyond_column?(value, bound, limits, scale)

        inexact ? Operand.new(:inexact, value, bound) : Operand.new(:exact, bound)
      end

      # Only ever asked of a real numeric column: its decimal precision, or
      # its integer range (checked on `bound`, the value that actually binds).
      def beyond_column?(value, bound, limits, scale)
        return true if beyond_precision?(value, limits, scale)

        integer_limits?(limits) && !serializable?(limits, bound)
      end

      # What actually binds: an Integer on a scale-0 column (so the integer
      # type never sees a BigDecimal), the BigDecimal itself otherwise.
      def bindable(value, scale)
        scale&.zero? ? value.to_i : value
      end

      def decimal_value(raw)
        case raw
        when String then numeric_string?(raw) ? raw.strip.to_d : nil
        when Integer then BigDecimal(raw)
        when Float, BigDecimal then raw.finite? ? raw.to_d : nil
        end
      end

      # The shape check and the size bounds, read off the string itself — the
      # exponent is compared as a (≤ 100-char) digit string's Integer, never
      # by building the number it describes.
      def numeric_string?(raw)
        return false if raw.length > MAX_LENGTH || !NUMERIC_STRING.match?(raw)

        exponent = raw[EXPONENT, 1]
        exponent.nil? || exponent.to_i.abs <= MAX_EXPONENT
      end

      # Integer columns (and the Integer-backed DecimalWithoutScale) hold whole
      # numbers only; a Decimal its declared scale (nil = unconstrained).
      def decimal_scale(type)
        type.is_a?(ActiveModel::Type::Integer) ? 0 : type.scale
      end

      def integer_limits?(type)
        type.is_a?(ActiveModel::Type::Integer)
      end

      def beyond_precision?(value, limits, scale)
        precision = limits.precision
        return false unless precision && kind(limits) == :decimal

        value.abs >= BigDecimal(10)**(precision - (scale || 0))
      end

      def float_operand(raw)
        value = float_value(raw)
        return UNCASTABLE if value.nil? || value.nan?
        return out_of_range(value) unless value.finite?
        return underflow(raw) if value.zero? && !written_zero?(raw)

        Operand.new(:exact, value)
      end

      # A nonzero literal below the smallest subnormal ("1e-400") reads as
      # 0.0 — a DIFFERENT number, so binding it as :exact made `= 1e-400`
      # match every 0.0 row and `< 1e-400` miss them. No Float can equal it:
      # it is :inexact, floored to the largest Float below it (0.0 for a
      # positive literal, the negative subnormal nearest zero for a negative
      # one), which keeps `> v` / `>= v` as `> floor` and `< v` / `<= v` as
      # `<= floor` exact, like every other inexact operand.
      def underflow(raw)
        negative = raw.is_a?(String) ? raw.strip.start_with?("-") : raw.negative?
        Operand.new(:inexact, decimal_value(raw) || raw, negative ? 0.0.prev_float : 0.0)
      end

      # Only reached for a numeric_string? String or a finite Numeric.
      def written_zero?(raw)
        raw.is_a?(String) ? raw.strip.to_d.zero? : raw.zero?
      end

      def float_value(raw)
        case raw
        when String then numeric_string?(raw) ? raw.strip.to_f : nil
        when Numeric then raw.to_f
        end
      end

      def out_of_range(value)
        Operand.new(value.positive? ? :above : :below, value)
      end

      # `serializable?` is the Rails 6.1+ range probe; on 6.0 only `serialize`
      # itself knows, raising ActiveModel::RangeError (a ::RangeError).
      def serializable?(type, value)
        return type.serializable?(value) if type.respond_to?(:serializable?)

        type.serialize(value)
        true
      rescue ::RangeError
        false
      end
    end
  end
end
