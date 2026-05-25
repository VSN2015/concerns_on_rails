require "active_support/concern"

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
    # The phrase "does not exist" is preserved so existing specs that match
    # /does not exist/ keep passing.
    module ColumnGuard
      def ensure_columns!(concern, *fields)
        fields.flatten.compact.each do |field|
          next if column_names.include?(field.to_s)

          raise ArgumentError,
                "#{concern}: '#{field}' does not exist in the database (table: #{table_name})"
        end
      end
    end
  end
end
