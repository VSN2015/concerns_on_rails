module ConcernsOnRails
  module Support
    # Equality lookups on a column that may be `encryptable`. Encryptable's
    # ciphertext carries a random IV, so `where(field => value)` serializes the
    # value into a FRESH envelope that matches no stored row — a query on the
    # column itself silently finds nothing. Such a field is findable only
    # through its blind index.
    #
    # Used by the concerns that look a generated value up by equality —
    # Tokenizable (authenticate_by_/consume_ and its uniqueness precheck) and
    # Hashable (its `unique:` precheck) — so they work whichever order the
    # model declares `encryptable` in.
    module EncryptedLookup
      module_function

      # The field's Encryptable rule, or nil when it is not encrypted.
      def rule(klass, field)
        return nil unless klass.respond_to?(:encryptable_rules)

        klass.encryptable_rules[field.to_sym]
      end

      # True when `field` is encrypted and has no blind index: no query can
      # find a row by its value.
      def unqueryable?(klass, field)
        found = rule(klass, field)
        !found.nil? && found[:blind_index].nil?
      end

      # The where-hash matching rows whose `field` equals `value`: the column
      # itself for a plain field, the blind-index column (every digest the
      # current and previous keys produce) for an indexed encrypted one, and
      # nil for an encrypted field without an index.
      def condition(klass, field, value)
        found = rule(klass, field)
        return { field.to_sym => value } if found.nil?

        index = found[:blind_index]
        return nil if index.nil?

        encryptable = ConcernsOnRails::Models::Encryptable
        { index[:column] => encryptable.blind_index_predicate(encryptable.blind_fingerprints(found, value)) }
      end

      # The blind-index column to clear alongside `field` when a write skips
      # callbacks (update_all), so no stale digest keeps matching; nil when
      # there is none.
      def index_column(klass, field)
        rule(klass, field)&.dig(:blind_index, :column)
      end
    end
  end
end
