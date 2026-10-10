require "active_support/concern"
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/encrypted_lookup"
require "concerns_on_rails/support/generated_values"
require "concerns_on_rails/support/random_value"
require "concerns_on_rails/support/unique_retry"
require "active_support/security_utils"
require "securerandom"

module ConcernsOnRails
  module Models
    # Generates and manages security tokens (API keys, invite codes, share links).
    #
    #   class User < ApplicationRecord
    #     include ConcernsOnRails::Tokenizable
    #
    #     tokenizable_by :api_token                              # 32-char URL-safe
    #     tokenizable_by :reset_password_token, length: 24, expires_in: 2.hours
    #     tokenizable_by :invite_code, type: :alphanumeric, length: 8
    #   end
    #
    #   user = User.create!                       # tokens auto-generated on create
    #   user.regenerate_api_token!                # new value, persisted
    #   user.revoke_api_token!                    # sets the column to nil
    #   user.api_token?                           # true if present
    #
    #   User.find_by_api_token(token)             # Rails default
    #   User.authenticate_by_api_token(token)     # constant-time compare; returns record or nil
    #   User.consume_invite_code(code)            # authenticate AND revoke in one step (single use)
    #
    # `expires_in:` gives a field a lifetime: `<field>_expires_at` (a datetime
    # column you add) is stamped when the token is generated — on create
    # (a caller-supplied token that arrives without its own expiry included)
    # and on regenerate_<field>! — and cleared by revoke_<field>!. Assigning a
    # token to an already-persisted row stamps nothing; rotate with
    # regenerate_<field>! instead.
    # `authenticate_by_<field>` / `consume_<field>` refuse an expired token,
    # `<field>_expired?` reports it, and the `<field>_expired` scope finds rows
    # for cleanup. `consume_<field>` (every field) revokes with a conditional
    # UPDATE, so two concurrent consumers cannot both win.
    #
    # Unlike Hashable, one model can declare multiple token fields, generation is
    # URL-safe by default, and `assign_tokenizable_value` retries on uniqueness
    # collisions before insert (best-effort; pair with a unique DB index).
    #
    # For stateless / self-expiring tokens (password resets, email confirmations)
    # on Rails 7.1+, consider the framework-native `generates_token_for` instead.
    module Tokenizable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Models::Tokenizable".freeze
      VALID_TYPES = %i[urlsafe hex alphanumeric numeric].freeze
      ALPHANUMERIC_ALPHABET = (("A".."Z").to_a + ("a".."z").to_a + ("0".."9").to_a).freeze
      NUMERIC_ALPHABET = ("0".."9").to_a.freeze
      MAX_GENERATION_ATTEMPTS = 10

      included do
        class_attribute :tokenizable_fields, instance_accessor: false, default: {}
      end

      module ClassMethods
        include ConcernsOnRails::Support::ColumnGuard

        # Configure a tokenizable field.
        #
        # Options:
        #   type:       one of :urlsafe (default), :hex, :alphanumeric, :numeric
        #   length:     character length of the generated token (default 32)
        #   expires_in: a Duration / seconds — stamps `<field>_expires_at` on
        #               generation and makes authenticate/consume refuse stale tokens
        def tokenizable_by(field, type: :urlsafe, length: 32, expires_in: nil)
          field = field.to_sym
          type = type.to_sym
          length = length.to_i
          expires_in = validate_tokenizable_options!(type, length, expires_in)

          # One call, so an unmigrated model is told about the token column AND
          # its expiry column at once — one migration, not two boot failures.
          columns = { field => "string:uniq" }
          columns[tokenizable_expiry_column(field)] = :datetime if expires_in
          ensure_columns!(LABEL, *columns.keys, types: columns)

          # Build a fresh hash so subclasses don't mutate the parent's config.
          self.tokenizable_fields = tokenizable_fields.merge(field => { type: type, length: length, expires_in: expires_in })

          before_create -> { tokenizable_assign_on_create(field) }

          define_tokenizable_methods(field)
          define_tokenizable_expiry_methods(field) if expires_in
        end

        # Generate a new random value for the given field using its configured type/length.
        def generate_tokenizable_value(field)
          config = tokenizable_fields.fetch(field) do
            raise ArgumentError, "#{LABEL}: '#{field}' is not a tokenizable field"
          end

          length = config[:length]

          case config[:type]
          when :urlsafe      then SecureRandom.urlsafe_base64(length)[0, length]
          when :hex          then SecureRandom.hex((length + 1) / 2)[0, length]
          when :alphanumeric then ConcernsOnRails::Support::RandomValue.from_alphabet(ALPHANUMERIC_ALPHABET, length)
          when :numeric      then ConcernsOnRails::Support::RandomValue.from_alphabet(NUMERIC_ALPHABET, length)
          end
        end

        # `<field>_expires_at` — the column an `expires_in:` field stamps.
        def tokenizable_expiry_column(field)
          :"#{field}_expires_at"
        end

        private

        def define_tokenizable_methods(field)
          # Same uniqueness path as create-time assignment (pre-1.22 this wrote
          # one blind candidate — a short :numeric invite code regenerated
          # straight into RecordNotUnique with no retry). Each attempt runs in
          # its own savepoint so a rejected UPDATE inside a caller's
          # transaction doesn't abort it on PostgreSQL.
          define_method("regenerate_#{field}!") do
            ConcernsOnRails::Support::UniqueRetry.with_retries(limit: MAX_GENERATION_ATTEMPTS, savepoint: self.class) do
              update!(tokenizable_generated_attributes(field))
            end
          end
          define_method("revoke_#{field}!")     { update!(tokenizable_revoked_attributes(field)) }
          define_method("#{field}?")            { self[field].present? }
          define_method("#{field}_expired?")    { tokenizable_expired?(field) }
          define_singleton_method("authenticate_by_#{field}") { |value| timing_safe_find(field, value) }
          define_singleton_method("consume_#{field}") { |value| consume_tokenizable_value(field, value) }
        end

        def define_tokenizable_expiry_methods(field)
          column = tokenizable_expiry_column(field)
          scope :"#{field}_expired", -> { where.not(column => nil).where(arel_table[column].lteq(Time.current)) }
        end

        # NOTE: the find_by below is an indexed SQL equality, which is not itself
        # timing-safe; secure_compare only hardens the in-Ruby comparison of the
        # already-fetched candidate. For a truly constant-time lookup, store and
        # query a digest instead of the raw token. An expired token never
        # authenticates.
        #
        # An `encryptable` token column holds ciphertext with a random IV, so
        # the equality runs on its blind index instead (the decrypted value is
        # then secure_compared as usual). Without a blind index no query can
        # find the row, so this raises rather than failing every login as nil.
        def timing_safe_find(field, value)
          tokenizable_refuse_unqueryable!(field)
          return nil unless tokenizable_lookup_value?(value)

          candidate = find_by(ConcernsOnRails::Support::EncryptedLookup.condition(self, field, value))
          return nil unless candidate

          stored = candidate[field].to_s
          given = value.to_s
          return nil unless stored.bytesize == given.bytesize
          return nil unless ActiveSupport::SecurityUtils.secure_compare(stored, given)

          candidate.public_send("#{field}_expired?") ? nil : candidate
        end

        # Single use: authenticate, then revoke with a conditional UPDATE keyed
        # on the token still being there — if a concurrent consumer got in
        # first, the UPDATE touches 0 rows and this call returns nil. For an
        # encrypted token both the key and the revocation go through the blind
        # index, which is cleared too (update_all skips Encryptable's refresh,
        # and a stale digest would keep find_by_<field> resolving the row).
        def consume_tokenizable_value(field, value)
          record = public_send("authenticate_by_#{field}", value)
          return nil unless record

          revoked = unscoped.where(primary_key => record.id)
                            .where(ConcernsOnRails::Support::EncryptedLookup.condition(self, field, value))
                            .update_all(tokenizable_consumed_attributes(record, field))
          revoked == 1 ? record.reload : nil
        end

        # Only a non-blank String (or an Integer — a numeric code from a JSON
        # body) is looked up. A crafted param (`?token[a]=b`) arrives as a
        # Hash or ActionController::Parameters, which find_by cannot cast
        # (TypeError: a 500 instead of a 401), and an Array would run an
        # IN (...) over the caller's guesses; anything else answers nil, like
        # a wrong token, without a query.
        def tokenizable_lookup_value?(value)
          (value.is_a?(String) || value.is_a?(Integer)) && value.present?
        end

        def tokenizable_consumed_attributes(record, field)
          attributes = record.send(:tokenizable_revoked_attributes, field)
          index = ConcernsOnRails::Support::EncryptedLookup.index_column(self, field)
          index ? attributes.merge(index => nil) : attributes
        end

        # Checked when the finder is CALLED, not at tokenizable_by: encrypting a
        # token at rest without a blind index is a supported combination (the
        # token is generated, stored and compared on the loaded record), only
        # the lookup by value is impossible — and `encryptable` may be declared
        # before or after this macro.
        def tokenizable_refuse_unqueryable!(field)
          return unless ConcernsOnRails::Support::EncryptedLookup.unqueryable?(self, field)

          raise ArgumentError,
                "#{LABEL}: '#{field}' is encrypted (Encryptable) without a blind index, so no query can find a " \
                "record by its token — authenticate_by_#{field} / consume_#{field} would never match. " \
                "Declare `encryptable :#{field}, blind_index: true`."
        end

        def validate_tokenizable_options!(type, length, expires_in)
          raise ArgumentError, "#{LABEL}: unknown type '#{type}'. Valid types: #{VALID_TYPES.join(', ')}" unless VALID_TYPES.include?(type)
          raise ArgumentError, "#{LABEL}: length must be a positive integer" unless length.positive?
          return nil if expires_in.nil?

          seconds = positive_duration_seconds(expires_in)
          return seconds if seconds

          raise ArgumentError, "#{LABEL}: expires_in must be a positive Duration or number of seconds"
        end

        # Mirrors Lockable#positive_duration_or_nil?. A bare respond_to?(:to_i)
        # accepted values the siblings reject: `2.hours.from_now` is a Time whose
        # to_i is ~1.8e9 seconds (the token would expire in 2083 — the feature
        # silently off), and "2 hours" coerces to 2 seconds. Returns the lifetime
        # in whole seconds, or nil when the value is not a positive duration.
        def positive_duration_seconds(value)
          return nil unless value.is_a?(ActiveSupport::Duration) || value.is_a?(Numeric)

          seconds = value.to_i
          seconds.positive? ? seconds : nil
        end
      end

      # Assigns the generated value only when blank, so callers can pass an
      # explicit one; an `expires_in:` field also gets its expiry stamped when
      # the caller didn't set one.
      def assign_tokenizable_value(field)
        self[field] = tokenizable_unique_value(field) if self[field].blank?

        column = tokenizable_expiry_column_for(field)
        self[column] = tokenizable_expiry_from_now(field) if column && self[field].present? && self[column].blank?
      end

      # Generate → in-Ruby exists? precheck → retry, up to MAX_GENERATION_ATTEMPTS
      # times — useful for short codes; a unique DB index is still the real
      # guarantee. Shared by create-time assignment and regenerate_<field>!.
      # Checked against the STI base class: a subclass's own relation carries
      # its type condition and would miss a sibling subclass's token. An
      # encrypted field is checked through its blind index (the ciphertext
      # column never matches); one without an index cannot be checked at all.
      def tokenizable_unique_value(field)
        MAX_GENERATION_ATTEMPTS.times do
          candidate = self.class.generate_tokenizable_value(field)
          condition = ConcernsOnRails::Support::EncryptedLookup.condition(self.class, field, candidate)
          return candidate if condition.nil? || !self.class.base_class.unscoped.exists?(condition)
        end

        raise "#{LABEL}: could not generate a unique value for '#{field}' " \
              "after #{MAX_GENERATION_ATTEMPTS} attempts — consider a longer length or a larger alphabet"
      end

      private

      # The before_create path: generate (and stamp the expiry), then tell the
      # siblings that already ran — Encryptable's blind index, a slug built
      # from the token, Auditable's creation entry (Support::GeneratedValues).
      def tokenizable_assign_on_create(field)
        ConcernsOnRails::Support::GeneratedValues.watch(self, [field, tokenizable_expiry_column_for(field)]) do
          assign_tokenizable_value(field)
        end
      end

      # A fresh token plus, for an expiring field, a fresh expiry.
      def tokenizable_generated_attributes(field)
        attributes = { field => tokenizable_unique_value(field) }
        column = tokenizable_expiry_column_for(field)
        attributes[column] = tokenizable_expiry_from_now(field) if column
        attributes
      end

      def tokenizable_revoked_attributes(field)
        attributes = { field => nil }
        column = tokenizable_expiry_column_for(field)
        attributes[column] = nil if column
        attributes
      end

      # nil for a field declared without expires_in:.
      def tokenizable_expiry_column_for(field)
        config = self.class.tokenizable_fields.fetch(field)
        config[:expires_in] ? self.class.tokenizable_expiry_column(field) : nil
      end

      def tokenizable_expiry_from_now(field)
        Time.current + self.class.tokenizable_fields.fetch(field)[:expires_in]
      end

      # True only for an expiring field whose expiry has been reached; a field
      # without expires_in:, or a row with no expiry set, never expires.
      def tokenizable_expired?(field)
        column = tokenizable_expiry_column_for(field)
        return false unless column

        expires_at = self[column]
        expires_at.present? && expires_at <= Time.current
      end
    end
  end
end
