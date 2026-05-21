require "active_support/concern"

module ConcernsOnRails
  module Models
    # Boolean active/inactive toggle backed by a single column.
    #
    #   class Subscription < ApplicationRecord
    #     include ConcernsOnRails::Activatable
    #
    #     activatable_by             # defaults to :active
    #     # activatable_by :enabled  # custom column name
    #   end
    #
    #   Subscription.active     # WHERE active = TRUE
    #   Subscription.inactive   # WHERE active = FALSE OR active IS NULL
    #
    # NULL is treated as inactive, mirroring how unset booleans behave in most apps.
    #
    # Note: SoftDeletable also defines a `.active` scope (alias of `.without_deleted`).
    # If both concerns are included on the same model, the later one wins.
    module Activatable
      extend ActiveSupport::Concern

      DEFAULT_FIELD = :active

      included do
        class_attribute :activatable_field, instance_accessor: false, default: DEFAULT_FIELD
      end

      class_methods do
        def activatable_by(field = DEFAULT_FIELD)
          self.activatable_field = field.to_sym

          unless column_names.include?(activatable_field.to_s)
            raise ArgumentError,
                  "ConcernsOnRails::Models::Activatable: activatable_field '#{activatable_field}' does not exist in the database"
          end

          scope :active,   -> { where(activatable_field => true) }
          scope :inactive, -> { where(activatable_field => [false, nil]) }
        end
      end

      def active?
        self[self.class.activatable_field] == true
      end

      def inactive?
        !active?
      end

      def activate!
        update(self.class.activatable_field => true)
      end

      def deactivate!
        update(self.class.activatable_field => false)
      end

      def toggle_active!
        active? ? deactivate! : activate!
      end
    end
  end
end
