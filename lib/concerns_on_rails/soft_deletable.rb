require "active_support/concern"

module ConcernsOnRails
  module SoftDeletable
    extend ActiveSupport::Concern

    included do
      # declare class attributes and set default values
      class_attribute :soft_delete_field, instance_accessor: false, default: :deleted_at
      class_attribute :soft_delete_touch, instance_accessor: false, default: true
      
      # scopes
      scope :active, -> { unscope(where: soft_delete_field).where(soft_delete_field => nil) }
      scope :without_deleted, -> { unscope(where: soft_delete_field).where(soft_delete_field => nil) }
      scope :soft_deleted, -> { unscope(where: soft_delete_field).where.not(soft_delete_field => nil) }
      # Optionally, uncomment to hide deleted by default:
      # default_scope { without_deleted }

      # define callbacks
      define_model_callbacks :soft_delete
      define_model_callbacks :restore
    end

    class_methods do
      # Define soft delete field and options
      # Example:
      #   soft_deletable_by :deleted_at, touch: false
      def soft_deletable_by(field = nil, touch: true)
        self.soft_delete_field = field || :deleted_at
        self.soft_delete_touch = touch

        unless column_names.include?(soft_delete_field.to_s)
          raise ArgumentError, "ConcernsOnRails::SoftDeletable: soft_delete_field '#{soft_delete_field}' does not exist in the database"
        end
      end
    end

    # Soft delete hooks
    def before_soft_delete; end
    def after_soft_delete; end
    def before_restore; end
    def after_restore; end

    # add soft delete methods
    def soft_delete!
      run_callbacks(:soft_delete) do
        before_soft_delete
        if self.class.soft_delete_touch
          update(self.class.soft_delete_field => Time.zone.now).tap do |result|
            touch if respond_to?(:touch)
            after_soft_delete if result
          end
        else
          update_column(self.class.soft_delete_field, Time.zone.now).tap do |result|
            after_soft_delete if result
          end
        end
      end
    end

    # really delete the record
    def really_delete!
      destroy
    end
  
    def restore!
      run_callbacks(:restore) do
        before_restore
        if self.class.soft_delete_touch
          update(self.class.soft_delete_field => nil).tap do |result|
            touch if respond_to?(:touch)
            after_restore if result
          end
        else
          update_column(self.class.soft_delete_field, nil).tap do |result|
            after_restore if result
          end
        end
      end
    end
  
    def deleted?
      self[self.class.soft_delete_field].present?
    end

    # alias methods
    # define here to avoid issue: undefined method `deleted?' for module `ConcernsOnRails::SoftDeletable'
    alias_method :is_soft_deleted?, :deleted?
    alias_method :soft_deleted?, :deleted?

    # Is really deleted?
    def is_really_deleted?
      !self.class.exists?(id)
    end
  end
end

# Usage Example:
# class MyModel < ApplicationRecord
#   include ConcernsOnRails::SoftDeletable
#   soft_deletable_by :deleted_at
# end
