require "active_support/concern"
require "concerns_on_rails/support/column_guard"

module ConcernsOnRails
  module Models
    module SoftDeletable
      extend ActiveSupport::Concern

      included do
        # declare class attributes and set default values
        class_attribute :soft_delete_field, instance_accessor: false, default: :deleted_at
        class_attribute :soft_delete_touch, instance_accessor: false, default: true
        # Whether `.all` hides soft-deleted rows via a default_scope. ON by default for
        # backwards compatibility; opt out with `soft_deletable_by ..., default_scope: false`.
        # A default_scope is sticky and breaks unscoped joins / uniqueness validations /
        # eager-loading, so new models are encouraged to disable it and chain `.without_deleted`.
        class_attribute :soft_delete_default_scope, instance_accessor: false, default: true

        # scopes
        scope :active, -> { unscope(where: soft_delete_field).where(soft_delete_field => nil) }
        scope :without_deleted, -> { unscope(where: soft_delete_field).where(soft_delete_field => nil) }
        scope :soft_deleted, -> { unscope(where: soft_delete_field).where.not(soft_delete_field => nil) }
        scope :only_deleted, -> { soft_deleted }
        # `with_deleted` peels off the default scope so deleted + non-deleted are both returned.
        scope :with_deleted, -> { unscope(where: soft_delete_field) }
        # Records soft-deleted within the last `duration` (e.g. `deleted_within(7.days)`).
        # Uses an explicit `>=` rather than an endless range (`x..`): AR only
        # translates an endless range to a `>=` predicate on Rails 6.0+, but this
        # gem supports Rails >= 5.0.
        scope :deleted_within, lambda { |duration|
          soft_deleted.where("#{connection.quote_column_name(soft_delete_field.to_s)} >= ?", duration.ago)
        }

        # Hide soft-deleted rows from `.all` only when enabled (the default). The block is
        # evaluated lazily, so toggling `soft_delete_default_scope` via the macro takes effect.
        default_scope { soft_delete_default_scope ? without_deleted : all }
      end

      # A real module (not `class_methods do`) so the batch helpers and their
      # private fast-path predicate aren't constrained by Metrics/BlockLength
      # (the Stateable/Auditable precedent). ActiveSupport::Concern auto-extends it.
      module ClassMethods
        include ConcernsOnRails::Support::ColumnGuard

        # Define soft delete field and options.
        # Example:
        #   soft_deletable_by :deleted_at, touch: false
        #   soft_deletable_by :deleted_at, default_scope: false  # don't hide deleted rows from .all
        def soft_deletable_by(field = nil, touch: true, default_scope: true)
          self.soft_delete_field = field || :deleted_at
          self.soft_delete_touch = touch
          self.soft_delete_default_scope = default_scope
          ensure_columns!("ConcernsOnRails::Models::SoftDeletable", soft_delete_field, types: :datetime)
        end

        # Soft-delete every matching record. Returns the Integer count of
        # records transitioned (already-deleted rows are skipped and keep their
        # original timestamp). A record that fails raises
        # ActiveRecord::RecordNotSaved and rolls the whole batch back — before
        # 1.22 the rollback happened silently and the method returned nil. With
        # `touch: false` and no overridden hooks this is a single UPDATE.
        def soft_delete_all
          if soft_delete_batch_fast_path?(:soft_delete)
            return all.where(soft_delete_field => nil).update_all(soft_delete_field => Time.zone.now)
          end

          transaction do
            all.to_a.count do |record|
              next false if record.deleted?

              record.soft_delete! ||
                raise(ActiveRecord::RecordNotSaved.new(
                        "ConcernsOnRails::Models::SoftDeletable: failed to soft-delete record", record
                      ))
              true
            end
          end
        end

        # Override destroy_all to soft delete. Kept for backwards compatibility, but prefer the
        # explicit `soft_delete_all` — silently redefining a standard AR method is a known footgun
        # (and unlike AR's destroy_all this returns a count, not the records).
        def destroy_all
          soft_delete_all
        end

        # Hard-delete every record matching the CURRENT relation — including
        # soft-deleted rows (only the soft-delete column's predicates are
        # peeled off). Note that `unscope` also drops a caller's own condition
        # on that column, so `only_deleted.really_destroy_all` widens to the
        # whole relation — use `soft_deleted.delete_all` to purge trash only.
        # (Before 1.22 this ignored the relation entirely and hard-deleted the
        # complete table.)
        def really_destroy_all
          all.unscope(where: soft_delete_field).delete_all
        end

        # Restore every soft-deleted record (mirror of soft_delete_all):
        # Integer count, RecordNotSaved + rollback on failure, single UPDATE
        # when the fast path applies.
        def restore_all
          return soft_deleted.update_all(soft_delete_field => nil) if soft_delete_batch_fast_path?(:restore)

          transaction do
            soft_deleted.to_a.count do |record|
              record.restore! ||
                raise(ActiveRecord::RecordNotSaved.new(
                        "ConcernsOnRails::Models::SoftDeletable: failed to restore record", record
                      ))
              true
            end
          end
        end

        private

        # The single-UPDATE fast path is only safe when per-record behavior
        # cannot differ from update_all: `touch: false` (the per-record path is
        # update_column — already no validations/callbacks/updated_at) and none
        # of the gem's hooks or bang methods overridden by the host model.
        def soft_delete_batch_fast_path?(kind)
          return false if soft_delete_touch

          methods = if kind == :restore
                      %i[before_restore after_restore restore!]
                    else
                      %i[before_soft_delete after_soft_delete soft_delete!]
                    end
          methods.all? { |m| instance_method(m).owner == ConcernsOnRails::Models::SoftDeletable }
        end
      end

      # Soft delete hooks
      def before_soft_delete; end
      def after_soft_delete; end
      def before_restore; end
      def after_restore; end

      def soft_delete!
        return true if deleted?

        result = false
        # Wrap the timestamp change and its hooks in a transaction so a raising
        # before/after hook rolls the change back instead of leaving a half-applied state.
        transaction do
          before_soft_delete
          result = if self.class.soft_delete_touch
                     update(self.class.soft_delete_field => Time.zone.now)
                   else
                     update_column(self.class.soft_delete_field, Time.zone.now)
                   end
          after_soft_delete if result
        end
        result
      end

      def restore!
        return true unless deleted?

        result = false
        transaction do
          before_restore
          result = if self.class.soft_delete_touch
                     update(self.class.soft_delete_field => nil)
                   else
                     update_column(self.class.soft_delete_field, nil)
                   end
          after_restore if result
        end
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
