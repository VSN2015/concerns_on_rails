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
      # truncation. Only a column that is not plain numeric (a virtual field,
      # or a numeric `type:` over a string column) falls back to `type`.
      def classify(raw, type, column_type: type)
        return nil unless kind(type)

        limits = kind(column_type) ? column_type : type
        return out_of_range(raw) if raw.is_a?(Integer) && raw.abs.bit_length > MAX_INTEGER_BITS

        kind(limits) == :float ? float_operand(raw) : decimal_operand(raw, limits)
      end

      def decimal_operand(raw, limits)
        value = decimal_value(raw)
        return UNCASTABLE if value.nil?

        scale = decimal_scale(limits)
        return out_of_range(value) if beyond_precision?(value, limits, scale)

        inexact = scale && value.round(scale) != value
        bound = bindable(inexact ? value.floor(scale) : value, scale)
        return out_of_range(value) unless within_integer_range?(limits, bound)

        inexact ? Operand.new(:inexact, value, bound) : Operand.new(:exact, bound)
      end

      def within_integer_range?(limits, bound)
        !integer_limits?(limits) || serializable?(limits, bound)
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
        value =
          case raw
          when String then numeric_string?(raw) ? raw.strip.to_f : nil
          when Numeric then raw.to_f
          end
        return UNCASTABLE if value.nil? || value.nan?
        return out_of_range(value) unless value.finite?

        Operand.new(:exact, value)
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
