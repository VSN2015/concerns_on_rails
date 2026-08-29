module ConcernsOnRails
  module Support
    # Shared machinery for the concerns' `*_all` batch verbs.
    #
    # Every batch verb follows the contract established by SoftDeletable in
    # 1.22: it operates on the current relation, returns an Integer count,
    # runs in a transaction, rolls the whole batch back when a record fails,
    # filters already-transitioned rows DB-side, and collapses to a single
    # UPDATE when that cannot differ from looping the per-record path.
    module BatchOps
      # Columns Rails itself bumps when a record is updated with timestamps on.
      TOUCH_COLUMNS = %w[updated_at updated_on].freeze

      module_function

      # True when every named instance method is still the concern's own — the
      # host model overrode none of them. This is the ownership half of the
      # fast-path decision on its own, for the two concerns whose per-record
      # path already skips validations (SoftDeletable under `touch: false` and
      # Lockable, both of which write via update_column(s)) and so are exempt
      # from the validations half.
      def unoverridden?(klass, owner, *methods)
        methods.all? { |name| klass.instance_method(name).owner == owner }
      end

      # The whole safety decision for a single-UPDATE fast path: it is only
      # taken when per-record behavior cannot differ from `update_all` —
      # the host model overrode none of the concern's hooks or bang methods,
      # AND it declares no validations (update_all skips validations
      # entirely, so an unguarded fast path would silently write invalid
      # records instead of honoring the batch contract: RecordNotSaved +
      # rollback on a record that can't save).
      #
      # Save callbacks are deliberately NOT gated on: update_all skipping
      # callbacks is documented Rails behavior shared by every *_all method.
      def fast_path?(klass, owner, *methods)
        !validations?(klass) && unoverridden?(klass, owner, *methods)
      end

      # True when the host model declares anything that runs at validation time.
      #
      # `validators` alone is not enough: it is populated only by `validates` /
      # `validates_with`. A custom `validate :some_check` (or `validate do … end`)
      # registers only a `_validate_callbacks` entry and leaves `validators`
      # EMPTY — so gating on `validators.empty?` took the fast path on one of
      # the most common declaration forms and wrote invalid rows. Callbacks
      # can't merely be counted either: Rails registers validate callbacks of
      # its own on ActiveRecord::Base, so the class's filters are compared
      # against the base class's.
      def validations?(klass)
        klass.validators.any? ||
          (klass._validate_callbacks.map(&:filter) - base_validate_filters).any?
      end

      # `update_all` never touches updated_at, but the per-record `update` the
      # slow path uses does — so the fast path writes the timestamp itself and
      # the two paths agree, the same thing Rails' own `touch_all` and
      # `update_counters(touch:)` do. Otherwise a batch verb would bump
      # updated_at or not depending on whether the model happens to declare a
      # validator, silently staling cache keys and `updated_since` sync jobs.
      def with_timestamps(klass, attributes)
        return attributes unless klass.record_timestamps

        now = Time.zone.now
        (TOUCH_COLUMNS & klass.column_names).each_with_object(attributes.dup) do |column, attrs|
          attrs[column] = now
        end
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

      # The validate callbacks every ActiveRecord model carries out of the box
      # (Rails 7.1 registers :cant_modify_encrypted_attributes_when_frozen on
      # ActiveRecord::Base), subtracted so a bare model doesn't read as "has
      # validations". Resolved on first use rather than at load time: no file
      # in lib/ requires active_record, and referencing ActiveRecord::Base
      # while this file loads would force it.
      def base_validate_filters
        @base_validate_filters ||= ActiveRecord::Base._validate_callbacks.map(&:filter).freeze
      end
    end
  end
end
