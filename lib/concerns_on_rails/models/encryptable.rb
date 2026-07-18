require "active_support/concern"
require "active_model/type"
require "bigdecimal"
require "time"
require "concerns_on_rails/encryption"
require "concerns_on_rails/support/encryptor"

module ConcernsOnRails
  module Models
    # Transparent per-field encryption for sensitive columns (SSN, DOB, cards).
    # Reads and writes stay plaintext; the DB column holds an authenticated
    # AES-256-GCM envelope. Encryption is implemented as a custom
    # ActiveModel::Type on the declared column, so it is invisible to the rest
    # of the stack — sibling concerns that read `self[:field]` (Maskable,
    # Normalizable) compose for free, and dirty tracking compares plaintext.
    #
    #   ConcernsOnRails.configure_encryption { |c| c.key = ENV["ENCRYPTION_KEY"] }
    #
    #   class Patient < ApplicationRecord
    #     include ConcernsOnRails::Models::Encryptable
    #
    #     encryptable :ssn, :notes              # transparent string encryption
    #     encryptable :dob, type: :date         # decrypts back to a Date
    #     encryptable :email, blind_index: true # + a queryable fingerprint column
    #   end
    #
    #   p = Patient.create!(ssn: "123-45-6789", dob: Date.new(1990, 1, 1))
    #   p.ssn                 # => "123-45-6789"
    #   p.reload.dob          # => Wed, 01 Jan 1990
    #   p.ssn_ciphertext      # => "AQEA..." (Base64 envelope; no plaintext at rest)
    #   p.ssn_encrypted?      # => true
    #   Patient.find_by_email("a@b.com")  # exact-match lookup via the blind index
    #
    # `type:` casts the decrypted value (reuses the Storable caster set:
    # :string default, :integer, :float, :decimal, :boolean, :date, :datetime).
    # `key:` overrides the gem-level key per field (a String or a Proc).
    #
    # BLIND INDEX (`blind_index: true` or a Hash): because encryption is
    # non-deterministic, encrypted columns are not directly queryable. Opt into
    # a blind index and the concern maintains a deterministic keyed HMAC of the
    # value in a companion `<field>_bidx` column (override with `column:`), and
    # generates `find_by_<field>` / `where_<field>` / `<field>_fingerprint`
    # class methods for exact-match lookups. Pass `expression:` (a callable) to
    # normalize before hashing (e.g. `->(v) { v.to_s.downcase }`) — it is applied
    # on BOTH write and query so they stay symmetric. The index leaks equality
    # (identical values share a digest); use it only for lookup keys.
    #
    # Notes:
    #   * The declared column must be `text` (or binary): it stores an opaque
    #     Base64 envelope, not the logical type. `nil` stays `nil` (never an
    #     encrypted blank). A blind-index column is `string`/`text` (a 64-char
    #     hex digest) — add an index on it.
    #   * The ciphertext itself is non-deterministic (random IV) — the same
    #     plaintext yields different ciphertext every write, so `where(:ssn)`
    #     matches nothing. Query through a blind index instead. Presence/NULL
    #     checks (`where.not(ssn: nil)`) work normally.
    #   * Never `update_column`/`update_columns` an encrypted field — those
    #     bypass the type and write raw plaintext to the column (and skip the
    #     blind-index refresh).
    #   * Auditing an encrypted field would persist its plaintext to the audit
    #     column, so declaring a field with BOTH `encryptable` and `auditable_by`
    #     raises. Maskable masks the decrypted value; Normalizable normalizes the
    #     plaintext before it is encrypted (order-independent).
    module Encryptable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Models::Encryptable".freeze
      VALID_TYPES = %i[string integer float decimal boolean date datetime].freeze

      # Reusable ActiveModel casters. :decimal and :datetime round-trip through
      # Strings and are handled explicitly (mirrors Models::Storable).
      CASTERS = {
        string: ActiveModel::Type::String.new,
        integer: ActiveModel::Type::Integer.new,
        float: ActiveModel::Type::Float.new,
        boolean: ActiveModel::Type::Boolean.new,
        date: ActiveModel::Type::Date.new,
        datetime: ActiveModel::Type::DateTime.new
      }.freeze

      included do
        # { field => { type:, key:, blind_index: } }. Subclasses inherit and may
        # add fields.
        class_attribute :encryptable_rules, instance_accessor: false, default: {}
        # Backstop for the reverse declaration order (Auditable added AFTER
        # Encryptable): the macro-time guard can't see a not-yet-declared audit.
        before_save :encryptable_guard_audited_plaintext!
        before_save :encryptable_refresh_blind_indexes
      end

      # Deterministic blind-index fingerprint for a field's value, applying the
      # field's normalization `expression:`. Shared by the generated class
      # finders and the before_save refresh. Returns nil for a nil value.
      def self.blind_fingerprint(rule, value)
        bi = rule[:blind_index]
        return nil unless bi
        return nil if value.nil?

        normalized = bi[:expression] ? bi[:expression].call(value) : value
        return nil if normalized.nil?

        config = ConcernsOnRails.encryption
        material = config.resolve_material(rule[:key])
        return normalized.to_s if material == ConcernsOnRails::Encryption::PASSTHROUGH

        ConcernsOnRails::Support::Encryptor.blind_index(
          normalized, key: material, salt: config.key_derivation_salt
        )
      end

      # Custom type registered on each encrypted column. cast handles user input
      # (plaintext in memory), serialize encrypts on the write-to-DB path, and
      # deserialize decrypts on the read-from-DB path. An immutable value type,
      # so dirty tracking compares the cast plaintext — a re-save of unchanged
      # data is not dirtied by GCM's random IV.
      class EncryptedType < ActiveModel::Type::Value
        def initialize(type: :string, key: nil)
          @type = type
          @key = key
          super()
        end

        # user assignment -> typed plaintext (no crypto)
        def cast(value)
          cast_typed(value)
        end

        # DB ciphertext -> typed plaintext
        def deserialize(value)
          return nil if value.nil?

          plaintext = read_plaintext(value)
          return nil if plaintext.nil?

          cast_typed(plaintext)
        end

        # typed plaintext -> DB ciphertext
        def serialize(value)
          return nil if value.nil?

          plaintext = canonical_string(value)
          return nil if plaintext.nil?

          write_ciphertext(plaintext)
        end

        private

        def cast_typed(value)
          case @type
          when :decimal  then to_big_decimal(value)
          when :datetime then to_time(value)
          else CASTERS[@type].cast(value)
          end
        rescue StandardError
          nil
        end

        # Canonical, reversible String form fed to the cipher: cast to the typed
        # value first, then format that type as a stable String.
        def canonical_string(value)
          typed = cast_typed(value)
          return nil if typed.nil?

          stringify(typed)
        rescue StandardError
          nil
        end

        def stringify(typed)
          case @type
          when :decimal  then typed.to_s("F")
          when :date     then typed.iso8601
          when :datetime then typed.utc.iso8601(6)
          else typed.to_s
          end
        end

        def to_big_decimal(value)
          return nil if value.nil?

          value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
        end

        def to_time(value)
          case value
          when nil then nil
          when ActiveSupport::TimeWithZone, Time then value
          when DateTime then value.to_time
          when Date then Time.utc(value.year, value.month, value.day)
          when String
            begin
              Time.iso8601(value)
            rescue ArgumentError
              CASTERS[:datetime].cast(value)
            end
          else CASTERS[:datetime].cast(value)
          end
        end

        def write_ciphertext(plaintext)
          config = ConcernsOnRails.encryption
          material = config.resolve_material(@key)
          return plaintext if material == ConcernsOnRails::Encryption::PASSTHROUGH

          ConcernsOnRails::Support::Encryptor.encrypt(
            plaintext, key: material, salt: config.key_derivation_salt
          )
        end

        def read_plaintext(stored)
          config = ConcernsOnRails.encryption
          material = config.resolve_material(@key)
          return stored if material == ConcernsOnRails::Encryption::PASSTHROUGH

          ConcernsOnRails::Support::Encryptor.decrypt(
            stored, key: material, salt: config.key_derivation_salt
          )
        rescue ConcernsOnRails::Encryption::DecryptionError
          raise if config.raise_on_decrypt_error

          nil
        end
      end

      module ClassMethods
        include ConcernsOnRails::Support::ColumnGuard

        # Declare one or more encrypted fields. Repeatable; per-field options.
        def encryptable(*fields, type: :string, key: nil, blind_index: nil)
          type = type.to_sym
          encryptable_validate!(fields, type, blind_index)
          ensure_columns!(LABEL, *fields)

          fields.each do |field|
            field = field.to_sym
            encryptable_guard_auditable!(field)
            bi = encryptable_normalize_blind_index(field, blind_index)
            ensure_columns!(LABEL, bi[:column]) if bi
            self.encryptable_rules = encryptable_rules.merge(field => { type: type, key: key, blind_index: bi })
            attribute field, EncryptedType.new(type: type, key: key)
            encryptable_define_helpers(field)
            encryptable_define_blind_index(field, bi) if bi
            encryptable_register_filter_parameter(field)
          end
        end

        private

        def encryptable_validate!(fields, type, blind_index)
          raise ArgumentError, "#{LABEL}: at least one field is required" if fields.empty?
          raise ArgumentError, "#{LABEL}: unknown type ':#{type}' (valid: #{VALID_TYPES.join(', ')})" unless VALID_TYPES.include?(type)
          return unless blind_index.is_a?(Hash) && blind_index[:column] && fields.size > 1

          raise ArgumentError, "#{LABEL}: blind_index column: cannot be combined with multiple fields"
        end

        # nil/false -> no index; true -> defaults; Hash -> { column:, expression: }.
        def encryptable_normalize_blind_index(field, option)
          return nil unless option

          option = {} if option == true
          raise ArgumentError, "#{LABEL}: blind_index: must be true or a Hash" unless option.is_a?(Hash)

          expression = option[:expression]
          raise ArgumentError, "#{LABEL}: blind_index expression: must be callable" if expression && !expression.respond_to?(:call)

          { column: (option[:column] || "#{field}_bidx").to_sym, expression: expression }
        end

        def encryptable_define_helpers(field)
          # Raw stored value: the DB ciphertext once persisted (before the type
          # deserializes it). Useful for migrations, debugging, and asserting no
          # plaintext is at rest.
          define_method("#{field}_ciphertext") { read_attribute_before_type_cast(field) }
          define_method("#{field}_encrypted?") { read_attribute_before_type_cast(field).present? }
        end

        # find_by_<field> / where_<field> / <field>_fingerprint for equality
        # lookups through the deterministic blind-index column.
        def encryptable_define_blind_index(field, blind_index)
          column = blind_index[:column]

          define_singleton_method("#{field}_fingerprint") do |value|
            ConcernsOnRails::Models::Encryptable.blind_fingerprint(encryptable_rules.fetch(field), value)
          end
          # Accepts one value, several, or an array — multiple values become an
          # IN query on the fingerprint column. Returns a Relation, so it chains
          # with scopes, `.or`, `.merge` (for joins), and further `.where`.
          define_singleton_method("where_#{field}") do |*values|
            fingerprints = values.flatten.map { |v| public_send("#{field}_fingerprint", v) }
            where(column => fingerprints.length == 1 ? fingerprints.first : fingerprints)
          end
          define_singleton_method("find_by_#{field}") do |value|
            find_by(column => public_send("#{field}_fingerprint", value))
          end
        end

        # Macro-time guard for the common order (Encryptable declared after
        # Auditable): a field must not be both encrypted and audited.
        def encryptable_guard_auditable!(field)
          return unless respond_to?(:auditable_fields)
          return unless Array(auditable_fields).map(&:to_sym).include?(field.to_sym)

          raise ArgumentError,
                "#{LABEL}: ':#{field}' is also declared with Auditable; auditing would persist the " \
                "decrypted plaintext to the audit column. Remove it from auditable_by."
        end

        # Redact encrypted fields from Rails parameter logging when running
        # inside a Rails app (guarded — no-op under bare ActiveRecord/tests).
        def encryptable_register_filter_parameter(field)
          return unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

          filters = Rails.application.config.filter_parameters
          filters << field unless filters.include?(field)
        rescue StandardError
          nil
        end
      end

      private

      def encryptable_guard_audited_plaintext!
        return unless self.class.respond_to?(:auditable_fields)

        overlap = self.class.encryptable_rules.keys & Array(self.class.auditable_fields).map(&:to_sym)
        return if overlap.empty?

        raise ArgumentError,
              "#{LABEL}: #{overlap.map { |f| ":#{f}" }.join(', ')} declared with both Encryptable and " \
              "Auditable; auditing would persist decrypted plaintext. Remove them from auditable_by."
      end

      # Recompute each blind-index column from the (changed) plaintext just
      # before the row is written, so the fingerprint always matches the value.
      def encryptable_refresh_blind_indexes
        self.class.encryptable_rules.each do |field, rule|
          bi = rule[:blind_index]
          next unless bi
          next unless public_send("#{field}_changed?")

          self[bi[:column]] = ConcernsOnRails::Models::Encryptable.blind_fingerprint(rule, public_send(field))
        end
      end
    end
  end
end
