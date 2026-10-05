require "active_support/concern"
require "concerns_on_rails/core"
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/slug_sources"
require "concerns_on_rails/support/batch_ops"
require "concerns_on_rails/support/locking"
require "active_model/type"
require "bigdecimal"
require "time"
require "concerns_on_rails/encryption"
require "concerns_on_rails/support/encryptor"
require "concerns_on_rails/support/time_value"

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
    # A :datetime field behaves like a datetime column on the same model: under
    # time_zone_aware_attributes, zone-less input is read in Time.zone and the
    # value is a TimeWithZone. The plaintext is always UTC ISO8601.
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
    #   * `update_column`/`update_columns` DO encrypt (the value still
    #     serializes through the attribute type — `reencrypt!` and Anonymizable
    #     rely on it), but they skip validations, callbacks, dirty tracking and
    #     the blind-index refresh, so a field written that way is unsearchable
    #     until the row is saved normally.
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
        # (The audited-plaintext overlap is guarded at macro time from BOTH
        # declaration orders — here and in Auditable#auditable_by — so no
        # per-save backstop is needed.)
        before_save :encryptable_refresh_blind_indexes
        # The slug guard DOES need one: a slug is plaintext of its source, and
        # the macro-time checks cannot see every shape — Sluggable included
        # without sluggable_by (it slugs the implicit :name), or friendly_id
        # declared after `encryptable`. Checked before the row is written.
        before_save :encryptable_guard_slug_source!
      end

      # Rails < 7.1 does not memoize ActiveModel::Attribute#value_for_database,
      # so every write path re-serializes an encrypted value a second time
      # (fresh IV) when it "forgets" the assignment: the in-memory raw value is
      # then ciphertext that was never written. 7.1 introduced the memo (and
      # the private _value_for_database it wraps), which is what is detected.
      def self.stale_raw_after_write?
        return @stale_raw_after_write if defined?(@stale_raw_after_write)

        @stale_raw_after_write = !ActiveModel::Attribute.private_method_defined?(:_value_for_database)
      end

      # Deterministic blind-index fingerprint for a field's value under the
      # CURRENT key, applying the field's normalization `expression:` — what
      # the before_save refresh (and reencrypt!) writes: the digest of the
      # canonical plaintext (see blind_index_inputs). nil for a nil value.
      # `zone_aware:` is how the class doing the lookup reads a zone-less
      # String for a :datetime field, as its datetime column would
      # (Encryptable.zone_converted?). A Time is the same instant either way.
      # Only the canonical digest is ever written: a value that does not cast
      # (Infinity, garbage) is stored as NULL, so its fingerprint is nil too.
      def self.blind_fingerprint(rule, value, zone_aware: false)
        blind_fingerprints(rule, value, zone_aware: zone_aware, legacy: false).first
      end

      # The fingerprints under every key that can currently decrypt — current
      # first, then `previous_keys` — so lookups keep finding rows whose index
      # was written before a rotation and not yet re-encrypted. A per-field
      # `key:` has exactly one. Each key digests every blind_index_inputs
      # entry, the canonical one first. Empty for a nil value.
      def self.blind_fingerprints(rule, value, zone_aware: false, legacy: true)
        return [] if rule[:blind_index].nil? || value.nil?

        inputs = blind_index_inputs(rule, value, zone_aware, legacy: legacy)
        return [] if inputs.empty?

        config = ConcernsOnRails.encryption
        material = config.resolve_material(rule[:key])
        return inputs if material == ConcernsOnRails::Encryption::PASSTHROUGH

        keys = blind_index_materials(rule, config, material)
        inputs.flat_map do |input|
          keys.map { |key| ConcernsOnRails::Support::Encryptor.blind_index(input, key: key, salt: config.key_derivation_salt) }
        end.uniq
      end

      # What a digest is taken of, the written one first:
      #   1. the CANONICAL plaintext: the value cast through the field's type,
      #      in the form the cipher gets (a :datetime as UTC ISO8601), or
      #      `expression:` applied to that cast value (a :datetime handed over
      #      as a UTC Time). No request zone reaches it, and a String finds a
      #      typed field.
      #   2. the value's own `to_s` (after `expression:`), which is what the
      #      index hashed before, so a row indexed then is still found by the
      #      same lookup. For every type but :datetime the two are the same.
      def self.blind_index_inputs(rule, value, zone_aware, legacy: true)
        type = EncryptedType.new(type: rule[:type], key: rule[:key])
        expression = rule[:blind_index][:expression]
        canonical = blind_index_canonical(type, expression, value, zone_aware)
        [canonical, (blind_index_legacy(expression, value) if legacy)].compact.uniq
      end

      def self.blind_index_canonical(type, expression, value, zone_aware)
        typed = type.blind_index_value(value, zone_aware: zone_aware)
        return nil if typed.nil?

        expression ? expression.call(typed)&.to_s : type.plaintext_of(typed)
      end

      def self.blind_index_legacy(expression, value)
        (expression ? expression.call(value) : value)&.to_s
      rescue StandardError
        nil # an expression that only accepts the typed value
      end

      # Whether `klass` reads a zone-less String for `field` in Time.zone:
      # whether ActiveRecord wrapped the field's type in its TimeZoneConverter
      # for that class (see EncryptedType), looking through the decorations
      # around it (`normalizes`). Lookups then read a String exactly as an
      # assignment on that class does, on every Rails line: Rails decides
      # per class up to 7.1, and on the declaring class from 7.2.
      def self.zone_converted?(klass, field)
        time_zone_converted_type?(klass.type_for_attribute(field.to_s))
      end

      # Whether a (possibly decorated) attribute type contains ActiveRecord's
      # TimeZoneConverter.
      def self.time_zone_converted_type?(type)
        return false unless defined?(::ActiveRecord::AttributeMethods::TimeZoneConversion::TimeZoneConverter)

        8.times do
          return true if type.is_a?(::ActiveRecord::AttributeMethods::TimeZoneConversion::TimeZoneConverter)
          return false unless type.respond_to?(:__getobj__)

          type = type.__getobj__
        end
        false
      end

      # Rails 7.2+ applies time-zone conversion to a declared attribute when
      # it is declared (TimeZoneConversion#hook_attribute_type); up to 7.1,
      # per class at schema load.
      def self.declaration_time_zone_conversion?
        return @declaration_time_zone_conversion if defined?(@declaration_time_zone_conversion)

        @declaration_time_zone_conversion =
          defined?(::ActiveRecord::AttributeMethods::TimeZoneConversion::ClassMethods) &&
          ::ActiveRecord::AttributeMethods::TimeZoneConversion::ClassMethods.private_method_defined?(:hook_attribute_type)
      end

      # A per-field key is one key; gem-keyed fields fingerprint under the
      # current key and every previous one.
      def self.blind_index_materials(rule, config, current)
        return [current] if rule[:key]

        config.key_ids.filter_map { |id| config.key_material_for(id) }
      end

      # One digest → equality, several → IN.
      def self.blind_index_predicate(fingerprints)
        fingerprints.length == 1 ? fingerprints.first : fingerprints
      end

      # Custom type registered on each encrypted column. cast handles user input
      # (plaintext in memory), serialize encrypts on the write-to-DB path, and
      # deserialize decrypts on the read-from-DB path. An immutable value type,
      # so dirty tracking compares the cast plaintext — a re-save of unchanged
      # data is not dirtied by GCM's random IV.
      #
      # A :datetime field reports the :datetime type, so ActiveRecord gives it
      # the time-zone handling it gives any `attribute :name, :datetime`: under
      # time_zone_aware_attributes it wraps this type in its TimeZoneConverter
      # (zone-less input read in Time.zone, reads as TimeWithZones), minus
      # skip_time_zone_conversion_for_attributes. Where Rails decides that is
      # Rails' own business: per class up to 7.1 (a subclass's own setting
      # applies), on the declaring class from 7.2. Being a wrapper, it keeps
      # `normalizes` and a re-declared key inherited as usual. This
      # type itself therefore casts and reads without a zone, as the column's
      # own type does (ActiveRecord.default_timezone). The plaintext is always
      # UTC ISO8601, so none of this changes what is stored.
      class EncryptedType < ActiveModel::Type::Value
        # ActiveModel's own test (Type::Helpers::Numeric#non_numeric_string?).
        # Only an integer column's `where` refuses such a String: a float or
        # decimal column casts it (".5" is 0.5), so those fields do too.
        NUMERIC_STRING = /\A\s*[+-]?\d/

        def initialize(type: :string, key: nil)
          @type = type
          @key = key
          super()
        end

        # Only :datetime is reported: it is what enables the time-zone
        # conversion above. Other types keep the generic value type.
        def type
          @type == :datetime ? :datetime : super
        end

        # Called by ActiveRecord's TimeZoneConverter on the type it wraps, as on
        # its own datetime types: zone-less user input becomes Time.zone time.
        def user_input_in_time_zone(value)
          value.in_time_zone
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

          @type == :datetime ? read_time(plaintext) : cast_typed(plaintext)
        end

        # The typed value a blind index is computed from: the cast value, a
        # :datetime as a UTC Time so no request zone reaches the digest. A
        # zone-less String is read as the looking-up class's column reads it
        # (`zone_aware:`). nil when the value does not cast, and for a
        # non-numeric String on an :integer field: "abc" casts to 0, but an
        # integer column's `where(age: "abc")` finds nothing, so this does too.
        def blind_index_value(value, zone_aware: false)
          return nil if non_numeric_string?(value)
          return cast_typed(value) unless @type == :datetime

          typed = ConcernsOnRails::Support::TimeValue.cast(value, zone_aware: zone_aware)
          typed && ConcernsOnRails::Support::TimeValue.utc(typed)
        rescue StandardError
          nil
        end

        # The canonical plaintext of a typed value: what the cipher encrypts.
        def plaintext_of(typed)
          stringify(typed)
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
          when :datetime then ConcernsOnRails::Support::TimeValue.cast(value, zone_aware: false)
          else CASTERS[@type].cast(value)
          end
        rescue StandardError
          nil
        end

        # The stored plaintext is the UTC ISO8601 String `stringify` writes.
        # Any other form (a plain column adopted under on_missing_key:
        # :passthrough) is a DATABASE value: TimeValue.read reads it in
        # default_timezone, as ActiveRecord reads a datetime column. Showing
        # it in Time.zone is the TimeZoneConverter's job (see the class note).
        def read_time(plaintext)
          ConcernsOnRails::Support::TimeValue.read(plaintext, zone_aware: false)
        rescue StandardError
          nil
        end

        def non_numeric_string?(value)
          @type == :integer && value.is_a?(::String) && !NUMERIC_STRING.match?(value)
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
          # A UTC copy: Time#utc converts in place, so it rewrote the caller's
          # Time, and a frozen one raised here and saved the field as NULL.
          when :datetime then ConcernsOnRails::Support::TimeValue.utc(typed).iso8601(6)
          else typed.to_s
          end
        end

        def to_big_decimal(value)
          return nil if value.nil?

          value.is_a?(BigDecimal) ? value : BigDecimal(value.to_s)
        end

        # Gem-keyed fields stamp the configured key_id so rotation can tell old
        # rows apart; a per-field `key:` is outside rotation and always writes 0.
        def write_ciphertext(plaintext)
          config = ConcernsOnRails.encryption
          material = config.resolve_material(@key)
          return plaintext if material == ConcernsOnRails::Encryption::PASSTHROUGH

          ConcernsOnRails::Support::Encryptor.encrypt(
            plaintext, key: material, key_id: @key ? 0 : config.key_id, salt: config.key_derivation_salt
          )
        end

        def read_plaintext(stored)
          config = ConcernsOnRails.encryption
          material = config.resolve_material(@key)
          return stored if material == ConcernsOnRails::Encryption::PASSTHROUGH

          material = rotation_material(stored, config) unless @key
          ConcernsOnRails::Support::Encryptor.decrypt(
            stored, key: material, salt: config.key_derivation_salt
          )
        rescue ConcernsOnRails::Encryption::DecryptionError
          raise if config.raise_on_decrypt_error

          nil
        end

        # The envelope says which key wrote it; the config says whether that key
        # is still around (current or previous).
        def rotation_material(stored, config)
          id = ConcernsOnRails::Support::Encryptor.key_id(stored)
          config.key_material_for(id) ||
            raise(ConcernsOnRails::Encryption::DecryptionError,
                  "value was encrypted with unknown key id #{id} — add it to ConcernsOnRails.encryption.previous_keys")
        end
      end

      module ClassMethods
        include ConcernsOnRails::Support::ColumnGuard

        # Declare one or more encrypted fields. Repeatable; per-field options.
        def encryptable(*fields, type: :string, key: nil, blind_index: nil)
          @encryptable_declaring = true # see _default_attributes
          type = type.to_sym
          encryptable_validate!(fields, type, blind_index)
          ensure_columns!(LABEL, *fields, types: :text)

          fields.each do |field|
            field = field.to_sym
            encryptable_guard_auditable!(field)
            encryptable_guard_sluggable!(field)
            encryptable_guard_queryable!(field)
            bi = encryptable_normalize_blind_index(field, blind_index)
            ensure_columns!(LABEL, bi[:column], types: "string:index") if bi
            self.encryptable_rules = encryptable_rules.merge(field => { type: type, key: key, blind_index: bi })
            attribute field, EncryptedType.new(type: type, key: key)
            encryptable_define_helpers(field)
            encryptable_define_blind_index(field, bi) if bi
            encryptable_register_filter_parameter(field)
          end
        ensure
          @encryptable_declaring = false
        end

        # From Rails 7.2, ActiveRecord fixes a declared attribute's time-zone
        # conversion when the attribute is declared, on the declaring class
        # (hook_attribute_type). A skip list naming an encrypted :datetime
        # field that is set after its `encryptable` line, or on a subclass,
        # can then no longer reach it. Refuse that, rather than silently
        # convert a field the developer opted out of. It is checked when
        # ActiveRecord builds the class's attribute set (first record, query
        # or type lookup), memoized on that set, so it costs one comparison
        # per call after that. Not while the schema loads (7.2+ precomputes
        # the set there, and a macro's column check loads it mid-class-body)
        # nor while `encryptable` itself runs (its column check builds the
        # set BEFORE the field's new type is attached): re-declaring the field
        # after the skip list, with other macros in between, is what applies
        # it. Up to 7.1 Rails decides per class at schema load, so the setting
        # applies wherever it is made and nothing is checked.
        def _default_attributes
          attributes = super
          return attributes if @encryptable_declaring || @encryptable_loading_schema
          return attributes if @encryptable_skip_checked.equal?(attributes)

          encryptable_refuse_late_skip!(attributes)
          attributes
        end

        def load_schema!
          @encryptable_loading_schema = true
          super
        ensure
          @encryptable_loading_schema = false
        end
        private :load_schema!

        # Rows whose ciphertext for any of `fields` (default: every gem-keyed
        # field) was written under a key other than the current one — the
        # envelope header is a fixed 4-char Base64 prefix per key id, so this is
        # a prefix comparison on the column, no decryption. Per-field `key:`
        # fields never rotate and are ignored.
        #
        # The comparison must be case-EXACT: Base64 prefixes for ids 26..51
        # reuse the letters of 0..25 in the other case, and both SQLite's LIKE
        # and MySQL's default collation fold case — which silently matched
        # every row and made this return nothing. Hence SUBSTR + `<>`, with
        # MySQL forced onto a binary collation.
        #
        # SCOPE: called on the model itself (`Patient.needs_reencryption`) it
        # covers the WHOLE table — rows hidden by a default_scope (SoftDeletable,
        # Publishable `default_scope: true`) still hold ciphertext under the old
        # key, and dropping that key from previous_keys makes them unreadable,
        # so "nothing left to rotate" must count them. Called on a relation
        # (`Patient.where(org_id: 1).needs_reencryption`, an association, a
        # `scoping` block) it narrows exactly that relation, default scope
        # included like any other chain — start from `unscoped` to reach hidden
        # rows in a subset.
        def needs_reencryption(*fields)
          columns = encryptable_rotatable_fields(fields)
          base = encryptable_rotation_base
          return base.none if columns.empty?

          prefix = ConcernsOnRails::Support::Encryptor.header_prefix(ConcernsOnRails.encryption.key_id)
          clauses = columns.map do |field|
            quoted = "#{quoted_table_name}.#{connection.quote_column_name(field)}"
            "(#{quoted} IS NOT NULL AND #{encryptable_prefix_mismatch_sql(quoted)})"
          end
          base.where(clauses.join(" OR "), *Array.new(columns.size, prefix))
        end

        # Case-exact "the first 4 characters are not this prefix", per adapter.
        # The MySQL family is matched the way Models::Storable matches it —
        # Trilogy (the Rails 7.1+ default) reports "Trilogy" and MariaDB setups
        # report "Mariadb", so a bare "mysql" test would drop both back onto the
        # case-folding comparison this branch exists to avoid.
        def encryptable_prefix_mismatch_sql(quoted)
          if connection.adapter_name.to_s.downcase.match?(/mysql|mariadb|trilogy/)
            "CAST(SUBSTRING(#{quoted}, 1, 4) AS BINARY) <> ?"
          else
            "SUBSTR(#{quoted}, 1, 4) <> ?"
          end
        end

        # Rewrite every stale row (see needs_reencryption) under the current key,
        # blind indexes included — one guarded UPDATE per row, streamed with
        # find_each, no giant transaction (each row is valid before and after).
        # Returns the Integer count of rows rewritten. Run it after every
        # rotation, then drop the old id from `previous_keys`.
        #
        # `Patient.reencrypt_all!` sweeps the whole table, default_scope
        # bypassed (soft-deleted / unpublished rows included); on a relation it
        # sweeps exactly that relation (see needs_reencryption).
        def reencrypt_all!(*fields)
          columns = encryptable_rotatable_fields(fields)
          return 0 if columns.empty? # e.g. only per-field-keyed fields were named

          count = 0
          ConcernsOnRails::Support::BatchOps.each_record(needs_reencryption(*columns)) do |record|
            count += 1 if record.reencrypt!(*columns)
          end
          count
        end

        # Gem-keyed encrypted fields (all, or the validated subset). Per-field
        # `key:` fields are not part of rotation.
        def encryptable_rotatable_fields(fields)
          rotatable = encryptable_rules.reject { |_field, rule| rule[:key] }.keys
          return rotatable if fields.empty?

          fields.map(&:to_sym).each do |field|
            next if encryptable_rules.key?(field)

            raise ArgumentError, "#{LABEL}: #{field} is not an encryptable field (declared: #{encryptable_rules.keys.join(', ')})"
          end
          fields.map(&:to_sym) & rotatable
        end

        private

        # The relation a rotation sweeps: the caller's explicit relation when
        # there is one (relation delegation and `scoping` set current_scope),
        # otherwise every row of the table, default_scope bypassed.
        def encryptable_rotation_base
          current_scope ? all : unscoped
        end

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
          # The value AT REST — the column's stored content, before the type
          # deserializes it. Useful for migrations, debugging, and asserting no
          # plaintext is at rest. nil while the field carries an unsaved change.
          #
          # That last clause is the fix: this used to return
          # read_attribute_before_type_cast unconditionally, and for a column
          # overridden with `attribute` that is the caller's PLAINTEXT whenever
          # the value has not round-tripped through the database — a new record,
          # or any record with a pending assignment (i.e. exactly the state
          # inside a before_save, a validator, or an error-reporting path). A
          # reader named `_ciphertext`, documented for "asserting no plaintext
          # is at rest", handed back the SSN, so `log.info(user.ssn_ciphertext)`
          # wrote it straight to the log.
          define_method("#{field}_ciphertext") do
            next nil if new_record? || public_send("#{field}_changed?")

            read_attribute_before_type_cast(field)
          end

          # True only when what is stored really is an encryption envelope. The
          # old `.present?` was true for plaintext too, so the natural guard
          # `raise unless user.ssn_encrypted?` passed on a record whose column
          # held the raw value. Note this is honestly false under
          # `on_missing_key: :passthrough`, where plaintext at rest is the
          # opted-into behavior.
          define_method("#{field}_encrypted?") do
            ConcernsOnRails::Support::Encryptor.envelope?(public_send("#{field}_ciphertext"))
          end

          # The key id stamped into the stored envelope, for auditing a rotation
          # ("which key is this row under?"). nil when nothing is at rest yet —
          # it reads <field>_ciphertext, so it is never asked of plaintext.
          define_method("#{field}_key_id") do
            stored = public_send("#{field}_ciphertext")
            stored.nil? ? nil : ConcernsOnRails::Support::Encryptor.key_id(stored)
          end
        end

        def encryptable_refuse_late_skip!(attributes)
          late = ConcernsOnRails::Models::Encryptable.declaration_time_zone_conversion? ? encryptable_late_skipped_fields(attributes) : []
          unless late.empty?
            raise ArgumentError,
                  "#{LABEL}: skip_time_zone_conversion_for_attributes names #{late.map(&:inspect).join(', ')}, " \
                  "declared with time-zone conversion by `encryptable ... type: :datetime`. From Rails 7.2 " \
                  "ActiveRecord fixes a declared attribute's conversion where it is declared: set the skip list " \
                  "before the `encryptable` line, or re-declare the field after it"
          end
          @encryptable_skip_checked = attributes
        end

        # Encrypted :datetime fields the skip list names but whose type
        # ActiveRecord converted anyway. Symbols only, as ActiveRecord reads
        # the list (`include?(name.to_sym)`): a String entry skips nothing.
        def encryptable_late_skipped_fields(attributes)
          skipped = skip_time_zone_conversion_for_attributes
          encryptable_rules.select do |field, rule|
            rule[:type] == :datetime && skipped.include?(field) &&
              ConcernsOnRails::Models::Encryptable.time_zone_converted_type?(attributes[field.to_s].type)
          end.keys
        end

        # find_by_<field> / where_<field> / <field>_fingerprint for equality
        # lookups through the deterministic blind-index column.
        def encryptable_define_blind_index(field, blind_index)
          column = blind_index[:column]

          define_singleton_method("#{field}_fingerprint") do |value|
            ConcernsOnRails::Models::Encryptable.blind_fingerprint(
              encryptable_rules.fetch(field), value, zone_aware: ConcernsOnRails::Models::Encryptable.zone_converted?(self, field)
            )
          end
          # Accepts one value, several, or an array — multiple values become an
          # IN query on the fingerprint column. Returns a Relation, so it chains
          # with scopes, `.or`, `.merge` (for joins), and further `.where`.
          # Lookups match the digest under the current key AND every previous
          # key, so rows not yet re-encrypted after a rotation are still found.
          define_singleton_method("where_#{field}") do |*values|
            rule = encryptable_rules.fetch(field)
            zone_aware = ConcernsOnRails::Models::Encryptable.zone_converted?(self, field)
            fingerprints = values.flatten.flat_map do |v|
              ConcernsOnRails::Models::Encryptable.blind_fingerprints(rule, v, zone_aware: zone_aware)
            end
            # A nil value has no fingerprint; passing it through would build
            # `WHERE bidx IS NULL` and match every unfingerprinted row instead
            # of "value is nil".
            return none if fingerprints.empty?

            where(column => ConcernsOnRails::Models::Encryptable.blind_index_predicate(fingerprints))
          end
          define_singleton_method("find_by_#{field}") do |value|
            fingerprints = ConcernsOnRails::Models::Encryptable.blind_fingerprints(
              encryptable_rules.fetch(field), value, zone_aware: ConcernsOnRails::Models::Encryptable.zone_converted?(self, field)
            )
            return nil if fingerprints.empty?

            find_by(column => ConcernsOnRails::Models::Encryptable.blind_index_predicate(fingerprints))
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

        # Macro-time guard for the order Sluggable-first: a friendly_id slug is
        # plaintext of its source, so slugging an encrypted field would store
        # the value in clear. Checks sources declared through sluggable_by
        # (its `candidates:` included); Sluggable mirrors this for the reverse
        # order.
        # A bare friendly_id model (`friendly_id :ssn, use: :slugged`) is
        # checked here too; Sluggable's implicit :name default is left to the
        # save-time backstop, since a sluggable_by may still follow.
        def encryptable_guard_sluggable!(field)
          return if respond_to?(:sluggable_declared) && !sluggable_declared
          return unless ConcernsOnRails::Support::SlugSources.names(self).include?(field.to_sym)

          raise ArgumentError, encryptable_slug_source_message(field)
        end

        def encryptable_slug_source_message(field)
          "#{LABEL}: ':#{field}' is also a slug source (Sluggable / friendly_id); the slug would store " \
            "the decrypted plaintext in the slug column. Slug from a non-sensitive field instead."
        end

        # Macro-time guard for the order Searchable/Taggable-first: `search` and
        # `tagged_with` are LIKE queries on the column, which holds ciphertext
        # under a random IV, so they would silently match nothing. Searchable
        # and Taggable mirror this for the reverse order. An undeclared
        # Taggable (its :tags default, a taggable_by may still follow) is left
        # to tagged_with's call-time check.
        def encryptable_guard_queryable!(field)
          concern = if encryptable_searched_field?(field)
                      "Searchable (search)"
                    elsif encryptable_tagged_field?(field)
                      "Taggable (tagged_with)"
                    end
          return unless concern

          raise ArgumentError,
                "#{LABEL}: ':#{field}' is also queried by #{concern}, whose LIKE match would run against the " \
                "ciphertext and never find a row. Query a non-encrypted column instead (a blind index gives " \
                "exact-match lookups: `blind_index: true`, then where_#{field})."
        end

        def encryptable_searched_field?(field)
          respond_to?(:searchable_fields) && searchable_fields.map(&:to_sym).include?(field)
        end

        def encryptable_tagged_field?(field)
          respond_to?(:taggable_declared) && taggable_declared && taggable_field.to_sym == field
        end

        # Redact encrypted fields from Rails parameter logging. The gem-level
        # registry is consulted at filter time by the proc ConcernsOnRails::
        # Railtie appends to config.filter_parameters at boot — so fields
        # registered when the model class loads later (lazy loading in
        # development) are still redacted, and boot-time snapshotters
        # (ActiveRecord filter_attributes, lograge-style initializers) see the
        # proc. The direct append remains as a fallback for apps that require
        # the gem after boot and for non-String param values.
        #
        # Only that best-effort fallback is rescued. The registry write is the
        # load-bearing half and must never be swallowed — a blanket rescue
        # once hid a NoMethodError here (the concern required without the
        # gem's loader), and the field silently went unfiltered.
        def encryptable_register_filter_parameter(field)
          ConcernsOnRails.filter_parameter_registry.add(field)
          return unless defined?(Rails) && Rails.respond_to?(:application) && Rails.application

          begin
            filters = Rails.application.config.filter_parameters
            filters << field unless filters.include?(field)
          rescue NameError
            raise
          rescue StandardError
            nil # e.g. a filter list frozen after boot — the registry covers it
          end
        end
      end

      # Re-encrypt this record's gem-keyed fields (or the given subset) under
      # the current key, refreshing their blind indexes — ONE UPDATE, no
      # validations/callbacks: the values don't change, only their ciphertext,
      # and a callback (an Auditable capture, a webhook) must not fire for a key
      # rotation — nor does lock_version move, so no open instance goes stale
      # (see encryptable_rotate_row!). Returns true when something was
      # rewritten, then reloads so the record's ciphertext readers describe
      # what is now at rest.
      #
      # The UPDATE is GUARDED on the exact ciphertext each field was read with.
      # A rotation runs for hours against a live table, and an unguarded
      # `SET ssn = <plaintext read at load> WHERE id = ?` silently reverts any
      # value the app wrote in between — data loss caused by the very sweep
      # meant to protect it. A row that lost the guard needs no rotating anyway:
      # the write that beat us used the current key. A field carrying an unsaved
      # change is skipped for the same reason — persisting it here would commit
      # the caller's pending edit with no validations behind their back.
      def reencrypt!(*fields)
        updates, guards, binds = encryptable_rotation_plan(fields)
        return false if updates.empty?
        return false unless encryptable_rotate_row!(updates, guards, binds) == 1

        reload
        true
      end

      # Every save/create/touch ends in changes_applied; on Rails < 7.1 that is
      # where the encrypted attributes are re-serialized with a new IV (see
      # Encryptable.stale_raw_after_write?), so re-read what was really stored.
      def changes_applied(...)
        result = super
        encryptable_sync_stored_ciphertext!
        result
      end

      # update_columns / update_column write their own serialization and keep
      # yet another in memory — same staleness, same repair.
      def update_columns(attributes)
        result = super
        written = attributes.keys.map(&:to_s) & self.class.encryptable_rules.keys.map(&:to_s)
        encryptable_sync_stored_ciphertext!(written) if written.any?
        result
      end

      private

      # Replace the in-memory raw value of each encrypted field with the
      # ciphertext actually at rest — one SELECT, raw adapter values (never
      # pluck, which would decrypt through the attribute type). Only Rails
      # < 7.1 needs it; fields not loaded (a partial `select`) or NULL are
      # skipped, as NULL serializes to NULL and is never stale.
      def encryptable_sync_stored_ciphertext!(fields = nil)
        return unless encryptable_stored_ciphertext_syncable?

        names = encryptable_stored_field_names(fields)
        return if names.empty?

        sql = self.class.unscoped.where(self.class.primary_key => id_in_database).select(*names).to_sql
        row = self.class.connection.select_rows(sql).first
        names.each_with_index { |name, index| @attributes.write_from_database(name, row[index]) } if row
      end

      def encryptable_stored_ciphertext_syncable?
        ConcernsOnRails::Models::Encryptable.stale_raw_after_write? &&
          !new_record? && !destroyed? && !self.class.primary_key.nil?
      end

      def encryptable_stored_field_names(fields)
        (fields || self.class.encryptable_rules.keys.map(&:to_s)).select do |name|
          has_attribute?(name) && !read_attribute_before_type_cast(name).nil?
        end
      end

      # What reencrypt! would write: the new values (plus their refreshed blind
      # indexes) and the ciphertext each one was read with, as guard predicates.
      def encryptable_rotation_plan(fields)
        updates = {}
        guards = []
        binds = []
        self.class.encryptable_rotatable_fields(fields).each do |field|
          stored = read_attribute_before_type_cast(field)
          next if stored.nil? || public_send("#{field}_changed?")

          value = public_send(field)
          # A rotation must never be able to destroy data. Under
          # `raise_on_decrypt_error = false` a field that cannot be decrypted
          # reads as nil, and writing that back would NULL the ciphertext AND
          # the blind index of exactly the rows a rotation exists to save.
          # Refuse the field instead — re-running once the key is restored fixes it.
          next if value.nil?

          rule = self.class.encryptable_rules.fetch(field)
          updates[field] = value
          updates[rule[:blind_index][:column]] = ConcernsOnRails::Models::Encryptable.blind_fingerprint(rule, value) if rule[:blind_index]
          guards << "#{self.class.quoted_table_name}.#{self.class.connection.quote_column_name(field)} = ?"
          binds << stored
        end
        [updates, guards, binds]
      end

      # The guarded single-statement rewrite behind reencrypt!. `unscoped` so a
      # row hidden by a default_scope (SoftDeletable) is still rotatable once
      # the caller holds it, matching update_columns.
      #
      # Under optimistic locking the lock_version column is pinned to itself:
      # update_all would otherwise bump it, and a rotation — which changes no
      # value — turned every record open in an edit form during the sweep
      # into a StaleObjectError. (A write the app makes meanwhile still bumps
      # it as usual; the ciphertext guard is what keeps the two apart.)
      def encryptable_rotate_row!(updates, guards, binds)
        primary_key = self.class.primary_key
        # id_in_database is Rails 5.2+; for a persisted row whose primary key
        # has not been reassigned in memory the attribute is the same value.
        pk_value = respond_to?(:id_in_database) ? id_in_database : self[primary_key]
        self.class.unscoped
            .where(primary_key => pk_value)
            .where(guards.join(" AND "), *binds)
            .update_all(updates.merge(ConcernsOnRails::Support::Locking.pinned(self.class)))
      end

      # Recompute each blind-index column from the (changed) plaintext just
      # before the row is written, so the fingerprint always matches the value.
      def encryptable_refresh_blind_indexes
        encryptable_refresh_blind_indexes_for(self.class.encryptable_rules.keys)
      end

      # Support::GeneratedValues consumer. A token / code / number generated in
      # before_create arrives AFTER the before_save refresh above, so without
      # this the row was INSERTed with a NULL fingerprint and find_by_<field>
      # never found a freshly created record.
      def encryptable_generated_values_assigned(columns)
        encryptable_refresh_blind_indexes_for(columns)
      end

      def encryptable_refresh_blind_indexes_for(fields)
        rules = self.class.encryptable_rules
        fields.each do |field|
          rule = rules[field.to_sym]
          bi = rule && rule[:blind_index]
          next unless bi
          next unless public_send("#{field}_changed?")

          self[bi[:column]] = ConcernsOnRails::Models::Encryptable.blind_fingerprint(rule, public_send(field))
        end
      end

      # Save-time backstop for the macro-time slug guards: raise (nothing is
      # written) when the model's friendly_id slug is resolved from an
      # encrypted field — whatever the declaration order, including
      # Sluggable's implicit :name default and a method named like a field.
      def encryptable_guard_slug_source!
        klass = self.class
        overlap = ConcernsOnRails::Support::SlugSources.names(klass) & klass.encryptable_rules.keys
        return if overlap.empty?

        raise ArgumentError, klass.send(:encryptable_slug_source_message, overlap.first)
      end
    end
  end
end
