require "active_support/concern"
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
    #     tokenizable_by :reset_password_token, length: 24
    #     tokenizable_by :invite_code, type: :alphanumeric, length: 8
    #   end
    #
    #   user = User.create!                       # tokens auto-generated on create
    #   user.regenerate_api_token!                # new value, persisted
    #   user.revoke_api_token!                    # sets the column to nil
    #   user.api_token?                           # true if present
    #
    #   User.find_by_api_token(token)             # Rails default
    #   User.authenticate_by_api_token(token)     # timing-safe lookup, returns record or nil
    #
    # Unlike Hashable, one model can declare multiple token fields, generation is
    # URL-safe by default, and `assign_tokenizable_value` retries on uniqueness
    # collisions before insert (best-effort; pair with a unique DB index).
    module Tokenizable
      extend ActiveSupport::Concern

      VALID_TYPES = %i[urlsafe hex alphanumeric numeric].freeze
      ALPHANUMERIC_ALPHABET = (("A".."Z").to_a + ("a".."z").to_a + ("0".."9").to_a).freeze
      NUMERIC_ALPHABET = ("0".."9").to_a.freeze
      MAX_GENERATION_ATTEMPTS = 10

      included do
        class_attribute :tokenizable_fields, instance_accessor: false, default: {}
      end

      class_methods do
        # Configure a tokenizable field.
        #
        # Options:
        #   type:   one of :urlsafe (default), :hex, :alphanumeric, :numeric
        #   length: character length of the generated token (default 32)
        def tokenizable_by(field, type: :urlsafe, length: 32)
          field = field.to_sym
          type = type.to_sym
          length = length.to_i

          validate_tokenizable_options!(field, type, length)

          # Build a fresh hash so subclasses don't mutate the parent's config.
          self.tokenizable_fields = tokenizable_fields.merge(field => { type: type, length: length })

          before_create -> { assign_tokenizable_value(field) }

          define_method("regenerate_#{field}!") do
            update!(field => self.class.generate_tokenizable_value(field))
          end

          define_method("revoke_#{field}!") do
            update!(field => nil)
          end

          define_method("#{field}?") do
            self[field].present?
          end

          define_singleton_method("authenticate_by_#{field}") do |value|
            return nil if value.blank?

            candidate = find_by(field => value)
            return nil unless candidate

            stored = candidate[field].to_s
            given = value.to_s
            return nil unless stored.bytesize == given.bytesize

            ActiveSupport::SecurityUtils.secure_compare(stored, given) ? candidate : nil
          end
        end

        # Generate a new random value for the given field using its configured type/length.
        def generate_tokenizable_value(field)
          config = tokenizable_fields.fetch(field) do
            raise ArgumentError, "ConcernsOnRails::Models::Tokenizable: '#{field}' is not a tokenizable field"
          end

          length = config[:length]

          case config[:type]
          when :urlsafe      then SecureRandom.urlsafe_base64(length)[0, length]
          when :hex          then SecureRandom.hex((length + 1) / 2)[0, length]
          when :alphanumeric then random_string_from_alphabet(ALPHANUMERIC_ALPHABET, length)
          when :numeric      then random_string_from_alphabet(NUMERIC_ALPHABET, length)
          end
        end

        private

        def validate_tokenizable_options!(field, type, length)
          unless column_names.include?(field.to_s)
            raise ArgumentError,
                  "ConcernsOnRails::Models::Tokenizable: tokenizable field '#{field}' does not exist in the database"
          end

          unless VALID_TYPES.include?(type)
            raise ArgumentError,
                  "ConcernsOnRails::Models::Tokenizable: unknown type '#{type}'. Valid types: #{VALID_TYPES.join(', ')}"
          end

          return if length.positive?

          raise ArgumentError, "ConcernsOnRails::Models::Tokenizable: length must be a positive integer"
        end

        def random_string_from_alphabet(alphabet, length)
          Array.new(length) { alphabet[SecureRandom.random_number(alphabet.size)] }.join
        end
      end

      # Assigns the generated value only when blank, so callers can pass an explicit one.
      # Retries up to MAX_GENERATION_ATTEMPTS times if the in-Ruby uniqueness check hits a
      # collision — useful for short codes; a unique DB index is still the real guarantee.
      def assign_tokenizable_value(field)
        return if self[field].present?

        MAX_GENERATION_ATTEMPTS.times do
          candidate = self.class.generate_tokenizable_value(field)
          unless self.class.unscoped.exists?(field => candidate)
            self[field] = candidate
            return
          end
        end

        raise "ConcernsOnRails::Models::Tokenizable: could not generate a unique value for '#{field}' " \
              "after #{MAX_GENERATION_ATTEMPTS} attempts — consider a longer length or a larger alphabet"
      end
    end
  end
end
