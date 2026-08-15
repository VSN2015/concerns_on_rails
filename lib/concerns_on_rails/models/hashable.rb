require "active_support/concern"
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/random_value"
require "concerns_on_rails/support/unique_retry"
require "securerandom"

module ConcernsOnRails
  module Models
    module Hashable
      extend ActiveSupport::Concern

      VALID_TYPES = %i[hex uuid integer custom].freeze
      MAX_GENERATION_ATTEMPTS = 10

      included do
        class_attribute :hashable_field, instance_accessor: false
        class_attribute :hashable_type, instance_accessor: false, default: :hex
        class_attribute :hashable_length, instance_accessor: false, default: 16
        class_attribute :hashable_alphabet, instance_accessor: false, default: nil
        class_attribute :hashable_unique, instance_accessor: false, default: false
      end

      class_methods do
        include ConcernsOnRails::Support::ColumnGuard

        # Define hashable field and generation options.
        # Example:
        #   hashable_by :token
        #   hashable_by :token, type: :hex, length: 16
        #   hashable_by :external_id, type: :uuid
        #   hashable_by :code, type: :integer, length: 6
        #   hashable_by :code, type: :custom, length: 8, alphabet: "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
        def hashable_by(field, type: :hex, length: 16, alphabet: nil, unique: false)
          self.hashable_field = field.to_sym
          self.hashable_type = type.to_sym
          self.hashable_length = length.to_i
          self.hashable_alphabet = alphabet
          self.hashable_unique = unique

          ensure_columns!("ConcernsOnRails::Models::Hashable", hashable_field,
                          types: hashable_unique ? "string:uniq" : :string)
          validate_hashable_options!
          before_create :assign_hashable_value

          # Same uniqueness handling as create-time assignment (pre-1.22 this
          # wrote one blind candidate: no `unique:` precheck, no retry when the
          # unique DB index rejected it).
          define_method("regenerate_#{hashable_field}!") do
            field = self.class.hashable_field
            ConcernsOnRails::Support::UniqueRetry.with_retries(limit: MAX_GENERATION_ATTEMPTS) do
              value = self.class.hashable_unique ? unique_hashable_value(field) : self.class.generate_hashable_value
              update!(field => value)
            end
          end
        end
      end

      class_methods do
        # Generate a new random value using the configured type/length/alphabet.
        def generate_hashable_value
          case hashable_type
          when :hex     then SecureRandom.hex(hashable_length)
          when :uuid    then SecureRandom.uuid
          when :integer then hashable_fixed_width_integer
          when :custom  then ConcernsOnRails::Support::RandomValue.from_alphabet(hashable_alphabet, hashable_length)
          end
        end

        private

        # Fixed width: draw from [10^(n-1), 10^n) so a `length: 6` code is
        # always 6 digits — SecureRandom.random_number(10**6) alone can return
        # e.g. 4213. length: 1 keeps the full 0-9 range.
        def hashable_fixed_width_integer
          min = hashable_length == 1 ? 0 : 10**(hashable_length - 1)
          SecureRandom.random_number((10**hashable_length) - min) + min
        end
      end

      class_methods do
        def validate_hashable_options!
          unless VALID_TYPES.include?(hashable_type)
            raise ArgumentError,
                  "ConcernsOnRails::Models::Hashable: unknown type '#{hashable_type}'. Valid types: #{VALID_TYPES.join(', ')}"
          end

          if length_bearing_hashable_type? && !hashable_length.positive?
            raise ArgumentError, "ConcernsOnRails::Models::Hashable: length must be a positive integer"
          end

          return unless hashable_type == :custom && (!hashable_alphabet.is_a?(String) || hashable_alphabet.empty?)

          raise ArgumentError, "ConcernsOnRails::Models::Hashable: type :custom requires a non-empty alphabet: String"
        end

        # :uuid ignores length; the others derive their size from it.
        def length_bearing_hashable_type?
          %i[hex integer custom].include?(hashable_type)
        end
      end

      # Assigns the generated value only when the field is blank,
      # so callers can still pass an explicit value at create time.
      def assign_hashable_value
        field = self.class.hashable_field
        return if self[field].present?

        self[field] = if self.class.hashable_unique
                        unique_hashable_value(field)
                      else
                        self.class.generate_hashable_value
                      end
      end

      # Best-effort uniqueness: retry on an in-Ruby collision before insert. Pair
      # with a unique DB index for the real guarantee (mirrors Tokenizable).
      def unique_hashable_value(field)
        ConcernsOnRails::Models::Hashable::MAX_GENERATION_ATTEMPTS.times do
          candidate = self.class.generate_hashable_value
          return candidate unless self.class.unscoped.exists?(field => candidate)
        end
        raise "ConcernsOnRails::Models::Hashable: could not generate a unique value for '#{field}' " \
              "after #{ConcernsOnRails::Models::Hashable::MAX_GENERATION_ATTEMPTS} attempts"
      end
    end
  end
end
