module ConcernsOnRails
  module Support
    # The machinery behind SoftDeletable's "contextual soft delete": an
    # APP-initiated `destroy_all` on a relation or an association soft-deletes,
    # while ActiveRecord's OWN association maintenance keeps ActiveRecord's
    # semantics (a hard delete). Three rules:
    #
    # 1. A live record is soft-deleted (`soft_delete!`: hooks, cascade).
    # 2. A record that is ALREADY soft-deleted is destroyed for real, but ONLY
    #    when the caller reached the trash on purpose: the relation was built by
    #    one of the gem's trash scopes (`only_deleted`, `soft_deleted`,
    #    `deleted_within`, `with_deleted`, affixed or renamed alike), which tag it
    #    with TrashScope (an `extending` marker: it survives chaining, `merge` and
    #    association scopes). Any other relation — including EVERY relation of a
    #    `default_scope: false` model, which already contains the trash — leaves
    #    the trashed rows untouched.
    # 3. Rails' own has_many :through maintenance stays hard (below).
    #
    # The trashed set is decided when the call STARTS (the primary keys, or the
    # loaded records' state), never per row while streaming: a row this very
    # call soft-deletes (a self-referential `cascade:`, an `after_soft_delete`
    # hook) is never purged by a later batch, so `restore!` can always bring it
    # back and the outcome does not depend on the batch size.
    #
    # Two places in ActiveRecord issue a relation-level `destroy_all` or a
    # per-record destroy that the concern must tell apart from the app's:
    #
    # * `HasManyThroughAssociation#delete_records(records, :destroy)` removes
    #   the join rows with `through_association.scope.destroy_all` — the
    #   owner's `has_many :through, dependent: :destroy` and every link removal
    #   (`user.groups.destroy(group)`, `user.groups.destroy_all`). Soft-deleting
    #   those left the join rows in place (an InvalidForeignKey when the owner
    #   row goes, or orphans). ThroughMaintenance wraps it in a fiber-local
    #   "hard" context for the join model, which SoftDeletable's relation
    #   override CONSUMES (one shot: the first relation-level destroy_all on
    #   that model, which is the one Rails issues) by calling ActiveRecord's own
    #   destroy_all — so a destroy callback of the join model that itself calls
    #   `destroy_all` on its class is an app call again and soft-deletes.
    #
    # * `HasManyAssociation#delete_records(records, method)` is where a
    #   non-through association destroys its records. The proxy's soft
    #   `destroy_all` hands ActiveRecord's own `delete_or_destroy` a private
    #   method name (SOFT_DESTROY), which SoftDestroy handles — so everything
    #   ActiveRecord does around the delete (before_remove / after_remove, the
    #   transaction, removing the records from the loaded target, `throw
    #   :abort`) stays ActiveRecord's. Any other method falls through to super,
    #   so `dependent: :destroy` and `post.comments.destroy(c)` are untouched.
    #
    # Both prepends are inert for every model that does not include
    # SoftDeletable (they only act on the join model they were handed, or on
    # SOFT_DESTROY), and are installed lazily by the first SoftDeletable
    # include. The signatures they wrap — `delete_records(records, method)` in
    # both classes and `delete_or_destroy(records, method)` — are identical on
    # ActiveRecord 6.0 through 8.1.
    module ContextualDestroy
      HARD_KEY = :concerns_on_rails_soft_delete_hard_classes
      SOFT_DESTROY = :concerns_on_rails_soft_destroy

      # Tags a relation built by one of the gem's trash scopes. Empty on
      # purpose: only its presence in `extending_values` matters.
      module TrashScope; end

      HardEntry = Struct.new(:klass, :used)
      private_constant :HardEntry

      module_function

      # True when `relation` reached the trash through one of the trash scopes.
      def trash_scope?(relation)
        relation.extending_values.include?(TrashScope)
      end

      # Runs the block with `klass`'s NEXT relation-level destroy_all forced
      # hard. A stack, restored in `ensure`, so nested maintenance calls and a
      # raise inside super never leak the context. Fiber-local (Thread#[]).
      def hard(klass)
        stack = (Thread.current[HARD_KEY] ||= [])
        stack.push(HardEntry.new(klass, false))
        yield
      ensure
        stack&.pop
      end

      # True while a hard context for `klass` is pending (not yet consumed).
      def hard?(klass)
        stack = Thread.current[HARD_KEY]
        !stack.nil? && stack.any? { |entry| !entry.used && klass <= entry.klass }
      end

      # Claims the pending hard context for `klass`, once: true for the one
      # relation-level destroy_all ActiveRecord's maintenance issues, false for
      # every later call (a callback's own destroy_all) until the context is
      # set again.
      def consume_hard(klass)
        stack = Thread.current[HARD_KEY]
        entry = stack&.find { |candidate| !candidate.used && klass <= candidate.klass }
        return false unless entry

        entry.used = true
      end

      # The relation form of destroy_all (SoftDeletable's RelationDestroyAll):
      # purge the rows that were already trashed when the call started (only
      # for a trash-scope relation), soft-delete the live ones, in ONE
      # transaction with soft_delete_all's RecordNotSaved + rollback contract.
      # Returns the records acted on. A vetoed purge is skipped, as
      # Relation#destroy_all skips a vetoed destroy.
      def destroy_relation(relation)
        klass = relation.klass
        purge = trash_scope?(relation)
        acted = []
        klass.transaction(requires_new: true) do
          if records_up_front?(relation)
            destroy_loaded(relation, purge, acted)
          else
            destroy_streaming(relation, purge, acted)
          end
        end
        acted
      end

      # A relation whose rows must be loaded as they are NOW: one already
      # loaded (act on those instances), a DisableJoinsAssociationRelation (its
      # `limit` answers an Array, which find_each cannot page), a LIMIT/OFFSET
      # (the slice is fixed when the call starts) or a composite key.
      def records_up_front?(relation)
        relation.loaded? || relation.limit_value || relation.offset_value ||
          relation.klass.primary_key.is_a?(Array) ||
          (defined?(ActiveRecord::DisableJoinsAssociationRelation) &&
            relation.is_a?(ActiveRecord::DisableJoinsAssociationRelation))
      end

      def destroy_loaded(relation, purge, acted)
        # One instance per record: a joined relation holds a stale copy per row.
        trashed, live = relation.records.uniq(&:id).partition(&:deleted?)
        purge_loaded(trashed, acted) if purge
        live.each do |record|
          raise_not_saved(record) unless record.soft_delete!
          acted << record
        end
      end

      def purge_loaded(trashed, acted)
        trashed.each { |record| acted << record if record.send(:soft_delete_purge!) }
      end

      def raise_not_saved(record)
        raise ActiveRecord::RecordNotSaved.new("#{SOFT_DELETE_LABEL}: failed to soft-delete record", record)
      end

      def destroy_streaming(relation, purge, acted)
        klass = relation.klass
        trashed_keys(relation, klass, purge).each_slice(BatchOps::BATCH_SIZE) do |slice|
          BatchOps.each_record(relation.unscope(:order).where(klass.primary_key => slice)) do |record|
            # A hook may have restored it since the call began: never purge a live row.
            acted << record if record.deleted? && record.send(:soft_delete_purge!)
          end
        end
        BatchOps.run(relation.where(klass.soft_delete_field => nil), label: SOFT_DELETE_LABEL,
                                                                     message: "failed to soft-delete record") do |record|
          record.soft_delete!.tap { |done| acted << record if done }
        end
      end

      # The primary keys of the rows already trashed right now.
      def trashed_keys(relation, klass, purge)
        return [] unless purge

        relation.unscope(:order).where.not(klass.soft_delete_field => nil).pluck(klass.primary_key).uniq
      end

      SOFT_DELETE_LABEL = "ConcernsOnRails::Models::SoftDeletable".freeze
      private_constant :SOFT_DELETE_LABEL
      private_class_method :destroy_loaded, :destroy_streaming, :trashed_keys, :records_up_front?, :raise_not_saved, :purge_loaded

      # ActiveRecord's through-association maintenance keeps ActiveRecord's
      # hard delete of the join rows.
      module ThroughMaintenance
        private

        def delete_records(records, method)
          return super unless method == :destroy

          ContextualDestroy.hard(through_reflection.klass) { super }
        end
      end

      # A non-through association's soft `destroy_all`, run through
      # ActiveRecord's own remove path (see the header). Per record, decided
      # when the call starts: a live record is soft-deleted (hooks, cascade); one
      # that was already soft-deleted is destroyed for real when the association
      # was reached through a trash scope (`has_many :trash, -> { only_deleted }`)
      # and left alone otherwise. A record that cannot be soft-deleted raises
      # ActiveRecord::RecordNotSaved and rolls the batch back; a purge that is
      # vetoed raises RecordNotDestroyed, as ActiveRecord's own association
      # destroy_all does (`destroy!`).
      module SoftDestroy
        # Public on the association: the collection proxy's override calls it.
        # Acts on the loaded target (as ActiveRecord's destroy_all does), so
        # the proxy's instances are the ones marked deleted. Returns what
        # ActiveRecord's does: the records, or nil when a before_remove aborted.
        def concerns_on_rails_soft_destroy_all
          targets = load_target.dup
          purge = ContextualDestroy.trash_scope?(scope)
          targets = targets.reject(&:deleted?) unless purge
          @concerns_on_rails_trashed = targets.select(&:deleted?).to_h { |record| [record, true] }.compare_by_identity
          # Wrapped in an Array, as `destroy(load_target)` does, so an empty
          # target answers [] (delete_or_destroy answers nil for a bare []).
          delete_or_destroy([targets], SOFT_DESTROY).tap do
            reset
            loaded!
          end
        ensure
          @concerns_on_rails_trashed = nil
        end

        private

        def delete_records(records, method)
          return super unless method == SOFT_DESTROY

          reflection.klass.transaction(requires_new: true) { records.each { |record| soft_destroy_record!(record) } }
          # Rails' own bookkeeping for the rows it really removed (a soft
          # delete leaves a counter cache alone, as soft_delete! does).
          hard = records.count(&:destroyed?)
          update_counter(-hard) if hard.positive? && !reflection.inverse_updates_counter_cache?
        end

        def soft_destroy_record!(record)
          if @concerns_on_rails_trashed&.key?(record)
            return true if record.send(:soft_delete_purge!)

            raise ActiveRecord::RecordNotDestroyed.new("Failed to destroy the record", record)
          end
          return true if record.soft_delete!

          raise ActiveRecord::RecordNotSaved.new(
            "ConcernsOnRails::Models::SoftDeletable: failed to soft-delete record", record
          )
        end
      end

      def install!
        through = ActiveRecord::Associations::HasManyThroughAssociation
        through.prepend(ThroughMaintenance) unless through < ThroughMaintenance
        has_many = ActiveRecord::Associations::HasManyAssociation
        has_many.prepend(SoftDestroy) unless has_many < SoftDestroy
      end
    end
  end
end
