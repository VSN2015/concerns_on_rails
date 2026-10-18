module ConcernsOnRails
  module Support
    # The machinery behind SoftDeletable's "contextual soft delete": an
    # APP-initiated `destroy_all` on a relation or an association soft-deletes,
    # while ActiveRecord's OWN association maintenance keeps ActiveRecord's
    # semantics (a hard delete). Two places in ActiveRecord issue a
    # relation-level `destroy_all` or a per-record destroy that the concern
    # must tell apart from the app's:
    #
    # * `HasManyThroughAssociation#delete_records(records, :destroy)` removes
    #   the join rows with `through_association.scope.destroy_all` — the
    #   owner's `has_many :through, dependent: :destroy` and every link removal
    #   (`user.groups.destroy(group)`, `user.groups.destroy_all`). Soft-deleting
    #   those left the join rows in place (an InvalidForeignKey when the owner
    #   row goes, or orphans). ThroughMaintenance wraps it in a fiber-local
    #   "hard" context for the join model, which SoftDeletable's relation
    #   override honours by calling ActiveRecord's own destroy_all.
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

      module_function

      # Runs the block with `klass`'s relation-level destroy_all forced hard.
      # A stack, restored in `ensure`, so nested maintenance calls and a raise
      # inside super never leak the context. Fiber-local (Thread#[]).
      def hard(klass)
        stack = (Thread.current[HARD_KEY] ||= [])
        stack.push(klass)
        yield
      ensure
        stack&.pop
      end

      def hard?(klass)
        stack = Thread.current[HARD_KEY]
        !stack.nil? && stack.any? { |hard_klass| klass <= hard_klass }
      end

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
      # ActiveRecord's own remove path (see the header). Rules, per record: a
      # live record is soft-deleted (hooks, cascade); one that is already
      # soft-deleted is destroyed for real. A record that cannot be soft-deleted
      # raises ActiveRecord::RecordNotSaved and rolls the batch back; a hard
      # destroy that is vetoed raises RecordNotDestroyed, as ActiveRecord's own
      # association destroy_all does (`destroy!`).
      module SoftDestroy
        # Public on the association: the collection proxy's override calls it.
        # Acts on the loaded target (as ActiveRecord's destroy_all does), so
        # the proxy's instances are the ones marked deleted.
        def concerns_on_rails_soft_destroy_all
          records = load_target.dup
          delete_or_destroy(records, SOFT_DESTROY)
          reset
          loaded!
          records
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
          return record.destroy! if record.deleted?
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
