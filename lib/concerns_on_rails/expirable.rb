require "active_support/concern"

module ConcernsOnRails
  module Expirable
    extend ActiveSupport::Concern

    DEFAULT_FIELD = :expires_at

    included do
      class_attribute :expirable_field, instance_accessor: false, default: DEFAULT_FIELD

      scope :active, lambda {
        column = arel_table[expirable_field]
        where(column.eq(nil).or(column.gt(Time.zone.now)))
      }

      scope :expired, lambda {
        where(arel_table[expirable_field].lteq(Time.zone.now))
      }

      scope :expiring_within, lambda { |duration|
        column = arel_table[expirable_field]
        now = Time.zone.now
        where(column.gt(now)).where(column.lteq(now + duration))
      }
    end

    class_methods do
      # Configure the expiry column.
      # Example:
      #   expirable_by                  # uses :expires_at
      #   expirable_by :valid_until
      def expirable_by(field = DEFAULT_FIELD)
        self.expirable_field = field.to_sym

        return if column_names.include?(expirable_field.to_s)

        raise ArgumentError, "ConcernsOnRails::Expirable: expirable_field '#{expirable_field}' does not exist in the database"
      end
    end

    def active?
      !expired?
    end

    # nil means never expires; equal-to-now is treated as expired (exclusive boundary).
    def expired?
      value = self[self.class.expirable_field]
      return false if value.nil?

      value <= Time.zone.now
    end

    def expire!(time = Time.zone.now)
      update(self.class.expirable_field => time)
    end

    # Push expiry forward by `by:`. If the record has no expiry yet, or has
    # already expired, the new expiry is `now + by`. Otherwise it's added to
    # the existing expiry.
    def extend_expiry!(by:)
      update(self.class.expirable_field => expiry_extension_base + by)
    end

    # Returns an ActiveSupport::Duration of how long until expiry, or nil
    # when there's no expiry set, or 0.seconds when already expired.
    def time_until_expiry
      value = self[self.class.expirable_field]
      return nil if value.nil?

      now = Time.zone.now
      return 0.seconds if value <= now

      (value - now).seconds
    end

    private

    def expiry_extension_base
      value = self[self.class.expirable_field]
      now = Time.zone.now
      value.nil? || value <= now ? now : value
    end
  end
end
