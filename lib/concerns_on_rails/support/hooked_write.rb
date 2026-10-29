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
    # * On any abort — false write, Rollback, or an exception — the record's
    #   identity (new/destroyed/previously-new flags and the id, a NEW
    #   record's included) and EVERY attribute are put back to the pre-write
    #   in-memory state, dirty tracking included. A database rollback never undoes the attribute
    #   cache (update_column(s) syncs it immediately; `update` leaves the new
    #   values assigned and marks them saved), and the concerns' idempotency
    #   guards (`return true if deleted?`) would otherwise turn every retry
    #   into a silent no-op. Restoring only the verb's own column was not
    #   enough: whatever else the write changed in memory — the entry
    #   Auditable appended to the trail, a before-hook's
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

      # The record's identity flags, snapshotted for a NEW record as well as a
      # stored one. Rolling the savepoint back does not reliably put them
      # back: Rails restores a record's transaction state (`@new_record`,
      # `@destroyed`, `@previously_new_record`, the primary key) only on a
      # full rollback or when the record's transaction join level is <= 1.
      # `update` runs `with_transaction_returning_status` inside the verb's own
      # transaction, so the record has joined twice (level 2) and a savepoint
      # rollback leaves the flags alone. On 6.0 the state is applied lazily,
      # from the record's FIRST join of the enclosing transaction. So:
      #
      # * a record CREATED by the aborted write, inside a caller's
      #   transaction, stayed `persisted?` with the id gone (the attribute set
      #   is put back): the next `save` ran `UPDATE … WHERE id IS NULL`,
      #   reported success and wrote no row (a StaleObjectError under
      #   lock_version);
      # * on 6.0 a record created EARLIER in the caller's transaction came
      #   back "new, no id", and the next save INSERTed a duplicate row.
      #
      # Whatever the flags were before the write is what they are after an
      # aborted one. (A no-op wherever Rails already leaves them alone.)
      def identity_snapshot(record)
        { id: record.id,
          new_record: record.instance_variable_get(:@new_record),
          destroyed: record.instance_variable_get(:@destroyed),
          previously_new_record: record.instance_variable_get(:@previously_new_record) }
      end

      def restore_identity!(record, identity)
        return if record.frozen?

        record.instance_variable_set(:@new_record, identity[:new_record])
        record.instance_variable_set(:@destroyed, identity[:destroyed])
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
      #
      # deep_dup copies an already-read value only ONE level deep (`dup`), so
      # a json Hash read before the write shared its nested Hashes with the
      # snapshot, and a vetoed hook's `settings["a"]["b"] = ...` survived the
      # restore (then persisted on the next save as an in-place change).
      # Values of a mutable type that were ALREADY read are deep-copied into
      # the snapshot; an unread one is never touched, so nothing is
      # deserialized (or decrypted) to take it.
      #
      # Forced changes (`title_will_change!`) live in the dirty tracker, not
      # the attribute set — a Set of names on Rails 6.0, a name => original
      # value Hash later — so they are copied from it and replayed onto the
      # rebuilt tracker.
      def attribute_snapshot(record)
        tracker = record.instance_variable_get(:@mutations_from_database)
        { attributes: detach_read_values(record.instance_variable_get(:@attributes).deep_dup),
          before_last_save: record.instance_variable_get(:@mutations_before_last_save),
          forced_changes: tracker&.instance_variable_get(:@forced_changes).dup }
      end

      # Rails 7.1+ SHARES (does not dup) the Attribute of a type reporting
      # `mutable? == false`, so only a mutable type's copy may be written to.
      # Rails 6.0 has no `mutable?`; its in-place-tracked types (json,
      # serialized, arrays) include Type::Helpers::Mutable.
      def detach_read_values(attributes)
        attributes.each_value do |attribute|
          next unless attribute.has_been_read? && mutable_type?(attribute.type)

          attribute.instance_variable_set(:@value, attribute.value.deep_dup)
        end
        attributes
      end

      def mutable_type?(type)
        return type.mutable? if type.respond_to?(:mutable?)

        type.is_a?(ActiveModel::Type::Helpers::Mutable)
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
        forced = snapshot[:forced_changes]
        record.send(:mutations_from_database).instance_variable_set(:@forced_changes, forced) if forced.present?
      end
      private_class_method :attribute_snapshot, :detach_read_values, :mutable_type?, :restore_attributes!,
                           :identity_snapshot, :restore_identity!
    end
  end
end
