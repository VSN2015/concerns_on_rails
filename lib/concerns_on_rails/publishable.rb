require "active_support/concern"

module ConcernsOnRails
  module Publishable
    extend ActiveSupport::Concern

    included do
      class_attribute :publishable_field, instance_accessor: false, default: :published_at

      scope :published, -> { where(arel_table[publishable_field].lteq(Time.zone.now)) }
      scope :unpublished, -> {
        where(arel_table[publishable_field].eq(nil).or(arel_table[publishable_field].gt(Time.zone.now)))
      }
    end

    class_methods do
      def publishable_by(field = nil)
        self.publishable_field = field || :published_at

        unless column_names.include?(publishable_field.to_s)
          raise ArgumentError, "ConcernsOnRails::Publishable: publishable_field '#{publishable_field}' does not exist in the database"
        end
      end
    end

    # Instance methods
    # Publish the record
    # Example:
    #   record.publish!
    def publish!
      update(self.class.publishable_field => Time.zone.now)
    end

    # Unpublish the record
    # Example:
    #   record.unpublish!
    def unpublish!
      update(self.class.publishable_field => nil)
    end

    # Check if the record is published
    # Example:
    #   record.published?
    def published?
      value = self[self.class.publishable_field]
      return false unless value.present?
      value.respond_to?(:<=) ? value <= Time.zone.now : true
    end

    # Check if the record is unpublished
    # Example:
    #   record.unpublished?
    def unpublished?
      !published?
    end
  end
end
