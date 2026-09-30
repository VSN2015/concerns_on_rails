module ConcernsOnRails
  module Support
    # The hand-off between concerns that GENERATE a column in before_create and
    # the siblings that DERIVE something from it.
    #
    # Rails runs a create's callbacks as before_validation -> before_save ->
    # before_create, whatever order the concerns were included or declared in.
    # Tokenizable's token, Hashable's code and Sequenceable's number are
    # assigned in before_create (on purpose: only a row that is really being
    # inserted draws one), so every sibling that already ran has missed them:
    # Encryptable fingerprinted a nil blind index, friendly_id built no slug,
    # Auditable's creation entry left the column out.
    #
    # A producer wraps its create-time assignment in `GeneratedValues.watch`,
    # which reports the columns the block actually changed, and each consumer
    # the model includes re-derives from the record's current state. The
    # consumers run in a FIXED order, not include order, because they build on
    # each other: the slug first (it may be built from the generated value),
    # then blind indexes (a slug is never encrypted, but the generated value
    # may be), then the audit entry last (it may track the generated column
    # AND the slug).
    #
    # Every hook is idempotent — it re-derives, it never appends — so a report
    # made outside a save (Hashable's public assign_hashable_value) is harmless:
    # the save's own callbacks recompute the same state.
    module GeneratedValues
      # Private instance methods a consumer defines; each receives the Symbol
      # names of the columns just generated.
      CONSUMER_HOOKS = %i[
        sluggable_generated_values_assigned
        encryptable_generated_values_assigned
        auditable_generated_values_assigned
      ].freeze

      module_function

      # Runs the producer's assignment and reports whichever of `columns` it
      # changed (a caller-supplied value is left alone and reports nothing —
      # the earlier callbacks already saw it). Returns the block's result.
      def watch(record, columns)
        columns = Array(columns).compact.map(&:to_sym)
        before = columns.map { |column| record[column] }
        result = yield
        assigned(record, columns.reject.with_index { |column, index| record[column] == before[index] })
        result
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
