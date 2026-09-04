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
        # has_many / has_one association names soft-deleted and restored along
        # with this record (their models must include SoftDeletable too).
        class_attribute :soft_delete_cascade, instance_accessor: false, default: [].freeze

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
        #   soft_deletable_by :deleted_at, cascade: %i[comments attachments]
        #
        # `cascade:` names has_many / has_one associations whose records are
        # soft-deleted with the parent (inside its transaction, with the
        # parent's exact timestamp, through their own soft_delete! — hooks and
        # nested cascades included) and restored with it. Restore only touches
        # dependents carrying the parent's timestamp, so a comment someone
        # deleted independently last week stays deleted when the post comes
        # back. Every target model must include SoftDeletable. With a cascade
        # configured the single-UPDATE batch fast paths are disabled, since a
        # bulk UPDATE could not follow the associations.
        def soft_deletable_by(field = nil, touch: true, default_scope: true, prefix: nil, suffix: nil, cascade: nil)
          self.soft_delete_field = field || :deleted_at
          self.soft_delete_touch = touch
          self.soft_delete_default_scope = default_scope
          ensure_columns!("ConcernsOnRails::Models::SoftDeletable", soft_delete_field, types: :datetime)
          self.soft_delete_cascade = soft_delete_validate_cascade!(cascade)
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

        # Hard-delete every record matching the CURRENT relation — soft-deleted
        # rows included. Only the default scope's own `deleted_at IS NULL` is
        # peeled off; a caller's predicate on the column survives, so
        # `only_deleted.really_destroy_all` purges the trash and nothing else
        # and `deleted_within(30.days).really_destroy_all` purges recent trash.
        # (Before 1.22 this ignored the relation entirely and hard-deleted the
        # complete table; until this fix it unscoped the column outright, which
        # widened `only_deleted.really_destroy_all` to the whole relation.)
        def really_destroy_all
          soft_delete_without_default_scope.delete_all
        end

        # Restore every soft-deleted record in the relation (mirror of
        # soft_delete_all): Integer count, RecordNotSaved + rollback on
        # failure, single UPDATE when the fast path applies. Built against the
        # current relation rather than routed through the `soft_deleted` scope,
        # whose `unscope(where: deleted_at)` also stripped the CALLER's predicate
        # on the column — `deleted_within(1.hour).restore_all` restored the
        # whole trash can. (Same defect `publish_all` fixed in 1.27.)
        def restore_all
          deleted = soft_delete_without_default_scope.where.not(soft_delete_field => nil)
          return deleted.update_all(soft_delete_field => nil) if soft_delete_batch_fast_path?(:restore)

          ConcernsOnRails::Support::BatchOps.run(
            deleted,
            label: "ConcernsOnRails::Models::SoftDeletable",
            message: "failed to restore record",
            &:restore!
          )
        end

        private

        # The current relation with the DEFAULT SCOPE's soft-delete predicate
        # peeled off — and nothing else. `unscope(where: field)` (what the
        # scopes do) strips every predicate on the column, the caller's
        # included; so unscope, then put back the predicates the caller added on
        # that column. "Added by the caller" is the relation's where clause
        # minus the default scope's own, using the same structural WhereClause
        # arithmetic Rails' `merge`/`except` rely on. Predicates on OTHER
        # columns — a host model's own `default_scope { where(tenant_id:) }`
        # included — are never touched. With `default_scope: false` there is
        # nothing to peel.
        def soft_delete_without_default_scope
          relation = all
          return relation unless soft_delete_default_scope

          callers = relation.where_clause - default_scoped.where_clause
          callers_on_column = callers - callers.except(soft_delete_field.to_s)
          peeled = relation.unscope(where: soft_delete_field)
          peeled.where_clause += callers_on_column unless callers_on_column.empty?
          peeled
        end

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
        # Exempt from BatchOps.fast_path?'s validations gate for that first
        # reason: under `touch: false` both paths skip validations already, so
        # only the ownership half (`unoverridden?`) applies.
        def soft_delete_batch_fast_path?(kind)
          return false if soft_delete_touch || soft_delete_cascade.any?

          methods = if kind == :restore
                      %i[before_restore after_restore restore!]
                    else
                      %i[before_soft_delete after_soft_delete soft_delete!]
                    end
          ConcernsOnRails::Support::BatchOps.unoverridden?(self, ConcernsOnRails::Models::SoftDeletable, *methods)
        end

        # Each cascade target must be a has_many / has_one (not through) whose
        # model includes SoftDeletable. The association shape is checked at
        # class load; the target model is checked here when it already
        # resolves, and otherwise on first cascade (a not-yet-loaded or
        # anonymous class cannot be resolved from inside a class body).
        def soft_delete_validate_cascade!(cascade)
          names = Array(cascade).map(&:to_sym)
          names.each do |name|
            reflection = reflect_on_association(name)
            raise ArgumentError, "#{soft_delete_label}: cascade: '#{name}' is not an association of #{self.name}" unless reflection
            unless %i[has_many has_one].include?(reflection.macro)
              raise ArgumentError,
                    "#{soft_delete_label}: cascade: '#{name}' must be a has_many or has_one (got #{reflection.macro})"
            end
            if reflection.is_a?(ActiveRecord::Reflection::ThroughReflection)
              raise ArgumentError, "#{soft_delete_label}: cascade: '#{name}' is a :through association; cascade to the source instead"
            end

            soft_delete_check_cascade_target!(name, reflection) if soft_delete_cascade_resolvable?(reflection)
          end
          names.freeze
        end

        def soft_delete_cascade_resolvable?(reflection)
          reflection.klass
          true
        rescue NameError # NoMethodError (anonymous class: nil name) is a NameError
          false
        end

        def soft_delete_check_cascade_target!(name, reflection)
          return if reflection.klass.respond_to?(:soft_delete_field)

          raise ArgumentError,
                "#{soft_delete_label}: cascade: '#{name}' targets #{reflection.klass.name}, which does not include SoftDeletable"
        end

        def soft_delete_label
          "ConcernsOnRails::Models::SoftDeletable"
        end
      end

      # Soft delete hooks
      def before_soft_delete; end
      def after_soft_delete; end
      def before_restore; end
      def after_restore; end

      # `at:` sets the timestamp (default now) — it is what the cascade uses to
      # hand the parent's exact timestamp down, and lets callers backdate.
      def soft_delete!(at: Time.zone.now)
        return true if deleted?

        result = false
        # Wrap the timestamp change and its hooks in a transaction so a raising
        # before/after hook rolls the change back instead of leaving a half-applied state.
        transaction do
          before_soft_delete
          result = if self.class.soft_delete_touch
                     update(self.class.soft_delete_field => at)
                   else
                     update_column(self.class.soft_delete_field, at)
                   end
          soft_delete_cascade_dependents!(at) if result
          after_soft_delete if result
        end
        result
      end

      def restore!
        return true unless deleted?

        stamp = self[self.class.soft_delete_field]
        result = false
        transaction do
          before_restore
          result = if self.class.soft_delete_touch
                     update(self.class.soft_delete_field => nil)
                   else
                     update_column(self.class.soft_delete_field, nil)
                   end
          restore_cascaded_dependents!(stamp) if result
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

      private

      # Soft-delete every not-yet-deleted dependent with the parent's timestamp.
      # Goes through each record's own soft_delete! so its hooks and its own
      # cascade run; a dependent deleted earlier keeps its own timestamp.
      def soft_delete_cascade_dependents!(at)
        soft_delete_each_dependent(deleted: false) { |dependent| dependent.soft_delete!(at: at) }
      end

      # Restore only the dependents that carry the parent's timestamp — the
      # ones this cascade deleted — and let them restore their own dependents.
      def restore_cascaded_dependents!(stamp)
        soft_delete_each_dependent(deleted: stamp, &:restore!)
      end

      # Yields the records of every cascade association matching `deleted:`
      # (false → not deleted, a timestamp → deleted at exactly that time).
      # The association's default scope is peeled off so deleted rows are
      # reachable; has_one is handled through the same relation.
      def soft_delete_each_dependent(deleted:, &block)
        self.class.soft_delete_cascade.each do |name|
          reflection = self.class.reflect_on_association(name)
          self.class.send(:soft_delete_check_cascade_target!, name, reflection)
          field = reflection.klass.soft_delete_field
          relation = association(name).scope.unscope(where: field)
          relation = deleted ? relation.where(field => deleted) : relation.where(field => nil)
          relation.find_each(&block)
        end
      end
    end
  end
end

# Usage Example:
# class MyModel < ApplicationRecord
#   include ConcernsOnRails::Models::SoftDeletable
#   soft_deletable_by :deleted_at
# end
