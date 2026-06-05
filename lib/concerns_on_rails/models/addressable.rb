require "active_support/concern"

module ConcernsOnRails
  module Models
    # Declarative normalization + format validation for a postal address spread
    # across several columns. One macro wires up whitespace cleanup, postal-code
    # and ISO country-code checks, required-part presence, and a `full_address`
    # helper — no external geocoding service required.
    #
    #   class Location < ApplicationRecord
    #     include ConcernsOnRails::Addressable
    #
    #     addressable_by                      # standard line1/line2/city/state/postal_code/country columns
    #     # addressable_by line1: :street, postal_code: :zip, country: :country_code,
    #     #                required: %i[line1 city postal_code], default_country: "GB",
    #     #                validate_state: true, verify_with: ->(rec) { Usps.verify(rec) },
    #     #                lengths: { line1: 100, postal_code: 5..10 }, allow_blank: %i[state],
    #     #                normalize_country: true,  # "Canada"/"CAN" -> "CA"
    #     #                if: :on_addresses?        # Rails-style condition gating the validations
    #   end
    #
    # Scope is *format/structure* only — it checks shape, not real-world
    # deliverability. Layer a real verifier on via `verify_with:`. Relates to
    # the per-field Normalizable concern.
    module Addressable
      extend ActiveSupport::Concern

      # Canonical address part => default column name.
      DEFAULT_FIELDS = {
        line1: :line1, line2: :line2, city: :city,
        state: :state, postal_code: :postal_code, country: :country
      }.freeze

      # Parts required by default (each must map to an existing column).
      DEFAULT_REQUIRED = %i[line1 city postal_code country].freeze

      # Prefix for the ArgumentErrors raised during configuration.
      LABEL = "ConcernsOnRails::Models::Addressable".freeze

      included do
        class_attribute :addressable_fields, instance_accessor: false, default: {}
        class_attribute :addressable_required, instance_accessor: false, default: [].freeze
        class_attribute :addressable_default_country, instance_accessor: false, default: "US"
        class_attribute :addressable_validate_state, instance_accessor: false, default: false
        class_attribute :addressable_verifier, instance_accessor: false, default: nil
        class_attribute :addressable_lengths, instance_accessor: false, default: {}
        class_attribute :addressable_allow_blank, instance_accessor: false, default: [].freeze
        class_attribute :addressable_normalize_country, instance_accessor: false, default: false
        class_attribute :addressable_validation_registered, instance_accessor: false, default: false

        # `validate :validate_address` is registered by `addressable_by` (not here) so it can
        # carry the optional if:/unless: condition. Normalization always runs.
        before_validation :normalize_address
      end

      # Defined as a real module (not `class_methods do`) so the public macro and
      # its private helpers share one `private` and aren't constrained by
      # Metrics/BlockLength. ActiveSupport::Concern auto-extends `ClassMethods`.
      module ClassMethods
        include ConcernsOnRails::Support::ColumnGuard

        # Configure the address. Column overrides are passed as `part: :column`
        # keyword pairs; everything else tunes behavior. See the module docs.
        def addressable_by(required: DEFAULT_REQUIRED, default_country: "US",
                           validate_state: false, verify_with: nil,
                           lengths: {}, allow_blank: false, normalize_country: false, **mapping)
          condition = extract_validation_condition!(mapping)
          self.addressable_fields = resolve_addressable_fields(mapping)
          self.addressable_required = Array(required).map(&:to_sym)
          self.addressable_default_country = default_country.to_s.upcase
          self.addressable_validate_state = validate_state
          self.addressable_verifier = verify_with
          self.addressable_lengths = resolve_lengths(lengths)
          self.addressable_allow_blank = resolve_allow_blank(allow_blank)
          self.addressable_normalize_country = normalize_country
          ensure_required_columns!
          register_address_validation(condition)
        end

        private

        def resolve_addressable_fields(mapping)
          unknown = mapping.keys.map(&:to_sym) - DEFAULT_FIELDS.keys
          raise ArgumentError, "#{LABEL}: unknown address part(s): #{unknown.join(', ')}" if unknown.any?

          overrides = mapping.to_h { |part, column| [part.to_sym, column.to_sym] }
          ensure_columns!(LABEL, overrides.values)
          DEFAULT_FIELDS.merge(overrides).select { |_part, column| column_names.include?(column.to_s) }
        end

        def ensure_required_columns!
          missing = addressable_required.reject { |part| addressable_fields.key?(part) }
          return if missing.empty?

          raise ArgumentError,
                "#{LABEL}: required address part(s) #{missing.join(', ')} " \
                "have no matching column (table: #{table_name})"
        end

        # Normalize the lengths: option into { part => [min, max] }, where min
        # defaults to 0 and max to Infinity so the validator needs no nil guards.
        def resolve_lengths(lengths)
          raise ArgumentError, "#{LABEL}: lengths: must be a Hash (part => Integer or Range)" unless lengths.is_a?(Hash)

          lengths.to_h do |part, bound|
            sym = part.to_sym
            raise ArgumentError, "#{LABEL}: unknown address part in lengths: #{sym}" unless DEFAULT_FIELDS.key?(sym)

            [sym, normalize_length_bound(sym, bound)]
          end
        end

        def normalize_length_bound(part, bound)
          case bound
          when Integer
            raise ArgumentError, "#{LABEL}: lengths[#{part}] must be a positive Integer" unless bound.positive?

            [0, bound]
          when Range then range_bounds(part, bound)
          else
            raise ArgumentError, "#{LABEL}: lengths[#{part}] must be an Integer or Range, got #{bound.class}"
          end
        end

        # A Range becomes [min, max] (min defaults to 0, an open end becomes
        # Infinity). Bounds must be non-negative Integers and the range must be
        # satisfiable (min <= max) — otherwise a typo would silently brick a column.
        def range_bounds(part, range)
          min = range.begin || 0
          max = range.end
          validate_range_endpoints!(part, min, max)
          max -= 1 if max && range.exclude_end?
          max ||= Float::INFINITY
          raise ArgumentError, "#{LABEL}: lengths[#{part}] range is empty or inverted (#{range})" if min > max

          [min, max]
        end

        def validate_range_endpoints!(part, min, max)
          return if min.is_a?(Integer) && !min.negative? && (max.nil? || (max.is_a?(Integer) && !max.negative?))

          raise ArgumentError, "#{LABEL}: lengths[#{part}] range must have non-negative Integer bounds"
        end

        # Normalize allow_blank: into the list of parts whose length check is skipped when blank.
        def resolve_allow_blank(allow_blank)
          case allow_blank
          when true then DEFAULT_FIELDS.keys
          when false, nil then []
          when Array
            parts = allow_blank.map(&:to_sym)
            unknown = parts - DEFAULT_FIELDS.keys
            raise ArgumentError, "#{LABEL}: unknown address part(s) in allow_blank: #{unknown.join(', ')}" if unknown.any?

            parts
          else
            raise ArgumentError, "#{LABEL}: allow_blank: must be true, false, or an Array of parts"
          end
        end

        # Pull Rails-style `if:` / `unless:` out of the keyword args (they ride in via
        # **mapping) so the remaining keys are treated as column overrides.
        def extract_validation_condition!(mapping)
          { if: mapping.delete(:if), unless: mapping.delete(:unless) }.compact
        end

        # Register `validate :validate_address` once, forwarding any if:/unless: condition
        # straight to Rails so it behaves like a normal conditional validation. Normalization
        # (before_validation) is unconditional; the condition only gates the validations.
        def register_address_validation(condition)
          return if addressable_validation_registered

          self.addressable_validation_registered = true
          validate :validate_address, **condition
        end
      end

      # --- Normalization (before_validation) ------------------------------------

      def normalize_address
        country = resolved_country
        self.class.addressable_fields.each do |part, column|
          value = self[column]
          next unless value.is_a?(String)

          self[column] = normalize_part(part, country, value)
        end
      end

      # --- Validation -----------------------------------------------------------

      def validate_address
        validate_required_parts
        validate_lengths
        validate_country_code
        validate_postal_code
        validate_state_code if self.class.addressable_validate_state
        run_address_verifier if self.class.addressable_verifier && errors.empty?
      end

      # --- Public helpers -------------------------------------------------------

      # The present parts joined into a single line, in canonical order.
      def full_address(separator: ", ")
        address_lines.join(separator)
      end

      # The present parts as an ordered array (handy for multi-line rendering).
      def address_lines
        ordered_parts.filter_map { |part| self[self.class.addressable_fields[part]].presence }
      end

      # True when any configured part has a value.
      def address_present?
        ordered_parts.any? { |part| self[self.class.addressable_fields[part]].present? }
      end

      # True when every required part has a value (presence only, no format check).
      def address_complete?
        self.class.addressable_required.all? do |part|
          (column = self.class.addressable_fields[part]) && self[column].present?
        end
      end

      # `{ part => value }` for the present parts (handy for serializers / verifiers).
      def address_attributes
        self.class.addressable_fields.each_with_object({}) do |(part, column), acc|
          value = self[column]
          acc[part] = value if value.present?
        end
      end

      private

      def ordered_parts
        DEFAULT_FIELDS.keys.select { |part| self.class.addressable_fields.key?(part) }
      end

      # The country driving postal-/state-format selection:
      #   * the record's own country when it's a recognized ISO alpha-2 code
      #   * the configured default_country when the country column is absent or blank
      #   * nil ("unknown") when a country is present but unrecognized — so postal/state
      #     fall back to permissive checks instead of wrongly applying the default's rules
      def resolved_country
        column = self.class.addressable_fields[:country]
        value = column && self[column]
        return self.class.addressable_default_country if value.blank?

        code = canonical_country_code(value)
        ConcernsOnRails::Support::AddressData.valid_country?(code) ? code : nil
      end

      # The country value as an alpha-2 candidate, applying name/alpha-3 mapping
      # when normalize_country is on so postal/state checks recognize it too.
      def canonical_country_code(value)
        return ConcernsOnRails::Support::AddressData.normalize_country_code(value).to_s.upcase if self.class.addressable_normalize_country

        value.to_s.strip.upcase
      end

      def normalize_part(part, country, value)
        squished = value.strip.squish
        case part
        when :postal_code then ConcernsOnRails::Support::AddressData.normalize_postal(country, value)
        when :country then normalize_country_part(squished)
        when :state then squished.length == 2 ? squished.upcase : squished
        else squished
        end
      end

      # With normalize_country on, map a name/alpha-3 to its alpha-2 (leaving an
      # unrecognized value untouched); otherwise just upcase a bare 2-letter code.
      def normalize_country_part(squished)
        return ConcernsOnRails::Support::AddressData.normalize_country_code(squished) if self.class.addressable_normalize_country

        squished.length == 2 ? squished.upcase : squished
      end

      def validate_required_parts
        fields = self.class.addressable_fields
        self.class.addressable_required.each do |part|
          column = fields[part]
          errors.add(column, "can't be blank") if column && self[column].blank?
        end
      end

      def validate_lengths
        self.class.addressable_lengths.each { |part, bounds| validate_length_of(part, bounds) }
      end

      # Enforce one part's [min, max] bounds. A blank value skips the check only
      # when the part is in allow_blank; otherwise the minimum is enforced on blanks
      # (independent of required:). Length is measured on the normalized value.
      def validate_length_of(part, (min, max))
        column = self.class.addressable_fields[part]
        return unless column

        value = self[column]
        return if value.blank? && self.class.addressable_allow_blank.include?(part)

        length = value.to_s.length
        errors.add(column, "is too short (minimum is #{length_phrase(min)})") if length < min
        errors.add(column, "is too long (maximum is #{length_phrase(max)})") if length > max
      end

      # "1 character" / "N characters" — mirrors Rails' pluralized length errors
      # without depending on i18n. (max is only interpolated for finite bounds.)
      def length_phrase(count)
        "#{count} #{count == 1 ? 'character' : 'characters'}"
      end

      def validate_country_code
        column = self.class.addressable_fields[:country]
        value = column && self[column]
        return unless value.is_a?(String) && value.length == 2
        return if ConcernsOnRails::Support::AddressData.valid_country?(value)

        errors.add(column, "is not a valid ISO 3166-1 country code")
      end

      def validate_postal_code
        column = self.class.addressable_fields[:postal_code]
        value = column && self[column]
        return if value.blank?

        format = ConcernsOnRails::Support::AddressData.postal_format_for(resolved_country)
        errors.add(column, "is not a valid postal code") unless value.to_s.match?(format)
      end

      def validate_state_code
        column = self.class.addressable_fields[:state]
        value = column && self[column]
        return if value.blank?
        return if ConcernsOnRails::Support::AddressData.valid_state?(resolved_country, value)

        errors.add(column, "is not a valid state/province")
      end

      def run_address_verifier
        apply_verifier_result(self.class.addressable_verifier.call(self))
      end

      def apply_verifier_result(result)
        case result
        when false then errors.add(:base, "address could not be verified")
        when String then errors.add(:base, result)
        when Array then result.each { |message| errors.add(:base, message) }
        end
      end
    end
  end
end
