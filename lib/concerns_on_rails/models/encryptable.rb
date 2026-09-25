require "active_support/concern"
require "concerns_on_rails/core"
require "concerns_on_rails/support/column_guard"
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
      # the before_save refresh (and reencrypt!) writes. nil for a nil value.
      def self.blind_fingerprint(rule, value)
        blind_fingerprints(rule, value).first
      end

      # The fingerprints under every key that can currently decrypt — current
      # first, then `previous_keys` — so lookups keep finding rows whose index
      # was written before a rotation and not yet re-encrypted. A per-field
      # `key:` has exactly one. Empty for a nil value.
      def self.blind_fingerprints(rule, value)
        bi = rule[:blind_index]
        return [] if bi.nil? || value.nil?

        normalized = bi[:expression] ? bi[:expression].call(value) : value
        return [] if normalized.nil?

        config = ConcernsOnRails.encryption
        material = config.resolve_material(rule[:key])
        return [normalized.to_s] if material == ConcernsOnRails::Encryption::PASSTHROUGH

        blind_index_materials(rule, config, material).map do |key|
          ConcernsOnRails::Support::Encryptor.blind_index(normalized, key: key, salt: config.key_derivation_salt)
        end.uniq
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
          type = type.to_sym
          encryptable_validate!(fields, type, blind_index)
          ensure_columns!(LABEL, *fields, types: :text)

          fields.each do |field|
            field = field.to_sym
            encryptable_guard_auditable!(field)
            bi = encryptable_normalize_blind_index(field, blind_index)
            ensure_columns!(LABEL, bi[:column], types: "string:index") if bi
            self.encryptable_rules = encryptable_rules.merge(field => { type: type, key: key, blind_index: bi })
            attribute field, EncryptedType.new(type: type, key: key)
            encryptable_define_helpers(field)
            encryptable_define_blind_index(field, bi) if bi
            encryptable_register_filter_parameter(field)
          end
        end

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
          needs_reencryption(*columns).find_each do |record|
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
          # Lookups match the digest under the current key AND every previous
          # key, so rows not yet re-encrypted after a rotation are still found.
          define_singleton_method("where_#{field}") do |*values|
            rule = encryptable_rules.fetch(field)
            fingerprints = values.flatten.flat_map { |v| ConcernsOnRails::Models::Encryptable.blind_fingerprints(rule, v) }
            # A nil value has no fingerprint; passing it through would build
            # `WHERE bidx IS NULL` and match every unfingerprinted row instead
            # of "value is nil".
            return none if fingerprints.empty?

            where(column => ConcernsOnRails::Models::Encryptable.blind_index_predicate(fingerprints))
          end
          define_singleton_method("find_by_#{field}") do |value|
            fingerprints = ConcernsOnRails::Models::Encryptable.blind_fingerprints(encryptable_rules.fetch(field), value)
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
      # rotation. Returns true when something was rewritten, then reloads so the
      # record's ciphertext readers describe what is now at rest.
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
      def encryptable_rotate_row!(updates, guards, binds)
        primary_key = self.class.primary_key
        # id_in_database is Rails 5.2+; for a persisted row whose primary key
        # has not been reassigned in memory the attribute is the same value.
        pk_value = respond_to?(:id_in_database) ? id_in_database : self[primary_key]
        self.class.unscoped
            .where(primary_key => pk_value)
            .where(guards.join(" AND "), *binds)
            .update_all(updates)
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
