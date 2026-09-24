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

      # Relation of existing rows that share this record's scope (and period, when
      # reset is enabled). Reads from `unscoped` so a model's default_scope never
      # hides rows the counter must account for — and from the class that
      # DECLARED the macro (cfg[:owner]), not the receiver: declared on an STI
      # base, every subclass draws from one table-wide counter (a subclass's own
      # relation would filter on its type and siblings would collide); declared
      # on each subclass, each keeps its own gap-free sequence. A subclass that
      # merely inherits the config shares its declaring parent's counter, and
      # the rows of a descendant that re-declared its own sequence are left out.
      def sequence_relation(field, record, scope_attrs)
        cfg = sequenceable_config.fetch(field)
        numbering = sequence_numbering_class(cfg)
        rel = sequence_exclude_redeclared(numbering.unscoped, numbering, field, cfg)

        cfg[:scope].each do |col|
          value = record ? record[col] : sequence_preview_scope_value(col, scope_attrs)
          rel = rel.where(col => value)
        end

        return rel if cfg[:reset] == :never

        rel.where(created_at: period_range(cfg[:reset], base_time(record)))
      end

      # The declaring class, when it owns this receiver's table. An abstract
      # declarer (or one on another table) has no rows of its own, so fall back
      # to the receiver's first concrete ancestor on the same table — its STI
      # base (numbering over the abstract class raised TableNotSpecified).
      def sequence_numbering_class(cfg)
        owner = cfg[:owner] || self
        return owner if !owner.abstract_class? && owner.table_name == table_name

        klass = self
        klass = klass.superclass while sequence_same_table_parent?(klass)
        klass
      end

      def sequence_same_table_parent?(klass)
        parent = klass.superclass
        parent < ActiveRecord::Base && !parent.abstract_class? && parent.table_name == klass.table_name
      end

      # A descendant that called sequenceable_by itself numbers its own series
      # (it owns a different config), so its rows — and its subtree's — must
      # not raise this series' MAX. Rows with a NULL type (base records) stay.
      # NOTE: relies on `descendants`, which is complete only once the classes
      # are loaded (eager loading); prefer scope: :type for per-type series.
      def sequence_exclude_redeclared(rel, numbering, field, cfg)
        column = numbering.inheritance_column.to_s
        return rel unless numbering.column_names.include?(column)

        types = numbering.descendants.filter_map do |klass|
          klass.sti_name if sequence_redeclared_by?(klass, numbering, field, cfg)
        end
        return rel if types.empty?

        attribute = numbering.arel_table[column]
        rel.where(attribute.eq(nil).or(attribute.not_in(types)))
      end

      # A named, concrete STI descendant on the same table whose own config
      # for `field` came from a different sequenceable_by call.
      def sequence_redeclared_by?(klass, numbering, field, cfg)
        return false if klass.name.nil? || klass.abstract_class? || klass.table_name != numbering.table_name

        own = klass.sequenceable_config[field]
        own ? !own[:owner].equal?(cfg[:owner]) : false
      end

      # next_<field> has no record to read the scope from. An omitted STI type
      # column resolves to what a new record of the RECEIVING class would carry
      # (its sti_name for a subclass, NULL for the base), so `Sub.next_number`
      # previews the value `Sub.create!` will actually get under scope: :type.
      def sequence_preview_scope_value(col, scope_attrs)
        return scope_attrs[col] if scope_attrs.key?(col)
        return scope_attrs[col.to_s] if scope_attrs.key?(col.to_s)
        return nil unless col.to_s == inheritance_column.to_s

        finder_needs_type_condition? ? sti_name : nil
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
