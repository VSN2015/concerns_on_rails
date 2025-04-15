require "active_support/concern"
require "acts_as_list"

module ConcernsOnRails
  module Sortable
    extend ActiveSupport::Concern

    # instance methods
    # include Sortable in model to enable sorting
    # Example:
    #   class Task < ApplicationRecord
    #     include Sortable
    #     sortable_by :priority
    #   end
    included do
      # declare class attributes
      class_attribute :sortable_field, instance_accessor: false
      class_attribute :sortable_direction, instance_accessor: false

      # set default values
      self.sortable_field ||= :position
      self.sortable_direction ||= :asc

      # we cannot use acts_as_list here
      default_scope { order(sortable_field => sortable_direction) }
    end

    # class methods
    # Example: Task.sortable_by(priority: :asc)
    class_methods do
      # Define sortable field and direction
      # Example:
      #   sortable_by :position
      #   sortable_by position: :asc
      #   sortable_by position: :desc
      #
      #   sortable_by :position, use_acts_as_list: false
      def sortable_by(field_config, use_acts_as_list: true)
        # parse field_config
        field, direction = parse_sortable_config(field_config)

        # validate direction and must be :asc or :desc
        direction = :asc unless %i[asc desc].include?(direction)

        # set class attributes
        self.sortable_field = field
        self.sortable_direction = direction

        validate_sortable_field!

        # add acts_as_list and default scope
        # Setup sorting behaviors
        acts_as_list column: sortable_field if use_acts_as_list

        # add default scope: position => asc
        default_scope { order(sortable_field => sortable_direction) }
      end

      private
      def parse_sortable_config(config)
        if config.is_a?(Hash)
          # extract key and value
          # when we call .first, we get the first key-value pair
          # Example: { position: :asc }.first => ["position", :asc]
          key, value = config.first
          [key.to_sym, value.to_sym]
        else
          [config.to_sym, :asc]
        end
      end

      # Validate sortable_field exists in database
      def validate_sortable_field!
        unless column_names.include?(sortable_field.to_s)
          raise ArgumentError, "ConcernsOnRails::Sortable: sortable_field '#{sortable_field}' does not exist in the database"
        end
      end
    end
  end
end
