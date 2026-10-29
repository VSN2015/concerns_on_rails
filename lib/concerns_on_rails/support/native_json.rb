module ConcernsOnRails
  module Support
    # Does a column's ATTRIBUTE type encode a Hash/Array itself? The one answer
    # behind Storable's and Auditable's decision to hand the column the value
    # (native) rather than a generated JSON String — assigning the String to a
    # native type stores a JSON string scalar wrapping the encoded document.
    # Native means:
    #   - a host-app `serialize`d column (ActiveRecord::Type::Serialized);
    #   - an ActiveRecord::Type::Json (a SQLite/MySQL `t.json`, an
    #     `attribute :x, :json` override over a text column) or any type that
    #     reports `:json` / `:jsonb` (PostgreSQL's OID::Jsonb is not a Type::Json
    #     subclass but its `type` is `:jsonb`);
    #   - a column whose own type is `:json` / `:jsonb`.
    # A schema that cannot be read answers false, so a model stays loadable.
    module NativeJson
      module_function

      JSON_TYPES = %i[json jsonb].freeze

      def column?(klass, column)
        name = column.to_s
        type = klass.type_for_attribute(name)
        native_type?(type) || JSON_TYPES.include?(klass.columns_hash[name]&.type)
      rescue StandardError
        false
      end

      def native_type?(type)
        return true if defined?(ActiveRecord::Type::Serialized) && type.is_a?(ActiveRecord::Type::Serialized)
        return true if defined?(ActiveRecord::Type::Json) && type.is_a?(ActiveRecord::Type::Json)

        JSON_TYPES.include?(type.type)
      end
    end
  end
end
