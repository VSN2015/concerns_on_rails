require "active_support/concern"

module ConcernsOnRails
  module Publishable
    extend ActiveSupport::Concern

    # instance methods
    included do
      # declare class attributes and set default values
      class_attribute :publishable_field, instance_accessor: false
      self.publishable_field ||= :published_at
    end

    # class methods
    class_methods do
      # Define publishable field
      # Example:
      #   publishable_by :published_at
      def publishable_by(field = nil)
        self.publishable_field = field || :published_at

        # validate publishable_field exists in database
        unless column_names.include?(publishable_field.to_s)
          raise ArgumentError, "ConcernsOnRails::Publishable: publishable_field '#{publishable_field}' does not exist in the database"
        end

        scope :published, -> { where(arel_table[publishable_field].not_eq(nil)) }
        scope :unpublished, -> { where(arel_table[publishable_field].eq(nil)) }
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
      self[self.class.publishable_field].present?
    end

    # Check if the record is unpublished
    # Example:
    #   record.unpublished?
    def unpublished?
      !published?
    end
  end
end
