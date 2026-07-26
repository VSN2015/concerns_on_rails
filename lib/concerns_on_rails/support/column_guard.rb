module ConcernsOnRails
  module Support
    # Shared schema-validation helper mixed into a concern's ClassMethods.
    # Runs in class context, so `column_names` / `table_name` resolve against
    # the including model. Centralizes the column-existence check that every
    # model concern used to re-implement, and keeps the error wording uniform.
    #
    #   class_methods do
    #     include ConcernsOnRails::Support::ColumnGuard
    #
    #     def activatable_by(field = :active)
    #       self.activatable_field = field.to_sym
    #       ensure_columns!("ConcernsOnRails::Models::Activatable", activatable_field)
    #     end
    #   end
    #
    # When the schema is unreachable — no database yet (`db:create`, a fresh
    # `db:migrate`, `assets:precompile`, CI bootstrap) or the table not yet
    # migrated — the check is skipped and `false` is returned instead of
    # raising, so model classes stay loadable. A missing column with a
    # *reachable* schema still raises: the rescue is scoped to
    # ActiveRecord::ActiveRecordError precisely so real bugs (NameError from a
    # typo etc.) keep surfacing. Skipping is self-healing: once the migration
    # runs and classes reload, validation happens for real — and a genuinely
    # missing column still fails loudly on first query.
    #
    # The phrase "does not exist" is preserved so existing specs that match
    # /does not exist/ keep passing.
    module ColumnGuard
      def ensure_columns!(concern, *fields)
        ensure_columns_on!(concern, self, *fields)
      end

      # Same contract, validated against another class (e.g. CounterCacheable
      # checks the counter column on the *parent* model).
      def ensure_columns_on!(concern, klass, *fields)
        return false unless schema_reachable?(klass)

        fields.flatten.compact.each do |field|
          next if klass.column_names.include?(field.to_s)

          raise ArgumentError,
                "#{concern}: '#{field}' does not exist in the database (table: #{klass.table_name})"
        end
        true
      end

      # True when the class's table can actually be inspected. Connection
      # errors (ConnectionNotEstablished, NoDatabaseError, adapter errors)
      # all inherit from ActiveRecord::ActiveRecordError.
      def schema_reachable?(klass = self)
        klass.table_exists?
      rescue ActiveRecord::ActiveRecordError
        false
      end
    end
  end
end
