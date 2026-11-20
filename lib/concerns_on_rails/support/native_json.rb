require "json"

module ConcernsOnRails
  module Support
    # Does a column's ATTRIBUTE type encode a Hash/Array itself? The one answer
    # behind Storable's and Auditable's decision to hand the column the value
    # (native) rather than a generated JSON String — assigning the String to a
    # native type stores a JSON string scalar wrapping the encoded document.
    # The attribute type alone decides (never the column's: an explicit
    # `attribute :x, :string` over a jsonb column wants a String):
    #   - a host-app `serialize`d column (ActiveRecord::Type::Serialized);
    #   - an ActiveRecord::Type::Json — a `t.json` column, PostgreSQL's
    #     OID::Jsonb (a subclass of it on Rails 6.0-8.1), an
    #     `attribute :x, :json` override over a text column;
    #   - any other type that reports `:json` / `:jsonb`.
    # A schema that cannot be read answers false, so a model stays loadable.
    module NativeJson
      module_function

      JSON_TYPES = %i[json jsonb].freeze

      # A native json column's cast value, re-read when Rails could not decode it.
      # Type::Json decodes with ActiveSupport::JSON.decode and rescues any
      # ParserError to nil, so on json >= 3 a stored document with a repeated
      # object key reads nil — Storable then wrote the next key over defaults,
      # erasing the rest. When the cast is nil, the attribute is unchanged and
      # the raw database String parses with the last duplicate key winning
      # (json 2.x semantics), that is what is returned; otherwise `value` as is.
      def reread(record, column, value)
        return value unless value.nil? && !record.attribute_changed?(column.to_s)

        raw = record.read_attribute_before_type_cast(column.to_s)
        raw.is_a?(String) ? JSON.parse(raw, allow_duplicate_key: true) : value
      rescue JSON::ParserError
        value
      end

      def column?(klass, column)
        type = klass.type_for_attribute(column.to_s)
        return true if defined?(ActiveRecord::Type::Serialized) && type.is_a?(ActiveRecord::Type::Serialized)
        return true if defined?(ActiveRecord::Type::Json) && type.is_a?(ActiveRecord::Type::Json)

        JSON_TYPES.include?(type.type)
      rescue StandardError
        false
      end
    end
  end
end
