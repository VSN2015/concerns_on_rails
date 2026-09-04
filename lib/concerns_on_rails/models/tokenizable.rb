require "active_support/concern"
require "concerns_on_rails/support/column_guard"
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
    # column you add) is stamped whenever the token is generated — on create,
    # on regenerate_<field>!, and for a caller-supplied token that arrives
    # without its own expiry — and cleared by revoke_<field>!.
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

          ensure_columns!(LABEL, field, types: "string:uniq")
          ensure_columns!(LABEL, tokenizable_expiry_column(field), types: :datetime) if expires_in

          # Build a fresh hash so subclasses don't mutate the parent's config.
          self.tokenizable_fields = tokenizable_fields.merge(field => { type: type, length: length, expires_in: expires_in })

          before_create -> { assign_tokenizable_value(field) }

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
          # straight into RecordNotUnique with no retry).
          define_method("regenerate_#{field}!") do
            ConcernsOnRails::Support::UniqueRetry.with_retries(limit: MAX_GENERATION_ATTEMPTS) do
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
        def timing_safe_find(field, value)
          return nil if value.blank?

          candidate = find_by(field => value)
          return nil unless candidate

          stored = candidate[field].to_s
          given = value.to_s
          return nil unless stored.bytesize == given.bytesize
          return nil unless ActiveSupport::SecurityUtils.secure_compare(stored, given)

          candidate.public_send("#{field}_expired?") ? nil : candidate
        end

        # Single use: authenticate, then revoke with a conditional UPDATE keyed
        # on the token still being there — if a concurrent consumer got in
        # first, the UPDATE touches 0 rows and this call returns nil.
        def consume_tokenizable_value(field, value)
          record = public_send("authenticate_by_#{field}", value)
          return nil unless record

          revoked = unscoped.where(primary_key => record.id, field => value)
                            .update_all(record.send(:tokenizable_revoked_attributes, field))
          revoked == 1 ? record.reload : nil
        end

        def validate_tokenizable_options!(type, length, expires_in)
          raise ArgumentError, "#{LABEL}: unknown type '#{type}'. Valid types: #{VALID_TYPES.join(', ')}" unless VALID_TYPES.include?(type)
          raise ArgumentError, "#{LABEL}: length must be a positive integer" unless length.positive?
          return nil if expires_in.nil?
          return expires_in.to_i if expires_in.respond_to?(:to_i) && expires_in.to_i.positive?

          raise ArgumentError, "#{LABEL}: expires_in must be a positive Duration or number of seconds"
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
      def tokenizable_unique_value(field)
        MAX_GENERATION_ATTEMPTS.times do
          candidate = self.class.generate_tokenizable_value(field)
          return candidate unless self.class.unscoped.exists?(field => candidate)
        end

        raise "#{LABEL}: could not generate a unique value for '#{field}' " \
              "after #{MAX_GENERATION_ATTEMPTS} attempts — consider a longer length or a larger alphabet"
      end

      private

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
