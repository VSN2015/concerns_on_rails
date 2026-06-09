module ConcernsOnRails
  module Support
    # Internal helpers for Models::Sequenceable: computing the next value within a
    # scope (+ period) and formatting it. Mixed into the model's class methods, so
    # `self` is the model class and `unscoped` / `sequenceable_config` resolve
    # against it. Kept here to keep the concern itself focused on configuration.
    module SequenceCalculator
      private

      # Next integer that would be assigned for the given scope: MAX within the
      # scope (+ period) + 1, or start_at when the scope/period is still empty.
      def sequence_base_value(field, record, scope_attrs)
        cfg = sequenceable_config.fetch(field)
        max = sequence_relation(field, record, scope_attrs).maximum(field)
        max ? max + 1 : cfg[:start_at]
      end

      def sequence_value_taken?(field, candidate, record, scope_attrs)
        sequence_relation(field, record, scope_attrs).exists?(field => candidate)
      end

      # Relation of existing rows that share this record's scope (and period, when
      # reset is enabled). Reads from `unscoped` so a model's default_scope never
      # hides rows the counter must account for.
      def sequence_relation(field, record, scope_attrs)
        cfg = sequenceable_config.fetch(field)
        rel = unscoped

        cfg[:scope].each do |col|
          value = record ? record[col] : (scope_attrs[col] || scope_attrs[col.to_s])
          rel = rel.where(col => value)
        end

        return rel if cfg[:reset] == :never

        rel.where(created_at: period_range(cfg[:reset], base_time(record)))
      end

      def format_sequence(field, seq, record)
        cfg = sequenceable_config.fetch(field)
        return cfg[:template].call(seq, record) if cfg[:template]

        padded = cfg[:padding].positive? ? seq.to_s.rjust(cfg[:padding], "0") : seq.to_s
        return "#{cfg[:prefix]}#{padded}" if cfg[:reset] == :never

        token = period_token(cfg[:reset], base_time(record))
        "#{cfg[:prefix]}#{token}#{cfg[:separator]}#{padded}"
      end

      def period_range(reset, time)
        case reset
        when :year  then time.beginning_of_year..time.end_of_year
        when :month then time.beginning_of_month..time.end_of_month
        when :day   then time.beginning_of_day..time.end_of_day
        end
      end

      def period_token(reset, time)
        case reset
        when :year  then time.year.to_s
        when :month then time.strftime("%Y%m")
        when :day   then time.strftime("%Y%m%d")
        end
      end

      # created_at is the natural anchor for the period, but it may not be set yet
      # during before_create — fall back to the current time, which is what the
      # timestamp will resolve to anyway.
      def base_time(record)
        return Time.current unless record

        # Memoize the fallback "now" on the record so every base_time call within a
        # single create resolves to the SAME instant — otherwise two Time.current
        # reads could straddle a period boundary (year/month/day) and disagree.
        record.created_at ||
          record.instance_variable_get(:@_sequenceable_now) ||
          record.instance_variable_set(:@_sequenceable_now, Time.current)
      end
    end
  end
end
