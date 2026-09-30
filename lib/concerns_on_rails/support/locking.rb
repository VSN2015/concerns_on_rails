module ConcernsOnRails
  module Support
    # Keeping a record instance honest with its row around the concerns' raw
    # SQL — the writes that bypass `save` (update_all, Relation#update_counters)
    # and the reads that must see the row, not the instance's copy of it.
    #
    # Optimistic locking (`lock_version`). `update_all` with a Hash — and so
    # Relation#update_counters and the class-level update_counters — adds
    # `lock_version = COALESCE(lock_version, 0) + 1` to the UPDATE on every
    # Rails line the gem supports (6.0–8.1), but touches no instance. The
    # instance the concern holds is then one version behind its own row, and
    # the next ordinary save raises StaleObjectError. Rails' own answer, in
    # Locking::Optimistic#increment! (identical 6.0–8.1), is to mirror the
    # bump in memory — `self[locking_column] += 1` with the change cleared —
    # which `mirror_bump!` copies. The in-memory value is INCREMENTED, never
    # replaced by the row's: an instance that was already stale for another
    # reason (someone else saved the row) must stay stale, or a save would
    # write over that change.
    #
    # Pessimistic reads. `lock!` / `with_lock` take the row lock by RELOADING
    # the instance, which refuses a record with unsaved changes ("Locking a
    # record with unpersisted changes is not supported") and would discard
    # them if it didn't. `with_row_lock` reads just the columns it needs with
    # SELECT ... FOR UPDATE and leaves the instance alone. (SQLite ignores FOR
    # UPDATE — its writers are serialized by the database lock instead — but
    # the value read is still the row's, not the instance's.)
    #
    # The optimistic helpers do nothing on a model without a locking column,
    # so such a model's SQL and in-memory state are exactly what they were.
    module Locking
      module_function

      # After a raw UPDATE of `record`'s row issued through `klass` (the
      # relation's model — its locking_enabled? is what decided whether the
      # UPDATE bumped the column), mirror the bump as increment! does. Skipped
      # when the column was not selected into the instance. true when it
      # mirrored.
      def mirror_bump!(record, klass = record.class)
        return false unless klass.locking_enabled?

        column = klass.locking_column
        return false unless record.has_attribute?(column)

        record[column] += 1
        record.send(:clear_attribute_change, column)
        true
      end

      # { locking_column => the column itself }, merged into an update_all
      # Hash that must NOT bump the version: update_all only adds its own
      # increment when the Hash has no entry for the column, and an Arel
      # attribute is emitted verbatim (`SET lock_version = lock_version`).
      # {} without optimistic locking.
      def pinned(klass)
        return {} unless klass.locking_enabled?

        column = klass.locking_column
        { column => klass.arel_table[column] }
      end

      # Open a transaction (joining the caller's), read `columns` of the
      # record's row with SELECT ... FOR UPDATE — unscoped, as reload is — and
      # yield them as { "column" => value } (cast through the model's
      # attribute types), or nil when the row has gone. The row stays locked
      # until the outermost transaction ends, so a write made in the block is
      # made against the value it read. The block's value is returned.
      def with_row_lock(record, *columns)
        klass = record.class
        primary_key = klass.primary_key
        names = columns.map(&:to_s)
        record.transaction do
          row = klass.unscoped.where(primary_key => record.id).lock.limit(1).pluck(primary_key, *names).first
          yield(row && names.zip(row.drop(1)).to_h)
        end
      end
    end
  end
end
