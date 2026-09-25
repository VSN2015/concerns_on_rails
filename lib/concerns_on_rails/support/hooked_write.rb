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
    # * On any abort — false write, Rollback, or an exception — the
    #   `restore:` attributes are put back to their pre-write in-memory
    #   values. A database rollback never undoes the attribute cache
    #   (update_column(s) syncs it immediately; `update` leaves the new value
    #   assigned), and the concerns' idempotency guards (`return true if
    #   deleted?`) would otherwise turn every retry into a silent no-op.
    #   An attribute that was already dirty before the call is restored as
    #   dirty against its database value, so unsaved edits are not lost.
    #
    # The block performs the write and returns truthy on success. Hooks are
    # method names sent to the record (so private overrides work); either may
    # be nil to skip it. Returns true or false; exceptions propagate.
    module HookedWrite
      module_function

      def run(record, before: nil, after: nil, restore: [])
        snapshot = snapshot(record, restore)
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
            restore!(record, snapshot)
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

      # [name, value, dirty?, database value] per attribute, taken before
      # anything is written. Reading an attribute runs its type's
      # deserializer — for an Encryptable field that DECRYPTS, which an
      # erasure must never do just to take a snapshot (and which raises
      # DecryptionError for ciphertext that no longer decrypts). So an
      # attribute still exactly as loaded (from the database, never read,
      # never assigned) is snapshotted RAW without deserializing:
      # [name, :raw, value_before_type_cast]. A value already in memory
      # keeps the typed path; one that still cannot be read falls back to raw.
      def snapshot(record, names)
        names.map do |name|
          name = name.to_s
          next raw_snapshot(record, name) if unread_from_database?(record, name)

          begin
            [name, record[name], record.attribute_changed?(name), record.attribute_in_database(name)]
          rescue StandardError
            raw_snapshot(record, name)
          end
        end
      end

      def raw_snapshot(record, name)
        [name, :raw, record.read_attribute_before_type_cast(name)]
      end

      # True for an attribute loaded from the database and neither read nor
      # assigned since — its value has never been deserialized. Checking this
      # deserializes nothing (Attribute#has_been_read? only tests @value).
      # Matched by class NAME: Attribute::FromDatabase is a private constant
      # on newer Rails and cannot be referenced directly.
      def unread_from_database?(record, name)
        attribute = record.instance_variable_get(:@attributes)&.[](name)
        return false unless attribute.respond_to?(:has_been_read?)

        attribute.class.name.to_s.end_with?("::FromDatabase") && !attribute.has_been_read?
      end

      def restore!(record, snapshot)
        return if record.frozen?

        snapshot.each do |name, value, dirty, in_database|
          next restore_raw!(record, name, dirty) if value == :raw

          record[name] = dirty ? in_database : value
          record.send(:clear_attribute_changes, [name])
          record[name] = value if dirty
        end
      end

      # Put a raw snapshot back as a LAZY from-database value: nothing is
      # decrypted, and the attribute ends exactly as it was loaded. A fresh
      # from-database attribute is already clean, so changes are only
      # cleared when something still reports one — on Rails 6.0
      # clear_attribute_changes re-reads (and so decrypts) the value.
      def restore_raw!(record, name, raw)
        record.instance_variable_get(:@attributes).write_from_database(name, raw)
        record.send(:clear_attribute_changes, [name]) if record.attribute_changed?(name)
      end
      private_class_method :snapshot, :restore!, :restore_raw!, :raw_snapshot, :unread_from_database?,
                           :identity_snapshot, :restore_identity!
    end
  end
end
