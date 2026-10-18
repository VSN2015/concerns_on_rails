module ConcernsOnRails
  module Support
    # The hand-off between concerns that GENERATE a column in before_create and
    # the siblings that DERIVE something from it.
    #
    # Rails runs a create's callbacks as before_validation -> before_save ->
    # before_create, whatever order the concerns were included or declared in.
    # Tokenizable's token, Hashable's code and Sequenceable's number are
    # assigned in before_create (on purpose: only a row that is really being
    # inserted draws one), and so is the position acts_as_list gives a Sortable
    # record — so every sibling that already ran has missed them:
    # Encryptable fingerprinted a nil blind index, friendly_id built no slug,
    # Auditable's creation entry left the column out.
    #
    # A producer reports from its before_create path only — never from a
    # public method a host may call outside a save (Hashable reports from a
    # callback of its own, next to assign_hashable_value). It wraps the write
    # in `GeneratedValues.watch`, which reports the columns the block actually
    # changed, or calls `assigned` directly; each consumer the model includes
    # re-derives from the record's current state. The
    # consumers run in a FIXED order, not include order, because they build on
    # each other: the slug first (it may be built from the generated value),
    # then blind indexes (a slug is never encrypted, but the generated value
    # may be), then the audit entry last (it may track the generated column
    # AND the slug).
    #
    # A failed INSERT must not leave the generated values behind. Rails keeps
    # the record's CURRENT attribute values when a create rolls back
    # (restore_transaction_record_state only rewinds new_record?/id), and every
    # producer assigns only into a blank column — so a retried `save!` of the
    # same record would re-INSERT the losing number/token/code instead of
    # drawing a fresh one, and a re-rendered form would show a value that was
    # never stored. `watch` (and Hashable, via `remember`) therefore records
    # each column's pre-create value on the record, and `Revertible` — included
    # by every producer — puts them back when the create rolls back.
    #
    # Every hook is idempotent — it re-derives, it never appends — so two
    # producers reporting in one create (a token and a number) are safe. The
    # hooks are NOT free outside a save (friendly_id's slug-availability
    # query, an audit entry on an unsaved record), hence the rule above.
    module GeneratedValues
      # Private instance methods a consumer defines; each receives the Symbol
      # names of the columns just generated.
      CONSUMER_HOOKS = %i[
        sluggable_generated_values_assigned
        encryptable_generated_values_assigned
        auditable_generated_values_assigned
      ].freeze

      # Included by every producer (Sequenceable, Tokenizable, Hashable,
      # Sortable). Hooks the transaction-record protocol rather than an
      # after_rollback callback, so it also runs for a save that joined a
      # caller's transaction or savepoint (UniqueRetry's `savepoint:`).
      # `rolledback!`'s keywords differ across Rails 6.0-8.1, so every argument
      # is forwarded to super untouched.
      module Revertible
        # Rails 6.0 enrolls a record in the transaction (so `rolledback!` runs
        # at all) only when its class has a transactional callback; 6.1+
        # always does. A no-op after_rollback gives 6.0 the same enrollment.
        def self.included(base)
          super
          base.after_rollback :generated_values_enrolled if ActiveRecord.version < Gem::Version.new("6.1")
        end

        def rolledback!(*, **, &)
          super
        ensure
          generated_values_revert!
        end

        private

        def generated_values_enrolled; end

        # Puts back the columns a create path generated, while the record is a
        # new record again. A column the caller has changed since (no longer
        # the generated value) is left alone; a persisted record keeps what it
        # was INSERTed with. The entry is consumed, so the next attempt
        # records its own.
        def generated_values_revert!
          pending = @_generated_values
          return if pending.nil? || pending.empty?
          return unless new_record?

          @_generated_values = nil
          pending.each do |column, (before, generated)|
            self[column] = before if self[column] == generated
          end
        end
      end

      module_function

      # Runs the producer's assignment and reports whichever of `columns` it
      # changed (a caller-supplied value is left alone and reports nothing —
      # the earlier callbacks already saw it). Returns the block's result.
      def watch(record, columns)
        columns = Array(columns).compact.map(&:to_sym)
        before = columns.to_h { |column| [column, record[column]] }
        result = yield
        changed = columns.reject { |column| record[column] == before[column] }
        remember(record, before.slice(*changed))
        assigned(record, changed)
        result
      end

      # Records the pre-create value of each generated column (column =>
      # value-before) on the record, for Revertible to restore if the create
      # rolls back. The current value is captured as the "generated" one, so
      # a later caller edit is never overwritten. A column drawn twice keeps
      # the earliest value.
      def remember(record, before_values)
        return if before_values.empty?

        pending = record.instance_variable_get(:@_generated_values) || {}
        before_values.each do |column, before|
          earlier = pending[column]
          before = earlier.first if earlier && earlier.last == before
          pending[column] = [before, record[column]]
        end
        record.instance_variable_set(:@_generated_values, pending)
      end

      # Hands `columns` to every consumer hook the record defines, in order.
      def assigned(record, columns)
        columns = Array(columns).map(&:to_sym)
        return if columns.empty?

        CONSUMER_HOOKS.each do |hook|
          record.send(hook, columns) if record.respond_to?(hook, true)
        end
      end
    end
  end
end
