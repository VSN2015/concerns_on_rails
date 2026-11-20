require "active_support/concern"
require "concerns_on_rails/core"
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/encrypted_lookup"
require "concerns_on_rails/support/generated_values"
require "concerns_on_rails/support/random_value"
require "concerns_on_rails/support/unique_retry"
require "securerandom"

module ConcernsOnRails
  module Models
    # Random identifier generation for one column — hex tokens, UUIDs, numeric
    # codes or values from a custom alphabet — assigned in before_create when
    # the field is blank. `prefix:` prepends a literal (Stripe-style public
    # IDs: "ord_k7m3pq9a"), `unique:` prechecks + retries collisions, and
    # `to_param: true` makes the field the URL parameter.
    module Hashable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Models::Hashable".freeze
      VALID_TYPES = %i[hex uuid integer custom].freeze
      MAX_GENERATION_ATTEMPTS = 10

      included do
        class_attribute :hashable_field, instance_accessor: false
        class_attribute :hashable_type, instance_accessor: false, default: :hex
        class_attribute :hashable_length, instance_accessor: false, default: 16
        class_attribute :hashable_alphabet, instance_accessor: false, default: nil
        class_attribute :hashable_unique, instance_accessor: false, default: false
        class_attribute :hashable_prefix, instance_accessor: false, default: nil
        class_attribute :hashable_to_param, instance_accessor: false, default: false
        include ConcernsOnRails::Support::GeneratedValues::Revertible
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
        #   hashable_by :public_id, type: :custom, length: 14, alphabet: "abcdefghijklmnopqrstuvwxyz0123456789",
        #               prefix: "ord_", unique: true, to_param: true      # => "ord_k7m3pq9a2x5n8v" in URLs
        def hashable_by(field, type: :hex, length: 16, alphabet: nil, unique: false, prefix: nil, to_param: false)
          # Validate BEFORE assigning: a refused (and rescued) re-declaration
          # must leave the previous, working declaration in place.
          ensure_columns!("ConcernsOnRails::Models::Hashable", field.to_sym,
                          types: unique ? "string:uniq" : :string)
          options = validated_hashable_options(type: type.to_sym, length: length.to_i, alphabet: alphabet,
                                               prefix: prefix, to_param: to_param)
          self.hashable_field = field.to_sym
          self.hashable_type = options[:type]
          self.hashable_length = options[:length]
          self.hashable_alphabet = options[:alphabet]
          self.hashable_unique = unique
          self.hashable_prefix = prefix
          self.hashable_to_param = to_param

          before_create :assign_hashable_value
          # Separate from the (public, skip_callback-able) assignment so a
          # host calling assign_hashable_value itself — outside a save, in
          # after_initialize — never runs the siblings' hooks.
          before_create :hashable_report_generated_value

          # Same uniqueness handling as create-time assignment (pre-1.22 this
          # wrote one blind candidate: no `unique:` precheck, no retry when the
          # unique DB index rejected it). Each attempt runs in its own
          # savepoint: inside a caller's transaction a rejected UPDATE would
          # otherwise abort it on PostgreSQL and every retry would fail too.
          define_method("regenerate_#{hashable_field}!") do
            field = self.class.hashable_field
            ConcernsOnRails::Support::UniqueRetry.with_retries(limit: MAX_GENERATION_ATTEMPTS, savepoint: self.class) do
              value = self.class.hashable_unique ? unique_hashable_value(field) : self.class.generate_hashable_value
              update!(field => value)
            end
          end
        end
      end

      class_methods do
        # Generate a new random value using the configured type/length/alphabet,
        # with `prefix:` prepended when configured.
        def generate_hashable_value
          value = case hashable_type
                  when :hex     then SecureRandom.hex(hashable_length)
                  when :uuid    then SecureRandom.uuid
                  when :integer then hashable_fixed_width_integer
                  when :custom  then ConcernsOnRails::Support::RandomValue.from_alphabet(hashable_alphabet, hashable_length)
                  else raise ArgumentError, "#{LABEL}: unknown type '#{hashable_type}'"
                  end
          hashable_prefix ? "#{hashable_prefix}#{value}" : value
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

      module ClassMethods
        # Returns the type/length/alphabet to store (the alphabet de-duplicated);
        # reads and writes no class state, so a refusal leaves the class untouched.
        def validated_hashable_options(type:, length:, alphabet:, prefix:, to_param:)
          unless VALID_TYPES.include?(type)
            raise ArgumentError,
                  "ConcernsOnRails::Models::Hashable: unknown type '#{type}'. Valid types: #{VALID_TYPES.join(', ')}"
          end

          if %i[hex integer custom].include?(type) && !length.positive? # :uuid ignores length
            raise ArgumentError, "ConcernsOnRails::Models::Hashable: length must be a positive integer"
          end

          alphabet = validated_hashable_alphabet(alphabet) if type == :custom
          validate_hashable_extras!(type, prefix, to_param)
          { type: type, length: length, alphabet: alphabet }
        end

        # Sampling is uniform over the alphabet's POSITIONS, so a repeated
        # character is silently drawn more often ("AAB" yields A two times in
        # three) — a quiet loss of entropy. Raising would break the boot of an
        # app that shipped such an alphabet, so it is de-duplicated (removing
        # the bias) with a deprecation warning; 2.0 will raise. One distinct
        # character is a constant, not an identifier — that still raises.
        def validated_hashable_alphabet(alphabet)
          unless alphabet.is_a?(String) && !alphabet.empty?
            raise ArgumentError, "ConcernsOnRails::Models::Hashable: type :custom requires a non-empty alphabet: String"
          end

          alphabet = dedupe_hashable_alphabet(alphabet)
          return alphabet if alphabet.length >= 2

          raise ArgumentError, "#{LABEL}: alphabet needs at least 2 distinct characters"
        end

        def dedupe_hashable_alphabet(alphabet)
          duplicates = alphabet.each_char.tally.select { |_char, n| n > 1 }.keys
          return alphabet if duplicates.empty?

          ConcernsOnRails.deprecator.warn(
            "#{LABEL}: #{name || 'model'} alphabet has duplicate character(s) " \
            "#{duplicates.map(&:inspect).join(', ')}, which biased the generated values; they have been " \
            "de-duplicated. Remove them from the alphabet — this will raise in 2.0."
          )
          alphabet.each_char.to_a.uniq.join
        end

        # prefix: is a literal String prepended to string-typed values only —
        # an Integer code can't carry one; to_param: is a plain flag.
        def validate_hashable_extras!(type, prefix, to_param)
          unless prefix.nil? || prefix.is_a?(String)
            raise ArgumentError, "#{LABEL}: prefix: must be a String (got #{prefix.inspect})"
          end
          if prefix && type == :integer
            raise ArgumentError, "#{LABEL}: prefix: is not supported for type :integer (use :custom with a digit alphabet)"
          end
          unless [true, false].include?(to_param)
            raise ArgumentError, "#{LABEL}: to_param: must be true or false (got #{to_param.inspect})"
          end
          validate_hashable_to_param_conflict!(to_param)
        end

        # Sluggable pulls in friendly_id, which also overrides to_param. Which
        # one wins is decided purely by the order the two concerns are included
        # — so one of `to_param: true` and friendly URLs silently loses. Refuse
        # the ambiguity instead of letting include order decide it.
        def validate_hashable_to_param_conflict!(to_param)
          return unless to_param && respond_to?(:friendly_id_config)

          raise ArgumentError,
                "#{LABEL}: to_param: true conflicts with Sluggable/friendly_id, which also overrides to_param " \
                "(the winner would depend on include order). Drop one, or override to_param on the model yourself."
        end
      end

      # With `to_param: true` the hashed field is the URL parameter
      # (`order_path(order)` → "/orders/ord_k7m3pq9a"), falling back to Rails'
      # primary-key behaviour while the field is blank. Lookups stay explicit:
      # `Model.find_by!(field => params[:id])`.
      def to_param
        return super unless self.class.hashable_to_param

        value = self[self.class.hashable_field]
        value.present? ? value.to_s : super
      end

      # Assigns the generated value only when the field is blank,
      # so callers can still pass an explicit value at create time. Remembers
      # whether it generated, for #hashable_report_generated_value.
      def assign_hashable_value
        field = self.class.hashable_field
        @hashable_generated = false
        return if self[field].present?

        blank = self[field]
        self[field] = if self.class.hashable_unique
                        unique_hashable_value(field)
                      else
                        self.class.generate_hashable_value
                      end
        @hashable_generated = true
        @hashable_blank_value = blank
      end

      # The before_create that follows assign_hashable_value: a code generated
      # there comes after every sibling's before_validation/before_save, so it
      # is reported to the ones that derive from it — Encryptable's blind
      # index, a slug built from the code, Auditable's creation entry
      # (Support::GeneratedValues). A value the caller supplied, or one
      # assigned before the save, was already seen by them: nothing to report.
      def hashable_report_generated_value
        return unless @hashable_generated

        @hashable_generated = false
        field = self.class.hashable_field
        ConcernsOnRails::Support::GeneratedValues.remember(self, field => @hashable_blank_value)
        ConcernsOnRails::Support::GeneratedValues.assigned(self, [field])
      end
      private :hashable_report_generated_value

      # Best-effort uniqueness: retry on an in-Ruby collision before insert. Pair
      # with a unique DB index for the real guarantee (mirrors Tokenizable).
      # Checked against the STI base class: a subclass's own relation carries
      # its type condition and would miss a sibling subclass's value. An
      # encrypted field is checked through its blind index (the ciphertext
      # column never matches); one without an index cannot be checked at all.
      def unique_hashable_value(field)
        ConcernsOnRails::Models::Hashable::MAX_GENERATION_ATTEMPTS.times do
          candidate = self.class.generate_hashable_value
          condition = ConcernsOnRails::Support::EncryptedLookup.condition(self.class, field, candidate)
          return candidate if condition.nil? || !self.class.base_class.unscoped.exists?(condition)
        end
        raise "ConcernsOnRails::Models::Hashable: could not generate a unique value for '#{field}' " \
              "after #{ConcernsOnRails::Models::Hashable::MAX_GENERATION_ATTEMPTS} attempts"
      end
    end
  end
end
