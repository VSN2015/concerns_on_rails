module ConcernsOnRails
  module Support
    # The one write path shared by every concern verb that wraps a column
    # write in before_/after_ lifecycle hooks (Publishable, SoftDeletable,
    # Expirable, Activatable, Anonymizable, Stateable).
    #
    # The contract, in full:
    #
    # * The hooks and the write run in their OWN savepoint
    #   (`transaction(requires_new: true)`). A bare `transaction` JOINS an
    #   enclosing one — BatchOps.run's, or the caller's — and Rails then
    #   swallows an ActiveRecord::Rollback raised by a hook without rolling
    #   anything back, so a vetoed change committed anyway.
    # * The result is true only once the after-hook has RETURNED. Taking it
    #   from `update` (which runs before the after-hook) reported a fake
    #   success for a write the hook had just rolled back, and BatchOps
    #   counted the row instead of aborting the batch.
    # * A write that returns falsey (a validation failure from `update`)
    #   rolls the savepoint back too, so a before-hook's own side effects
    #   never commit for a write that did not happen. The after-hook is
    #   skipped and the result is false.
    # * On any abort — false write, Rollback, or an exception — EVERY
    #   attribute is put back to its pre-write in-memory state, dirty
    #   tracking included. A database rollback never undoes the attribute
    #   cache (update_column(s) syncs it immediately; `update` leaves the new
    #   values assigned and marks them saved), and the concerns' idempotency
    #   guards (`return true if deleted?`) would otherwise turn every retry
    #   into a silent no-op. Restoring only the verb's own column was not
    #   enough: whatever else the write changed in memory — the entry
    #   Auditable's before_save appended to the trail, a before-hook's
    #   assignment — stayed behind, clean or dirty, and the next unrelated
    #   save persisted it (a phantom "draft -> published" audit entry for a
    #   vetoed transition). An attribute that was already dirty before the
    #   call is restored as dirty against its database value, so unsaved
    #   edits are not lost.
    #
    # The block performs the write and returns truthy on success. Hooks are
    # method names sent to the record (so private overrides work); either may
    # be nil to skip it. Returns true or false; exceptions propagate.
    module HookedWrite
      module_function

      def run(record, before: nil, after: nil)
        snapshot = attribute_snapshot(record)
        identity = identity_snapshot(record)
        completed = false
        begin
          record.transaction(requires_new: true) do
            record.send(before) if before
            raise ActiveRecord::Rollback unless yield

            record.send(after) if after
            completed = true
          end
        ensure
          unless completed
            restore_attributes!(record, snapshot)
            restore_identity!(record, identity)
          end
        end
        completed
      end

      # Rails 6.0: rolling the savepoint back runs `rolledback!`, which
      # restores the record's transaction state from when it FIRST joined the
      # enclosing transaction. For a record CREATED earlier in the caller's
      # transaction that is "new, no id", so the next save INSERTed a
      # duplicate row. A record persisted before the write is persisted after
      # an aborted one, so its identity is put back. (A no-op on 6.1+, which
      # leaves it alone.)
      def identity_snapshot(record)
        return nil unless record.persisted?

        { id: record.id,
          previously_new_record: record.instance_variable_get(:@previously_new_record) }
      end

      def restore_identity!(record, identity)
        return if identity.nil? || record.frozen?

        record.instance_variable_set(:@new_record, false)
        record.instance_variable_set(:@destroyed, false)
        if record.instance_variable_defined?(:@previously_new_record)
          record.instance_variable_set(:@previously_new_record, identity[:previously_new_record])
        end
        return if record.id == identity[:id]

        record.id = identity[:id]
        record.send(:clear_attribute_changes, Array(record.class.primary_key).map(&:to_s))
      end

      # The record's whole attribute set, copied before anything is written —
      # at the AttributeSet level, the way Rails' own transaction rollback
      # state keeps it, and never by READING the attributes: reading runs the
      # type's deserializer, which for an Encryptable field DECRYPTS (an
      # erasure must never load old PII just to take a snapshot, and
      # ciphertext that no longer decrypts would raise DecryptionError). A
      # deep_dup copies each Attribute object, so an unread value stays
      # unread, and the ORIGINAL value each one is dirty against is carried
      # along with it. The last save's mutations are kept too: `update`
      # inside the aborted write would otherwise leave saved_changes
      # reporting a save that was rolled back.
      def attribute_snapshot(record)
        { attributes: record.instance_variable_get(:@attributes).deep_dup,
          before_last_save: record.instance_variable_get(:@mutations_before_last_save) }
      end

      # Swap the copy back in. The dirty tracker is built over the attribute
      # set it was created for, so it is dropped and rebuilt lazily against
      # the restored one.
      #
      # Rails 6.0 applies a rolled-back savepoint's record state LAZILY — on
      # the record's next persisted?/attribute access, via
      # sync_with_transaction_state — and that would overwrite everything put
      # back here (identity included). It is settled first. (Gone on 6.1+.)
      def restore_attributes!(record, snapshot)
        return if record.frozen?

        record.send(:sync_with_transaction_state) if record.respond_to?(:sync_with_transaction_state, true)
        record.instance_variable_set(:@attributes, snapshot[:attributes])
        record.instance_variable_set(:@mutations_from_database, nil)
        record.instance_variable_set(:@mutations_before_last_save, snapshot[:before_last_save])
      end
      private_class_method :attribute_snapshot, :restore_attributes!, :identity_snapshot, :restore_identity!
    end
  end
end
