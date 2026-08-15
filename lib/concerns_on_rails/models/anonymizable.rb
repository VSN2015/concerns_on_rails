require "active_support/concern"
require "concerns_on_rails/support/column_guard"
require "digest"
require "securerandom"

module ConcernsOnRails
  module Models
    # Declarative right-to-erasure ("GDPR-lite") for personal data. The fourth
    # member of the sensitive-data suite: Maskable masks *display*, Sanitizable
    # strips *HTML*, Encryptable protects *at rest* — Anonymizable DESTROYS.
    #
    #   class User < ApplicationRecord
    #     include ConcernsOnRails::Models::Anonymizable
    #
    #     anonymizable :email, with: :email                 # unique fake address
    #     anonymizable :first_name, :last_name, with: :redact
    #     anonymizable :ssn, with: :nullify
    #     anonymizable :bio, with: ->(value) { value && "removed by user request" }
    #   end
    #
    #   user.anonymize!        # one UPDATE: strategies + anonymized_at stamp
    #   user.anonymized?       # => true
    #   User.not_anonymized    # scope (and .anonymized)
    #   User.where(...).anonymize_all!   # batch; returns the count
    #
    # HOW IT WRITES — deliberately update_columns (single UPDATE, no
    # validations, no callbacks): erasure must not be blocked by a presence/
    # format validation, and must not run callbacks that would copy the OLD
    # values somewhere new (Auditable's capture hook is the canonical example).
    # update_columns serializes each value through the model's attribute types
    # — Encryptable's custom type included — so a field that is also
    # `encryptable` stores a fresh ciphertext envelope of the anonymized
    # value, never plaintext. The record is reloaded afterwards so in-memory
    # readers see the anonymized values through the types.
    #
    # Strategy presets (`with:`):
    #   :nullify    — nil
    #   :redact     — "[REDACTED]"
    #   :hash       — SHA-256 hex of the value (deterministic pseudonymization:
    #                 the same input digests the same, so datasets keyed on the
    #                 value still join — NOT full anonymization)
    #   :email      — "anon-<random-hex>@anonymized.invalid" (random + unique,
    #                 so NOT NULL / unique-index email columns survive erasure;
    #                 .invalid is an RFC 2606 reserved TLD — it can never send)
    #   :random_hex — 32 random hex chars (unique tokens/usernames)
    #   a callable  — ->(value) { ... } or ->(value, record) { ... }; nil-in
    #                 nil-out is the preset convention, custom callables choose
    #
    # Notes:
    #   * The stamp column (default :anonymized_at, `stamp: false` to opt out)
    #     is what makes `anonymized?`, the scopes, and anonymize_all!'s
    #     idempotency work — add it (a datetime) unless you truly can't.
    #   * Auditable interaction: if any anonymized field is also audited, the
    #     trail already holds historical plaintext, so anonymize! clears the
    #     audit column in the SAME update (opt out per-macro with
    #     `clear_audit_trail: false`). The trail is one column — clearing is
    #     all-or-nothing.
    #   * Encryptable interaction: works transparently (see HOW IT WRITES).
    #   * Erasure is terminal: unsaved changes on the instance are discarded by
    #     the post-write reload.
    module Anonymizable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Models::Anonymizable".freeze
      DEFAULT_STAMP = :anonymized_at
      # Distinguishes "option not passed" from an explicit value, so repeat
      # macro calls merge fields without silently resetting earlier options.
      UNSET = Object.new

      PRESETS = {
        nullify: ->(_value) {},
        redact: ->(value) { value.nil? ? nil : "[REDACTED]" },
        hash: ->(value) { value.nil? ? nil : Digest::SHA256.hexdigest(value.to_s) },
        email: ->(value) { value.nil? ? nil : "anon-#{SecureRandom.hex(10)}@anonymized.invalid" },
        random_hex: ->(value) { value.nil? ? nil : SecureRandom.hex(16) }
      }.freeze

      included do
        class_attribute :anonymizable_rules, instance_accessor: false, default: {}
        class_attribute :anonymizable_stamp, instance_accessor: false, default: DEFAULT_STAMP
        class_attribute :anonymizable_clear_audit, instance_accessor: false, default: true
        class_attribute :anonymizable_scopes_defined, instance_accessor: false, default: false
      end

      module ClassMethods
        include ConcernsOnRails::Support::ColumnGuard

        # Declare fields and their erasure strategy. Repeatable — field rules
        # merge across calls; stamp:/clear_audit_trail:/prefix:/suffix: apply
        # only when explicitly passed (last explicit value wins).
        def anonymizable(*fields, with:, stamp: UNSET, clear_audit_trail: UNSET, prefix: nil, suffix: nil)
          raise ArgumentError, "#{LABEL}: at least one field is required" if fields.empty?

          strategy = anonymizable_resolve_strategy(with)
          anonymizable_apply_options(stamp, clear_audit_trail)

          ensure_columns!(LABEL, fields)
          ensure_columns!(LABEL, anonymizable_stamp) if anonymizable_stamp
          self.anonymizable_rules = anonymizable_rules.merge(fields.to_h { |f| [f.to_sym, strategy] })

          anonymizable_define_scopes(prefix, suffix)
        end

        # Anonymize every matching record that isn't already stamped, in one
        # transaction. Returns the Integer count of records anonymized (the
        # 1.22 batch contract). Without a stamp column every record matches.
        def anonymize_all!
          transaction do
            all.to_a.count do |record|
              next false if record.anonymized?

              record.anonymize!
              true
            end
          end
        end

        private

        def anonymizable_apply_options(stamp, clear_audit_trail)
          # `.presence` (not `&.`): `stamp: false` must resolve to nil, and
          # false&.to_sym would raise.
          self.anonymizable_stamp = stamp.presence && stamp.to_sym unless stamp.equal?(UNSET)
          return if clear_audit_trail.equal?(UNSET)

          self.anonymizable_clear_audit = clear_audit_trail ? true : false
        end

        def anonymizable_resolve_strategy(with)
          case with
          when Symbol
            PRESETS.fetch(with) do
              raise ArgumentError, "#{LABEL}: unknown preset '#{with}'. Valid presets: #{PRESETS.keys.join(', ')}"
            end
          else
            raise ArgumentError, "#{LABEL}: :with must be a preset symbol or a callable, got #{with.class}" unless with.respond_to?(:call)

            with
          end
        end

        # Scopes read the class attribute lazily, so later stamp changes take
        # effect; defined once (affixes come from the first defining call).
        def anonymizable_define_scopes(prefix, suffix)
          return if anonymizable_scopes_defined || anonymizable_stamp.nil?

          self.anonymizable_scopes_defined = true
          affixed = ->(base) { [prefix, base, suffix].compact.join("_") }
          scope affixed.call("anonymized"), -> { where.not(anonymizable_stamp => nil) }
          scope affixed.call("not_anonymized"), -> { where(anonymizable_stamp => nil) }
        end
      end

      # Lifecycle hooks — override in the model. Run inside the anonymize!
      # transaction, so a raising hook rolls the erasure back.
      def before_anonymize; end
      def after_anonymize; end

      # Erase the configured fields in a single UPDATE (see the module docs for
      # why validations and callbacks are deliberately skipped). Returns true.
      def anonymize!
        raise ArgumentError, "#{LABEL}: anonymize! cannot be called on a new record" if new_record?

        payload = anonymizable_payload
        transaction do
          before_anonymize
          update_columns(payload)
          after_anonymize
        end
        # update_columns leaves DB-serialized values (e.g. ciphertext) in the
        # in-memory attributes; reload so readers decode through the types.
        reload
        true
      end

      # True when the stamp column is set; always false with `stamp: false`
      # (there is nothing to observe).
      def anonymized?
        stamp = self.class.anonymizable_stamp
        stamp ? self[stamp].present? : false
      end

      private

      # { column => value }: strategy output cast through the attribute's type,
      # plus the stamp and — when an anonymized field is also audited — the
      # cleared audit column. update_columns serializes each value through the
      # model's attribute types (verified: Encryptable's custom type included),
      # so an encrypted field stores a fresh ciphertext envelope — passing a
      # pre-serialized value here would double-encrypt.
      def anonymizable_payload
        payload = {}
        self.class.anonymizable_rules.each do |field, strategy|
          value = anonymizable_apply_strategy(strategy, public_send(field))
          payload[field] = self.class.type_for_attribute(field.to_s).cast(value)
        end
        stamp = self.class.anonymizable_stamp
        payload[stamp] = Time.zone.now if stamp
        payload[self.class.auditable_into] = nil if anonymizable_clear_audit_column?
        payload
      end

      def anonymizable_apply_strategy(strategy, value)
        strategy.arity == 1 ? strategy.call(value) : strategy.call(value, self)
      end

      # The audit trail holds historical plaintext of tracked fields; when any
      # of them is being erased, the trail must go too (see module docs).
      def anonymizable_clear_audit_column?
        return false unless self.class.anonymizable_clear_audit
        return false unless self.class.respond_to?(:auditable_fields)

        tracked = Array(self.class.auditable_fields).map(&:to_sym)
        self.class.anonymizable_rules.keys.intersect?(tracked)
      end
    end
  end
end
