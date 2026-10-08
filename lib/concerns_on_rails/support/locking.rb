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
    # `with_locked_column` picks between the two for a concern verb's
    # read-modify-write: the reload whenever it is possible, the column-only
    # read only when unsaved changes rule the reload out.
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
      # `by: -1` takes a mirrored bump back (the UPDATE was rolled back).
      def mirror_bump!(record, klass = record.class, by: 1)
        return false unless klass.locking_enabled?

        column = klass.locking_column
        return false unless record.has_attribute?(column)

        record[column] += by
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

      # The row lock behind a concern verb that reads `column` and then
      # writes it (Stateable `lock: true`, Activatable#toggle_active!). Yields
      # inside the lock's transaction and returns the block's value.
      #
      # * No unsaved changes (or not persisted): with_lock, as these verbs
      #   always did — the record is RELOADED under the lock, so every
      #   attribute, lock_version included, is the committed row's. Hooks and
      #   validations see no stale value, a full-row save (partial updates
      #   off) writes none back, and a copy that is merely out of date still
      #   saves under optimistic locking.
      # * Unsaved changes: the reload is impossible (Rails refuses it, and it
      #   would discard them), so only `column` is read — with_row_lock — and
      #   taken into memory; the block's write then saves the pending changes
      #   with it. Nothing else is refreshed. Under optimistic locking such a
      #   record raises StaleObjectError when the row has moved on since it
      #   was loaded: its changes were made against a stale copy. A row that
      #   has gone raises RecordNotFound, as the reload does.
      #
      # The reload also empties the association cache. A loaded belongs_to
      # parent whose foreign key the reload left unchanged is put back, so it
      # is still the caller's instance: CounterCacheable mirrors its counter
      # UPDATE (and the lock_version bump) onto the parent the record holds,
      # and without this the caller's parent went stale and raised
      # StaleObjectError on its next save.
      def with_locked_column(record, column, &block)
        unless record.persisted? && record.has_changes_to_save?
          parents = loaded_parents(record)
          return record.with_lock do
            restore_parents!(record, parents)
            block.call
          end
        end

        with_row_lock(record, column) do |row|
          klass = record.class
          unless row
            raise ActiveRecord::RecordNotFound.new(
              "Couldn't find #{klass.name} with '#{klass.primary_key}'=#{record.id}", klass.name, klass.primary_key, record.id
            )
          end

          adopt!(record, column, row[column.to_s])
          yield
        end
      end

      # [reflection, target, key] for each loaded, persisted belongs_to
      # target — the key being the foreign key (and a polymorphic type) the
      # record held for it.
      def loaded_parents(record)
        record.class.reflect_on_all_associations(:belongs_to).filter_map do |reflection|
          next unless record.association_cached?(reflection.name)

          association = record.association(reflection.name)
          target = association.target
          next unless association.loaded? && target.is_a?(ActiveRecord::Base) && target.persisted?

          [reflection, target, parent_key(record, reflection)]
        end
      end

      # After the reload: each target whose key the row still holds goes back
      # into the (emptied) cache. One whose key moved is left to load afresh.
      def restore_parents!(record, parents)
        parents.each do |reflection, target, key|
          record.association(reflection.name).target = target if parent_key(record, reflection) == key
        end
      end

      def parent_key(record, reflection)
        columns = Array(reflection.foreign_key)
        columns += [reflection.foreign_type] if reflection.polymorphic?
        columns.map { |name| record[name] }
      end

      # Take the row's `value` for `column` into memory, clean — as a reload
      # leaves it — so a guard reads it and a write back to the in-memory
      # value the row no longer has still reaches the row.
      def adopt!(record, column, value)
        name = column.to_s
        return if record[name] == value && !record.will_save_change_to_attribute?(name)

        record[name] = value
        record.send(:clear_attribute_change, name)
      end
    end
  end
end
