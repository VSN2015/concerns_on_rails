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
    # record — so a sibling that derives from them in an earlier callback has
    # missed them: friendly_id built no slug.
    #
    # A producer reports from its before_create path only — never from a
    # public method a host may call outside a save (Hashable reports from a
    # callback of its own, next to assign_hashable_value). It wraps the write
    # in `GeneratedValues.watch`, which reports the columns the block actually
    # changed, or calls `assigned` directly; each consumer the model includes
    # re-derives from the record's current state.
    #
    # The siblings derive in a FIXED order, not include order, because they
    # build on each other: the slug first, here (it may be built from the
    # generated value); then, at the write boundary after every before_*
    # callback (Support::WriteBoundary), blind indexes (a slug is never
    # encrypted, but the generated value may be) and the audit entry last (it
    # may track the generated column AND the slug). Those two need no hook
    # here: the boundary comes after every producer.
    #
    # Every hook is idempotent — it re-derives, it never appends — so two
    # producers reporting in one create (a token and a number) are safe. The
    # hooks are NOT free outside a save (friendly_id's slug-availability
    # query), hence the rule above.
    module GeneratedValues
      # Private instance methods a consumer defines; each receives the Symbol
      # names of the columns just generated.
      CONSUMER_HOOKS = %i[
        sluggable_generated_values_assigned
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
