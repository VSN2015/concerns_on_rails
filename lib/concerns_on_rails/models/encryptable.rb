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
    #     encryptable :ssn, :notes          # transparent string encryption
    #     encryptable :dob, type: :date     # decrypts back to a Date
    #   end
    #
    #   p = Patient.create!(ssn: "123-45-6789", dob: Date.new(1990, 1, 1))
    #   p.ssn                 # => "123-45-6789"
    #   p.reload.dob          # => Wed, 01 Jan 1990
    #   p.ssn_ciphertext      # => "AQEA..." (Base64 envelope; no plaintext at rest)
    #   p.ssn_encrypted?      # => true
    #
    # `type:` casts the decrypted value (reuses the Storable caster set:
    # :string default, :integer, :float, :decimal, :boolean, :date, :datetime).
    # `key:` overrides the gem-level key per field (a String or a Proc).
    #
    # Notes:
    #   * The declared column must be `text` (or binary): it stores an opaque
    #     Base64 envelope, not the logical type. `nil` stays `nil` (never an
    #     encrypted blank).
    #   * Non-deterministic by design (random IV) — the same plaintext yields
    #     different ciphertext every write, so encrypted columns are NOT
    #     queryable/searchable (`where(:ssn)` matches ciphertext). Deterministic,
    #     queryable fields and multi-key rotation are planned follow-ups; the
    #     envelope already reserves the bytes for them.
    #   * Never `update_column`/`update_columns` an encrypted field — those
    #     bypass the type and write raw plaintext to the column.
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
        # { field => { type:, key: } }. Subclasses inherit and may add fields.
        class_attribute :encryptable_rules, instance_accessor: false, default: {}
        # Backstop for the reverse declaration order (Auditable added AFTER
        # Encryptable): the macro-time guard can't see a not-yet-declared audit.
        before_save :encryptable_guard_audited_plaintext!
      end

      # Custom type registered on each encrypted column. cast handles user input
      # (plaintext in memory), serialize encrypts on the write-to-DB path, and
      # deserialize decrypts on the read-from-DB path. An immutable value type,
      # so dirty tracking compares the cast plaintext — a re-save of unchanged
      # data is not dirtied by GCM's random IV.
      class EncryptedType < ActiveModel::Type::Value
        PASSTHROUGH = :__concerns_on_rails_passthrough__

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
          material = resolve_key_material(config)
          return plaintext if material == PASSTHROUGH

          ConcernsOnRails::Support::Encryptor.encrypt(
            plaintext, key: material, salt: config.key_derivation_salt
          )
        end

        def read_plaintext(stored)
          config = ConcernsOnRails.encryption
          material = resolve_key_material(config)
          return stored if material == PASSTHROUGH

          ConcernsOnRails::Support::Encryptor.decrypt(
            stored, key: material, salt: config.key_derivation_salt
          )
        rescue ConcernsOnRails::Encryption::DecryptionError
          raise if config.raise_on_decrypt_error

          nil
        end

        # Per-field key: wins; else the gem-level key; else raise (or the
        # passthrough sentinel in the dev/test escape-hatch mode).
        def resolve_key_material(config)
          material = @key.respond_to?(:call) ? @key.call : @key
          material = material.to_s unless material.nil?
          return material if material && !material.empty?

          global = config.key_material
          return global unless global.nil?
          return PASSTHROUGH if config.on_missing_key == :passthrough

          raise ConcernsOnRails::Encryption::MissingKeyError,
                "#{LABEL}: no encryption key configured. Set " \
                "ConcernsOnRails.configure_encryption { |c| c.key = ... } or pass key: to the macro."
        end
      end

      module ClassMethods
        include ConcernsOnRails::Support::ColumnGuard

        # Declare one or more encrypted fields. Repeatable; per-field options.
        def encryptable(*fields, type: :string, key: nil)
          raise ArgumentError, "#{LABEL}: at least one field is required" if fields.empty?

          type = type.to_sym
          raise ArgumentError, "#{LABEL}: unknown type ':#{type}' (valid: #{VALID_TYPES.join(', ')})" unless VALID_TYPES.include?(type)

          ensure_columns!(LABEL, *fields)

          fields.each do |field|
            field = field.to_sym
            encryptable_guard_auditable!(field)
            self.encryptable_rules = encryptable_rules.merge(field => { type: type, key: key })
            attribute field, EncryptedType.new(type: type, key: key)
            encryptable_define_helpers(field)
            encryptable_register_filter_parameter(field)
          end
        end

        private

        def encryptable_define_helpers(field)
          # Raw stored value: the DB ciphertext once persisted (before the type
          # deserializes it). Useful for migrations, debugging, and asserting no
          # plaintext is at rest.
          define_method("#{field}_ciphertext") { read_attribute_before_type_cast(field) }
          define_method("#{field}_encrypted?") { read_attribute_before_type_cast(field).present? }
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
    end
  end
end
