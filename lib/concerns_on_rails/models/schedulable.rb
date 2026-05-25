require "active_support/concern"

module ConcernsOnRails
  module Models
    module Schedulable
      extend ActiveSupport::Concern

      DEFAULT_STARTS_AT_FIELD = :starts_at
      DEFAULT_ENDS_AT_FIELD = :ends_at

      included do
        class_attribute :schedulable_starts_at_field, instance_accessor: false, default: DEFAULT_STARTS_AT_FIELD
        class_attribute :schedulable_ends_at_field, instance_accessor: false, default: DEFAULT_ENDS_AT_FIELD

        scope :active_at, lambda { |time|
          starts_field = schedulable_starts_at_field
          ends_field = schedulable_ends_at_field
          relation = all
          relation = relation.where(arel_table[starts_field].lteq(time)) if starts_field
          relation = relation.where(arel_table[ends_field].eq(nil).or(arel_table[ends_field].gt(time))) if ends_field
          relation
        }

        scope :current, -> { active_at(Time.zone.now) }

        scope :upcoming, lambda {
          field = schedulable_starts_at_field
          next none unless field

          where(arel_table[field].gt(Time.zone.now))
        }

        scope :expired, lambda {
          field = schedulable_ends_at_field
          next none unless field

          where(arel_table[field].lteq(Time.zone.now))
        }
      end

      class_methods do
        include ConcernsOnRails::Support::ColumnGuard

        # Configure the start/end timestamp columns.
        # Example:
        #   schedulable_by                                          # uses :starts_at and :ends_at
        #   schedulable_by starts_at: :starts_on, ends_at: :ends_on
        #   schedulable_by starts_at: nil, ends_at: :expires_at     # open-ended start
        def schedulable_by(starts_at: DEFAULT_STARTS_AT_FIELD, ends_at: DEFAULT_ENDS_AT_FIELD)
          self.schedulable_starts_at_field = starts_at&.to_sym
          self.schedulable_ends_at_field = ends_at&.to_sym

          if schedulable_starts_at_field.nil? && schedulable_ends_at_field.nil?
            raise ArgumentError, "ConcernsOnRails::Models::Schedulable: at least one of starts_at: or ends_at: must be configured"
          end

          ensure_columns!("ConcernsOnRails::Models::Schedulable",
                          schedulable_starts_at_field, schedulable_ends_at_field)
        end
      end

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

      def reschedule!(starts_at:, ends_at:)
        attrs = {}
        starts_field = self.class.schedulable_starts_at_field
        ends_field = self.class.schedulable_ends_at_field
        attrs[starts_field] = starts_at if starts_field
        attrs[ends_field] = ends_at if ends_field
        update(attrs)
      end

      private

      def schedulable_started_by?(time)
        field = self.class.schedulable_starts_at_field
        return true unless field

        value = self[field]
        !value.nil? && value <= time
      end

      def schedulable_not_ended_at?(time)
        field = self.class.schedulable_ends_at_field
        return true unless field

        value = self[field]
        value.nil? || value > time
      end
    end
  end
end
