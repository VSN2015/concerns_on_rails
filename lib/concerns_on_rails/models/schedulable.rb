require "active_support/concern"
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/affix"

module ConcernsOnRails
  module Models
    module Schedulable
      extend ActiveSupport::Concern

      DEFAULT_STARTS_AT_FIELD = :starts_at
      DEFAULT_ENDS_AT_FIELD = :ends_at
      SCOPE_BASES = %i[active_at current upcoming expired].freeze

      included do
        class_attribute :schedulable_starts_at_field, instance_accessor: false, default: DEFAULT_STARTS_AT_FIELD
        class_attribute :schedulable_ends_at_field, instance_accessor: false, default: DEFAULT_ENDS_AT_FIELD
        class_attribute :schedulable_scope_names, instance_accessor: false,
                                                  default: SCOPE_BASES.to_h { |b| [b, b] }.freeze
        class_attribute :schedulable_captured_scopes, instance_accessor: false, default: {}.freeze

        define_schedulable_scopes(nil, nil)
        self.schedulable_captured_scopes =
          ConcernsOnRails::Support::Affix.capture(self, SCOPE_BASES).freeze
      end

      class_methods do # rubocop:disable Metrics/BlockLength
        include ConcernsOnRails::Support::ColumnGuard

        # Configure the start/end timestamp columns.
        # Example:
        #   schedulable_by                                          # uses :starts_at and :ends_at
        #   schedulable_by starts_at: :starts_on, ends_at: :ends_on
        #   schedulable_by starts_at: nil, ends_at: :expires_at     # open-ended start
        def schedulable_by(starts_at: DEFAULT_STARTS_AT_FIELD, ends_at: DEFAULT_ENDS_AT_FIELD,
                           prefix: nil, suffix: nil)
          self.schedulable_starts_at_field = starts_at&.to_sym
          self.schedulable_ends_at_field = ends_at&.to_sym

          if schedulable_starts_at_field.nil? && schedulable_ends_at_field.nil?
            raise ArgumentError, "ConcernsOnRails::Models::Schedulable: at least one of starts_at: or ends_at: must be configured"
          end

          ensure_columns!("ConcernsOnRails::Models::Schedulable",
                          schedulable_starts_at_field, schedulable_ends_at_field, types: :datetime)
          return unless prefix || suffix

          define_schedulable_scopes(prefix, suffix)
          ConcernsOnRails::Support::Affix.retire!(self, schedulable_captured_scopes,
                                                  label: "ConcernsOnRails::Models::Schedulable")
        end

        private

        # Built here rather than inline in `included do` so the names can be
        # affixed. `current` resolves `active_at` through the names map — a
        # literal call would break under an affix.
        def define_schedulable_scopes(prefix, suffix)
          default_field = schedulable_starts_at_field || schedulable_ends_at_field
          prefix = ConcernsOnRails::Support::Affix.normalize(prefix, default: default_field)
          suffix = ConcernsOnRails::Support::Affix.normalize(suffix, default: default_field)
          self.schedulable_scope_names = SCOPE_BASES.to_h do |base|
            [base, ConcernsOnRails::Support::Affix.name(base, prefix: prefix, suffix: suffix)]
          end.freeze

          active_at_name = schedulable_scope_names.fetch(:active_at)

          scope active_at_name, lambda { |time|
            starts_field = schedulable_starts_at_field
            ends_field = schedulable_ends_at_field
            relation = all
            relation = relation.where(arel_table[starts_field].lteq(time)) if starts_field
            relation = relation.where(arel_table[ends_field].eq(nil).or(arel_table[ends_field].gt(time))) if ends_field
            relation
          }

          scope schedulable_scope_names[:current], -> { public_send(active_at_name, Time.zone.now) }

          scope schedulable_scope_names[:upcoming], lambda {
            field = schedulable_starts_at_field
            next none unless field

            where(arel_table[field].gt(Time.zone.now))
          }

          scope schedulable_scope_names[:expired], lambda {
            field = schedulable_ends_at_field
            next none unless field

            where(arel_table[field].lteq(Time.zone.now))
          }
        end
      end # rubocop:enable Metrics/BlockLength

      # Is the record active at the given time? Inclusive start, exclusive end.
      def active_at?(time)
        schedulable_started_by?(time) && schedulable_not_ended_at?(time)
      end

      def current?
        active_at?(Time.zone.now)
      end

      def upcoming?
        field = self.class.schedulable_starts_at_field
        value = field && self[field]
        return false unless value

        value > Time.zone.now
      end

      def expired?
        field = self.class.schedulable_ends_at_field
        value = field && self[field]
        return false unless value

        value <= Time.zone.now
      end

      def start!(time = Time.zone.now)
        field = self.class.schedulable_starts_at_field
        raise "ConcernsOnRails::Models::Schedulable: starts_at field not configured" unless field

        update(field => time)
      end

      def finish!(time = Time.zone.now)
        field = self.class.schedulable_ends_at_field
        raise "ConcernsOnRails::Models::Schedulable: ends_at field not configured" unless field

        update(field => time)
      end

      # Update either or both window columns: only the keywords you pass are
      # written (nil clears a side). Passing a value for a column that isn't
      # configured raises instead of silently dropping it (the pre-1.22
      # behavior), and single-column models no longer have to fabricate the
      # missing keyword.
      def reschedule!(**changes)
        extra = changes.keys - %i[starts_at ends_at]
        raise ArgumentError, "ConcernsOnRails::Models::Schedulable: unknown option(s): #{extra.join(', ')}" if extra.any?
        raise ArgumentError, "ConcernsOnRails::Models::Schedulable: reschedule! needs starts_at: and/or ends_at:" if changes.empty?

        attrs = changes.to_h do |kind, value|
          field = kind == :starts_at ? self.class.schedulable_starts_at_field : self.class.schedulable_ends_at_field
          raise ArgumentError, "ConcernsOnRails::Models::Schedulable: #{kind} column is not configured" unless field

          [field, value]
        end
        update(attrs)
      end

      # Postfix private — the keyword form trips RuboCop's scope analysis
      # against the `private` inside the class_methods block (Publishable's
      # pattern).
      def schedulable_started_by?(time)
        field = self.class.schedulable_starts_at_field
        return true unless field

        value = self[field]
        !value.nil? && value <= time
      end
      private :schedulable_started_by?

      def schedulable_not_ended_at?(time)
        field = self.class.schedulable_ends_at_field
        return true unless field

        value = self[field]
        value.nil? || value > time
      end
      private :schedulable_not_ended_at?
    end
  end
end
