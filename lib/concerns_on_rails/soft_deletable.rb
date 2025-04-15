require "active_support/concern"

module ConcernsOnRails
  module SoftDeletable
    extend ActiveSupport::Concern

    included do
      # declare class attributes and set default values
      class_attribute :soft_delete_field, instance_accessor: false, default: :deleted_at
      
      # scopes
      scope :active,          -> { where(soft_delete_field => nil) }
      scope :without_deleted, -> { where(soft_delete_field => nil) }
      scope :soft_deleted,    -> { where.not(soft_delete_field => nil) }
    end

    class_methods do
      # Define soft delete field
      # Example:
      #   soft_deletable_by :deleted_at
      def soft_deletable_by(field = nil)
        self.soft_delete_field = field || :deleted_at

        # validate soft_delete_field exists in database
        unless column_names.include?(soft_delete_field.to_s)
          raise ArgumentError, "ConcernsOnRails::SoftDeletable: soft_delete_field '#{soft_delete_field}' does not exist in the database"
        end
      end
    end

    alias_method :is_soft_deleted?, :deleted?

    # add soft delete methods
    def soft_delete!
      update(self.class.soft_delete_field => Time.zone.now)
    end

    def really_delete
      destroy
    end
  
    def restore!
      update(self.class.soft_delete_field => nil)
    end
  
    def deleted?
      self[self.class.soft_delete_field].present?
    end

    # Is really deleted?
    def is_really_deleted?
      !self.class.exists?(id)
    end
  end
end
