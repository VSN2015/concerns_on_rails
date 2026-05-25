require "active_support/concern"

module ConcernsOnRails
  module Models
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
        scope :only_deleted, -> { soft_deleted }
        # `with_deleted` peels off the default scope so deleted + non-deleted are both returned.
        scope :with_deleted, -> { unscope(where: soft_delete_field) }
        # Records soft-deleted within the last `duration` (e.g. `deleted_within(7.days)`).
        scope :deleted_within, ->(duration) { soft_deleted.where(soft_delete_field => duration.ago..) }
        # Optionally, uncomment to hide deleted by default:
        default_scope { without_deleted }
      end

      class_methods do
        include ConcernsOnRails::Support::ColumnGuard

        # Define soft delete field and options
        # Example:
        #   soft_deletable_by :deleted_at, touch: false
        def soft_deletable_by(field = nil, touch: true)
          self.soft_delete_field = field || :deleted_at
          self.soft_delete_touch = touch
          ensure_columns!("ConcernsOnRails::Models::SoftDeletable", soft_delete_field)
        end

        # Override destroy_all to perform soft delete on all records
        def destroy_all
          all.each(&:soft_delete!)
        end

        # Provide really_destroy_all to hard delete all records
        def really_destroy_all
          unscoped.delete_all
        end

        # Restore every soft-deleted record (mirror of the destroy_all override).
        def restore_all
          soft_deleted.each(&:restore!)
        end
      end

      # Soft delete hooks
      def before_soft_delete; end
      def after_soft_delete; end
      def before_restore; end
      def after_restore; end

      def soft_delete!
        return true if deleted?

        before_soft_delete
        result = if self.class.soft_delete_touch
                   update(self.class.soft_delete_field => Time.zone.now)
                 else
                   update_column(self.class.soft_delete_field, Time.zone.now)
                 end
        after_soft_delete if result
        result
      end

      def restore!
        return true unless deleted?

        before_restore
        result = if self.class.soft_delete_touch
                   update(self.class.soft_delete_field => nil)
                 else
                   update_column(self.class.soft_delete_field, nil)
                 end
        after_restore if result
        result
      end

      # bypasses AR callbacks and validations — use when you want a true hard delete
      def really_delete!
        self.class.unscoped.where(self.class.primary_key => id).delete_all
        freeze
      end

      def deleted?
        self[self.class.soft_delete_field].present?
      end

      # alias methods
      # define here to avoid issue: undefined method `deleted?' for module `ConcernsOnRails::Models::SoftDeletable'
      alias is_soft_deleted? deleted?
      alias soft_deleted? deleted?

      def is_really_deleted?
        !self.class.unscoped.exists?(id)
      end
    end
  end
end

# Usage Example:
# class MyModel < ApplicationRecord
#   include ConcernsOnRails::Models::SoftDeletable
#   soft_deletable_by :deleted_at
# end
