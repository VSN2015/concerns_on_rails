module ConcernsOnRails
  module Support
    # Shared machinery for the concerns' `*_all` batch verbs.
    #
    # Every batch verb follows the contract established by SoftDeletable in
    # 1.22: it operates on the current relation, returns an Integer count,
    # runs in a transaction, rolls the whole batch back when a record fails,
    # filters already-transitioned rows DB-side, and collapses to a single
    # UPDATE when the host model has overridden none of the concern's hooks
    # or bang methods.
    module BatchOps
      module_function

      # True when every named instance method is still the concern's own — the
      # host model overrode none of them, so a bulk UPDATE cannot differ from
      # looping the per-record path.
      def fast_path?(klass, owner, *methods)
        methods.all? { |name| klass.instance_method(name).owner == owner }
      end

      # The streaming slow path. `find_each` pages forward by primary key, so
      # rows leaving the filtered set as they're updated are never skipped or
      # revisited, and the relation is never materialized in full.
      #
      # The block returns truthy (counted), `:skip` (not counted, not an
      # error — a record that legitimately can't transition), or falsey
      # (raises and rolls the whole batch back).
      def run(relation, label:, message: "failed to update record")
        relation.klass.transaction do
          count = 0
          relation.find_each do |record|
            result = yield(record)
            next if result == :skip

            raise ActiveRecord::RecordNotSaved.new("#{label}: #{message}", record) unless result

            count += 1
          end
          count
        end
      end
    end
  end
end
