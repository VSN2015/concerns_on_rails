require "active_support/concern"
require "friendly_id"

module ConcernsOnRails
  module Sluggable
    extend ActiveSupport::Concern

    # instance methods
    included do
      # declare class attributes and set default values
      class_attribute :sluggable_field, instance_accessor: false
      self.sluggable_field ||= :name

      extend FriendlyId
      # we need use a lambda to access the instance variable
      # instead of friendly_id :slug_source, use: :slugged
      friendly_id :slug_source, use: :slugged
      # friendly_id ->(record) { record.slug_source }, use: :slugged

      # we must override should_generate_new_friendly_id? to support update slug
      # if we don't override this method, friendly_id will not generate the new slug when update
      define_method :should_generate_new_friendly_id? do
        field = self.class.sluggable_field
        respond_to?("will_save_change_to_#{field}?") && send("will_save_change_to_#{field}?")
      end
    end

    # class methods
    class_methods do
      # Define sluggable field
      # Example:
      #   sluggable_by :wonderful_name
      def sluggable_by(field)
        self.sluggable_field = field.to_sym

        validate_sluggable_field!
      end

      private
      # Validate sluggable_field exists in database
      def validate_sluggable_field!
        unless column_names.include?(sluggable_field.to_s)
          raise ArgumentError, "ConcernsOnRails::Sluggable: sluggable_field '#{sluggable_field}' does not exist in the database"
        end
      end
    end

    # Instance methods
    # Returns the source for the slug
    # we are calling the class attribute, so we can use it in the lambda
    # Example:
    #   record.slug_source
    def slug_source
      if self.class.sluggable_field.present? && respond_to?(self.class.sluggable_field)
        send(self.class.sluggable_field)
      elsif respond_to?(:title)
        title
      else
        to_s
      end
    end
  end
end