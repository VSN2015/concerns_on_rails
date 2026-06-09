require "active_support/concern"
require "securerandom"

module ConcernsOnRails
  module Models
    module Hashable
      extend ActiveSupport::Concern

      VALID_TYPES = %i[hex uuid integer custom].freeze

      included do
        class_attribute :hashable_field, instance_accessor: false
        class_attribute :hashable_type, instance_accessor: false, default: :hex
        class_attribute :hashable_length, instance_accessor: false, default: 16
        class_attribute :hashable_alphabet, instance_accessor: false, default: nil
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
        def hashable_by(field, type: :hex, length: 16, alphabet: nil)
          self.hashable_field = field.to_sym
          self.hashable_type = type.to_sym
          self.hashable_length = length.to_i
          self.hashable_alphabet = alphabet

          ensure_columns!("ConcernsOnRails::Models::Hashable", hashable_field)
          validate_hashable_options!
          before_create :assign_hashable_value

          define_method("regenerate_#{hashable_field}!") do
            update!(self.class.hashable_field => self.class.generate_hashable_value)
          end
        end
      end

      class_methods do
        # Generate a new random value using the configured type/length/alphabet.
        def generate_hashable_value
          case hashable_type
          when :hex     then SecureRandom.hex(hashable_length)
          when :uuid    then SecureRandom.uuid
          when :integer then SecureRandom.random_number(10**hashable_length)
          when :custom  then ConcernsOnRails::Support::RandomValue.from_alphabet(hashable_alphabet, hashable_length)
          end
        end

        private

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

        self[field] = self.class.generate_hashable_value
      end
    end
  end
end
