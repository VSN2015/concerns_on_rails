require "active_support/concern"
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/affix"
require "concerns_on_rails/support/batch_ops"

module ConcernsOnRails
  module Models
    module SoftDeletable
      extend ActiveSupport::Concern

      SCOPE_BASES = %i[active without_deleted soft_deleted only_deleted with_deleted deleted_within].freeze

      included do
        # declare class attributes and set default values
        class_attribute :soft_delete_field, instance_accessor: false, default: :deleted_at
        class_attribute :soft_delete_touch, instance_accessor: false, default: true
        # Whether `.all` hides soft-deleted rows via a default_scope. ON by default for
        # backwards compatibility; opt out with `soft_deletable_by ..., default_scope: false`.
        # A default_scope is sticky and breaks unscoped joins / uniqueness validations /
        # eager-loading, so new models are encouraged to disable it and chain `.without_deleted`.
        class_attribute :soft_delete_default_scope, instance_accessor: false, default: true
        class_attribute :soft_delete_scope_names, instance_accessor: false,
                                                  default: SCOPE_BASES.to_h { |b| [b, b] }.freeze
        class_attribute :soft_delete_captured_scopes, instance_accessor: false, default: {}.freeze

        define_soft_delete_scopes(nil, nil)
        self.soft_delete_captured_scopes =
          ConcernsOnRails::Support::Affix.capture(self, SCOPE_BASES).freeze

        # Hide soft-deleted rows from `.all` only when enabled (the default). The block is
        # evaluated lazily, so toggling `soft_delete_default_scope` via the macro takes effect —
        # and it resolves the scope through the names map, so an affixed model still filters.
        default_scope do
          soft_delete_default_scope ? public_send(soft_delete_scope_names.fetch(:without_deleted)) : all
        end
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
        def soft_deletable_by(field = nil, touch: true, default_scope: true, prefix: nil, suffix: nil)
          self.soft_delete_field = field || :deleted_at
          self.soft_delete_touch = touch
          self.soft_delete_default_scope = default_scope
          ensure_columns!("ConcernsOnRails::Models::SoftDeletable", soft_delete_field, types: :datetime)
          return unless prefix || suffix

          define_soft_delete_scopes(prefix, suffix)
          ConcernsOnRails::Support::Affix.retire!(self, soft_delete_captured_scopes,
                                                  label: "ConcernsOnRails::Models::SoftDeletable")
        end

        # Soft-delete every matching record. Returns the Integer count of
        # records transitioned (already-deleted rows are skipped and keep their
        # original timestamp). A record that fails raises
        # ActiveRecord::RecordNotSaved and rolls the whole batch back — before
        # 1.22 the rollback happened silently and the method returned nil. With
        # `touch: false` and no overridden hooks this is a single UPDATE.
        def soft_delete_all
          pending = all.where(soft_delete_field => nil)
          return pending.update_all(soft_delete_field => Time.zone.now) if soft_delete_batch_fast_path?(:soft_delete)

          ConcernsOnRails::Support::BatchOps.run(
            pending,
            label: "ConcernsOnRails::Models::SoftDeletable",
            message: "failed to soft-delete record",
            &:soft_delete!
          )
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
          deleted = all.public_send(soft_delete_scope_names.fetch(:soft_deleted))
          return deleted.update_all(soft_delete_field => nil) if soft_delete_batch_fast_path?(:restore)

          ConcernsOnRails::Support::BatchOps.run(
            deleted,
            label: "ConcernsOnRails::Models::SoftDeletable",
            message: "failed to restore record",
            &:restore!
          )
        end

        private

        # Built here rather than inline in `included do` so the names can be
        # affixed. Every scope that references another scope resolves it
        # through soft_delete_scope_names — a hard-coded symbol would break
        # the moment a model affixes.
        def define_soft_delete_scopes(prefix, suffix)
          prefix = ConcernsOnRails::Support::Affix.normalize(prefix, default: soft_delete_field)
          suffix = ConcernsOnRails::Support::Affix.normalize(suffix, default: soft_delete_field)
          self.soft_delete_scope_names = SCOPE_BASES.to_h do |base|
            [base, ConcernsOnRails::Support::Affix.name(base, prefix: prefix, suffix: suffix)]
          end.freeze

          soft_deleted_name = soft_delete_scope_names.fetch(:soft_deleted)

          scope soft_delete_scope_names[:active],
                -> { unscope(where: soft_delete_field).where(soft_delete_field => nil) }
          scope soft_delete_scope_names[:without_deleted],
                -> { unscope(where: soft_delete_field).where(soft_delete_field => nil) }
          scope soft_delete_scope_names[:soft_deleted],
                -> { unscope(where: soft_delete_field).where.not(soft_delete_field => nil) }
          scope soft_delete_scope_names[:only_deleted],
                -> { public_send(soft_deleted_name) }
          # `with_deleted` peels off the default scope so deleted + non-deleted are both returned.
          scope soft_delete_scope_names[:with_deleted],
                -> { unscope(where: soft_delete_field) }
          # Records soft-deleted within the last `duration` (e.g. `deleted_within(7.days)`).
          # Arel `gteq` rather than an endless range (`x..`): AR only translates an
          # endless range to `>=` on Rails 6.0+, but this gem supports Rails >= 5.0.
          # arel_table also qualifies the column with the table name, so the scope
          # stays unambiguous inside joins against tables sharing the column.
          scope soft_delete_scope_names[:deleted_within], lambda { |duration|
            public_send(soft_deleted_name).where(arel_table[soft_delete_field].gteq(duration.ago))
          }
        end

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
          ConcernsOnRails::Support::BatchOps.fast_path?(self, ConcernsOnRails::Models::SoftDeletable, *methods)
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
