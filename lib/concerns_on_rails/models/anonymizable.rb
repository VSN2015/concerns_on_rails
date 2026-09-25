require "active_support/concern"
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/affix"
require "concerns_on_rails/support/batch_ops"
require "concerns_on_rails/support/hooked_write"
require "concerns_on_rails/support/unique_retry"
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
    #   * Encryptable interaction: works transparently (see HOW IT WRITES),
    #     and erasure is never blocked by ciphertext that will not decrypt:
    #     :nullify reads nothing, :redact/:email/:random_hex check presence
    #     only, and :hash/callables fall back to a fresh random 64-hex value
    #     (cast through the field's type) for a value that cannot be read.
    #   * Slugs (`slug:` :auto / true / false): a friendly_id slug built from an
    #     anonymized COLUMN is replaced in the same UPDATE by a random,
    #     length-fitting slug and its history rows are deleted. :auto cannot
    #     see through a method or Proc slug source — declare `slug: true`.
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

      # Presets whose output never depends on the old value — only on whether
      # there was one (nil in, nil out). They are fed a presence marker instead
      # of the value, so an encrypted field is never decrypted to be erased.
      # :nullify needs not even that.
      PRESENCE_ONLY_PRESETS = %i[redact email random_hex].map { |name| PRESETS.fetch(name) }.freeze
      # Stands in for the old value of a presence-only preset; never persisted.
      PRESENT = Object.new.freeze
      # A value-dependent strategy (:hash, a callable) whose old value cannot
      # be read — ciphertext that will not decrypt — gets a fresh random value
      # of this many bytes (64 hex chars, the shape of the SHA-256 digest :hash
      # writes). Random per row, never a constant: a constant would give every
      # unreadable row the same blind-index fingerprint and trip a unique index.
      UNREADABLE_FALLBACK_BYTES = 32
      # `slug:` — :auto rewrites a slug only when its source columns are
      # anonymized; true always; false never.
      SLUG_MODES = [:auto, true, false].freeze
      # The slug that replaces one generated from an erased field:
      # "anon-<32 hex>", shortened to fit the slug COLUMN's limit (Sluggable's
      # max_length: is cosmetic — conflict suffixes already exceed it). The
      # prefix is kept only while MIN_SLUG_RANDOM random characters (64 bits)
      # still fit beside it; a column too short for MIN_SLUG_RANDOM raises
      # when a slug would be rewritten. A collision is retried with a fresh
      # value (SLUG_WRITE_ATTEMPTS in total).
      ANONYMIZED_SLUG_PREFIX = "anon-".freeze
      FULL_SLUG_RANDOM = 32
      MIN_SLUG_RANDOM = 16
      SLUG_WRITE_ATTEMPTS = 3

      included do
        class_attribute :anonymizable_rules, instance_accessor: false, default: {}
        class_attribute :anonymizable_stamp, instance_accessor: false, default: DEFAULT_STAMP
        class_attribute :anonymizable_clear_audit, instance_accessor: false, default: true
        class_attribute :anonymizable_scopes_defined, instance_accessor: false, default: false
        class_attribute :anonymizable_slug, instance_accessor: false, default: :auto
      end

      module ClassMethods
        include ConcernsOnRails::Support::ColumnGuard

        # Declare fields and their erasure strategy. Repeatable — field rules
        # merge across calls; stamp:/clear_audit_trail:/prefix:/suffix: apply
        # only when explicitly passed (last explicit value wins).
        def anonymizable(*fields, with:, stamp: UNSET, clear_audit_trail: UNSET, slug: UNSET, prefix: nil, suffix: nil)
          raise ArgumentError, "#{LABEL}: at least one field is required" if fields.empty?

          strategy = anonymizable_resolve_strategy(with)
          anonymizable_apply_slug_option(slug)
          anonymizable_apply_options(stamp, clear_audit_trail)

          ensure_columns!(LABEL, fields)
          ensure_columns!(LABEL, anonymizable_stamp, types: :datetime) if anonymizable_stamp
          self.anonymizable_rules = anonymizable_rules.merge(fields.to_h { |f| [f.to_sym, strategy] })

          anonymizable_define_scopes(prefix, suffix)
        end

        # Whether anonymize! replaces the friendly_id slug (see the module
        # docs). Only :slugged friendly_id models have one. :auto compares
        # the slug's SOURCE COLUMNS with the anonymized fields; a slug built
        # through a method or Proc is not guessed at — declare `slug: true`.
        def anonymizable_rewrites_slug?
          return false unless respond_to?(:friendly_id_config) && friendly_id_config.uses?(:slugged)
          return anonymizable_slug unless anonymizable_slug == :auto

          anonymizable_slug_source_columns.intersect?(anonymizable_rules.keys)
        end

        # The slug's source columns. The gem's Sluggable: the `candidates:`
        # entries that are columns (nested arrays flattened) when given — they
        # replace the sluggable field — else the sluggable field. A bare
        # friendly_id model: its base, when that is a column.
        def anonymizable_slug_source_columns
          columns = column_names
          anonymizable_slug_sources.filter_map do |source|
            source.to_sym if (source.is_a?(Symbol) || source.is_a?(String)) && columns.include?(source.to_s)
          end
        rescue ActiveRecord::ActiveRecordError
          # Schema unreachable only (the ColumnGuard convention) — any other
          # error propagates: swallowing it would silently keep a PII slug.
          []
        end

        # A random, non-identifying replacement slug that fits the slug
        # column's `limit`. Raises (before anything is written) when the
        # column cannot hold MIN_SLUG_RANDOM random characters.
        def anonymizable_random_slug
          room = anonymizable_slug_column_limit
          prefix = ANONYMIZED_SLUG_PREFIX
          return "#{prefix}#{anonymizable_random_hex(FULL_SLUG_RANDOM)}" if room.nil? || room >= prefix.length + FULL_SLUG_RANDOM
          return "#{prefix}#{anonymizable_random_hex(room - prefix.length)}" if room >= prefix.length + MIN_SLUG_RANDOM
          return anonymizable_random_hex(room) if room >= MIN_SLUG_RANDOM

          raise ArgumentError, anonymizable_slug_room_message(room)
        end

        # Anonymize every matching record that isn't already stamped, in one
        # transaction. Returns the Integer count of records anonymized (the
        # 1.22 batch contract). Without a stamp column every record matches.
        # Streams in PK batches (BatchOps.each_record, so an ordered/limited
        # relation erases exactly the rows it selects) rather than loading
        # the relation, filters stamped rows DB-side, and skips the per-record
        # reload — the batch discards its instances, so reloading each one
        # would cost a wasted SELECT per row. Deliberately NOT BatchOps.run:
        # an erasure batch maximises progress. Each record runs in its own
        # savepoint, so one whose hook vetoes (a legal hold) is skipped
        # without undoing the others, and only records actually erased count.
        def anonymize_all!
          relation = anonymizable_stamp ? all.where(anonymizable_stamp => nil) : all
          transaction do
            count = 0
            ConcernsOnRails::Support::BatchOps.each_record(relation) do |record|
              next if record.anonymized?

              count += 1 if record.send(:anonymize_record!)
            end
            count
          end
        end

        private

        # nil is rejected rather than read as :auto — omit the option for the
        # default. Explicit values persist across later calls that omit it.
        def anonymizable_apply_slug_option(slug)
          return if slug.equal?(UNSET)
          unless SLUG_MODES.any? { |mode| mode.equal?(slug) }
            raise ArgumentError, "#{LABEL}: slug: must be :auto, true or false (got #{slug.inspect})"
          end

          self.anonymizable_slug = slug
        end

        # Every declared slug source, columns or not (see
        # anonymizable_slug_source_columns).
        def anonymizable_slug_sources
          return Array(friendly_id_config.base).flatten unless respond_to?(:sluggable_field)

          sluggable_candidates ? Array(sluggable_candidates).flatten : [sluggable_field]
        end

        def anonymizable_random_hex(length)
          SecureRandom.hex((length + 1) / 2)[0, length]
        end

        # The slug column's declared `limit` (nil when unlimited or the schema
        # is unreachable — the UPDATE itself then reports a real failure).
        def anonymizable_slug_column_limit
          columns_hash[friendly_id_config.slug_column.to_s]&.limit
        rescue ActiveRecord::ActiveRecordError
          nil
        end

        def anonymizable_slug_room_message(room)
          "#{LABEL}: the slug column allows only #{room} characters, but an anonymized slug needs at least " \
            "#{MIN_SLUG_RANDOM} random characters to stay unique — widen the column, or pass slug: false " \
            "to leave slugs out of erasure"
        end

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
          prefix = ConcernsOnRails::Support::Affix.normalize(prefix, default: anonymizable_stamp)
          suffix = ConcernsOnRails::Support::Affix.normalize(suffix, default: anonymizable_stamp)
          scope ConcernsOnRails::Support::Affix.name(:anonymized, prefix: prefix, suffix: suffix),
                -> { where.not(anonymizable_stamp => nil) }
          scope ConcernsOnRails::Support::Affix.name(:not_anonymized, prefix: prefix, suffix: suffix),
                -> { where(anonymizable_stamp => nil) }
        end
      end

      # Lifecycle hooks — override in the model. Run inside the anonymize!
      # transaction, so a raising hook rolls the erasure back.
      def before_anonymize; end
      def after_anonymize; end

      # Erase the configured fields in a single UPDATE (see the module docs for
      # why validations and callbacks are deliberately skipped). Returns true,
      # or false when a hook vetoed the erasure with ActiveRecord::Rollback
      # (nothing is written, even inside a caller's transaction).
      def anonymize!
        return false unless anonymize_record!

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

      # The write itself, without the trailing reload — anonymize_all! goes
      # through this directly because its instances are discarded.
      def anonymize_record!
        raise ArgumentError, "#{LABEL}: anonymize! cannot be called on a new record" if new_record?

        # Support::HookedWrite: own savepoint (a hook's Rollback is honored
        # inside a caller's transaction and anonymize_all!), true only once
        # after_anonymize has returned, and on any abort the in-memory values
        # update_columns already synced are put back.
        payload = anonymizable_payload
        slug = anonymizable_slug_payload!(payload)
        ConcernsOnRails::Support::HookedWrite.run(self, before: :before_anonymize, after: :after_anonymize,
                                                        restore: payload.keys) do
          anonymizable_write!(payload, slug[:generated])
          anonymizable_delete_slug_history! if slug[:history]
          true
        end
      end

      # The single UPDATE. When it carries a generated slug, a unique-index
      # collision is retried with a fresh slug, each attempt in its own
      # SAVEPOINT so the surrounding transaction (anonymize_all!'s batch
      # included) survives the rejected write on PostgreSQL.
      def anonymizable_write!(payload, generated_slug_column)
        return update_columns(payload) unless generated_slug_column

        attempt = 0
        ConcernsOnRails::Support::UniqueRetry.with_retries(limit: SLUG_WRITE_ATTEMPTS, savepoint: self.class) do
          payload[generated_slug_column] = self.class.anonymizable_random_slug if (attempt += 1) > 1
          update_columns(payload)
        end
      end

      # { column => value }: strategy output cast through the attribute's type,
      # plus the stamp and — when an anonymized field is also audited — the
      # cleared audit column. update_columns serializes each value through the
      # model's attribute types (verified: Encryptable's custom type included),
      # so an encrypted field stores a fresh ciphertext envelope — passing a
      # pre-serialized value here would double-encrypt.
      def anonymizable_payload
        payload = {}
        self.class.anonymizable_rules.each do |field, strategy|
          value = anonymizable_erased_value(field, strategy)
          cast = self.class.type_for_attribute(field.to_s).cast(value)
          payload[field] = cast
          anonymizable_add_blind_index(payload, field, cast)
        end
        stamp = self.class.anonymizable_stamp
        payload[stamp] = Time.zone.now if stamp
        payload[self.class.auditable_into] = nil if anonymizable_clear_audit_column?
        payload
      end

      # update_columns skips before_save, so Encryptable's blind-index refresh
      # never runs here. Without this, the `<field>_bidx` column would keep the
      # deterministic fingerprint of the ERASED value — find_by_<field> with
      # the old PII would still resolve the record after anonymization.
      def anonymizable_add_blind_index(payload, field, value)
        return unless self.class.respond_to?(:encryptable_rules)

        rule = self.class.encryptable_rules[field]
        return unless rule && rule[:blind_index]

        payload[rule[:blind_index][:column]] =
          ConcernsOnRails::Models::Encryptable.blind_fingerprint(rule, value)
      end

      def anonymizable_apply_strategy(strategy, value)
        strategy.arity == 1 ? strategy.call(value) : strategy.call(value, self)
      end

      # The strategy's output for `field`, reading no more of the old value
      # than the strategy needs: :nullify reads nothing, the presence-only
      # presets learn only nil-or-not (for an encrypted field, from the stored
      # ciphertext — nothing is decrypted), and only :hash / callables read the
      # value itself. When that value is ciphertext that will not decrypt, the
      # field falls back to a fresh random value (UNREADABLE_FALLBACK_BYTES)
      # rather than blocking erasure (or rolling back an anonymize_all! batch). The DecryptionError is
      # swallowed deliberately and never re-raised with the value in it.
      def anonymizable_erased_value(field, strategy)
        return nil if strategy.equal?(PRESETS[:nullify])
        return strategy.call(anonymizable_value_present?(field) ? PRESENT : nil) if PRESENCE_ONLY_PRESETS.include?(strategy)

        value, readable = anonymizable_read_old_value(field)
        # Cast through the field's type like any strategy output.
        return SecureRandom.hex(UNREADABLE_FALLBACK_BYTES) unless readable

        anonymizable_apply_strategy(strategy, value)
      end

      # [value, readable]. An encrypted field is unreadable when it raises a
      # DecryptionError, or — with raise_on_decrypt_error off — when it reads
      # as nil although ciphertext is stored.
      def anonymizable_read_old_value(field)
        value = public_send(field)
        return [value, true] unless value.nil? && anonymizable_encrypted_field?(field)

        [nil, !anonymizable_stored_value?(field)]
      rescue ConcernsOnRails::Encryption::DecryptionError
        [nil, false]
      end

      def anonymizable_value_present?(field)
        return !public_send(field).nil? unless anonymizable_encrypted_field?(field)

        anonymizable_stored_value?(field)
      end

      # Whether an encrypted field holds a value, without decrypting it: a
      # pending assignment is in-memory plaintext (no crypto to read it);
      # otherwise the column's stored ciphertext is either there or NULL.
      def anonymizable_stored_value?(field)
        return !public_send(field).nil? if public_send("#{field}_changed?")

        !read_attribute_before_type_cast(field.to_s).nil?
      end

      def anonymizable_encrypted_field?(field)
        self.class.respond_to?(:encryptable_rules) && self.class.encryptable_rules.key?(field.to_sym)
      end

      # A slug generated from an erased field IS that field's PII
      # ("jane-smith"), and update_columns skips the callbacks that would
      # regenerate it. When the slug is rewritten (see the class method
      # anonymizable_rewrites_slug?), a random non-identifying slug joins the
      # same UPDATE. Returns { generated: <slug column, when this generated
      # the value>, history: <friendly_id history rows must go too> }.
      def anonymizable_slug_payload!(payload)
        klass = self.class
        return {} unless klass.anonymizable_rewrites_slug?

        config = klass.friendly_id_config
        slug_column = config.slug_column.to_sym
        plan = { history: config.uses?(:history) && respond_to?(:slugs) }
        # An explicit `anonymizable :slug, with: ...` rule wins.
        return plan if payload.key?(slug_column)

        payload[slug_column] = klass.anonymizable_random_slug
        plan.merge(generated: slug_column)
      end

      # friendly_id's history table keeps every earlier slug — each one as
      # identifying as the current. Deleted inside the erasure transaction, so
      # a vetoing hook puts them back with everything else.
      def anonymizable_delete_slug_history!
        association(:slugs).scope.unscope(:order).delete_all
        association(:slugs).reset
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
