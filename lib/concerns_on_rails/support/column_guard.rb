require "active_support/core_ext/string/inflections"

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
      # `types:` teaches the error message: a Symbol/String applies to every
      # listed field, a Hash maps field => type. When present, the raised
      # ArgumentError appends a ready-to-paste migration command. Generator
      # column-modifier syntax is welcome ("string:uniq" — tokens/slugs want a
      # unique index anyway).
      def ensure_columns!(concern, *fields, types: nil)
        ensure_columns_on!(concern, self, *fields, types: types)
      end

      # Same contract, validated against another class (e.g. CounterCacheable
      # checks the counter column on the *parent* model).
      def ensure_columns_on!(concern, klass, *fields, types: nil)
        return false unless schema_reachable?(klass)

        fields.flatten.compact.each do |field|
          next if klass.column_names.include?(field.to_s)

          raise ArgumentError,
                "#{concern}: '#{field}' does not exist in the database (table: #{klass.table_name})." \
                "#{column_migration_hint(klass, field, types)}"
        end
        true
      end

      # " Add it with: bin/rails generate migration AddDeletedAtToArticles
      # deleted_at:datetime" — every missing-column failure becomes a
      # copy-paste fix. Without a known type the column name goes out bare
      # (the generator defaults to string).
      def column_migration_hint(klass, field, types)
        type = types.is_a?(Hash) ? types[field.to_sym] : types
        column = [field, type].compact.join(":")
        " Add it with: bin/rails generate migration " \
          "Add#{field.to_s.camelize}To#{klass.table_name.to_s.camelize} #{column}"
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
