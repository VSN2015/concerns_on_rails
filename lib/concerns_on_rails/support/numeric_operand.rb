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
    # `classify` answers an Operand whose status says what the value means for
    # the column, and callers pick the SQL per operator:
    #
    #   :exact      — representable as-is; bind `value` normally.
    #   :inexact    — a decimal finer than the column's scale: no stored value
    #                 can EQUAL it. `value` is the unrounded BigDecimal and
    #                 `scale` the column's, so a comparison can be rewritten
    #                 onto the neighbouring representable values (see
    #                 Filterable#apply_filter_inexact_comparison).
    #   :above      — beyond the largest value the column can hold.
    #   :below      — beyond the smallest.
    #   :uncastable — not a number of this kind at all ("twelve", "0x10", or
    #                 an exponent/fraction for an integer column).
    #
    # `classify` returns nil for anything that is not a PLAIN numeric type —
    # enums (EnumType reports `type == :integer`), serialized or custom types —
    # so callers keep their existing path for those.
    module NumericOperand
      INTEGER_STRING = /\A\s*[-+]?\d+\s*\z/
      NUMERIC_STRING = /\A\s*[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?\s*\z/
      NUMERIC_CLASSES = [ActiveModel::Type::Integer, ActiveModel::Type::Decimal, ActiveModel::Type::Float].freeze
      KINDS = %i[integer decimal float].freeze

      Operand = Struct.new(:status, :value, :scale)
      UNCASTABLE = Operand.new(:uncastable, nil).freeze

      module_function

      # :integer / :decimal / :float for a plain numeric type, else nil. The
      # kind is the type's own `type` (NOT its class): AR's
      # DecimalWithoutScale — a `decimal(10,0)`, MySQL's default decimal — is
      # a BigInteger subclass that reports :decimal, and must compare 5.5
      # as 5.5, not truncate it.
      def kind(type)
        return nil unless type && NUMERIC_CLASSES.any? { |klass| type.is_a?(klass) }

        KINDS.find { |candidate| candidate == type.type }
      end

      # `type` decides how the operand is read; `column_type` (the column's
      # own attribute type, which is what Arel serializes the bound value
      # with) decides what it can hold — when it is the same kind.
      def classify(raw, type, column_type: type)
        kind = kind(type)
        return nil unless kind

        limits = kind(column_type) == kind ? column_type : type
        case kind
        when :integer then integer_operand(raw, limits)
        when :decimal then decimal_operand(raw, limits)
        else float_operand(raw)
        end
      end

      def integer_operand(raw, limits)
        value = integer_value(raw)
        return UNCASTABLE if value.nil?
        return out_of_range(value) unless serializable?(limits, value)

        Operand.new(:exact, value)
      end

      # A JSON-body float is accepted only when it is a whole number — 5.0 is
      # 5, but 5.5 would be truncated, so it is uncastable like "5.5".
      def integer_value(raw)
        case raw
        when String then INTEGER_STRING.match?(raw) ? Integer(raw.strip, 10) : nil
        when Integer then raw
        when Float, BigDecimal then raw.finite? && raw == raw.truncate ? raw.to_i : nil
        end
      end

      def decimal_operand(raw, limits)
        value = decimal_value(raw)
        return UNCASTABLE if value.nil?

        scale = decimal_scale(limits)
        precision = limits.precision
        return out_of_range(value) if precision && value.abs >= BigDecimal(10)**(precision - (scale || 0))

        return Operand.new(:inexact, value, scale) if scale && value.round(scale) != value

        Operand.new(:exact, value)
      end

      def decimal_value(raw)
        case raw
        when String then NUMERIC_STRING.match?(raw) ? raw.strip.to_d : nil
        when Integer then BigDecimal(raw)
        when Float, BigDecimal then raw.finite? ? raw.to_d : nil
        end
      end

      # An Integer-backed decimal type (DecimalWithoutScale) holds whole
      # numbers only, whatever `scale` it reports.
      def decimal_scale(type)
        type.is_a?(ActiveModel::Type::Integer) ? 0 : type.scale
      end

      def float_operand(raw)
        value =
          case raw
          when String then NUMERIC_STRING.match?(raw) ? raw.strip.to_f : nil
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
