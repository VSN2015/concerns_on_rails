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
    #     #                validate_state: true, verify_with: ->(rec) { Usps.verify(rec) }
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

      included do
        class_attribute :addressable_fields, instance_accessor: false, default: {}
        class_attribute :addressable_required, instance_accessor: false, default: [].freeze
        class_attribute :addressable_default_country, instance_accessor: false, default: "US"
        class_attribute :addressable_validate_state, instance_accessor: false, default: false
        class_attribute :addressable_verifier, instance_accessor: false, default: nil

        before_validation :normalize_address
        validate :validate_address
      end

      # Defined as a real module (not `class_methods do`) so the public macro and
      # its private helpers share one `private` and aren't constrained by
      # Metrics/BlockLength. ActiveSupport::Concern auto-extends `ClassMethods`.
      module ClassMethods
        include ConcernsOnRails::Support::ColumnGuard

        # Configure the address. Column overrides are passed as `part: :column`
        # keyword pairs; everything else tunes behavior. See the module docs.
        def addressable_by(required: DEFAULT_REQUIRED, default_country: "US",
                           validate_state: false, verify_with: nil, **mapping)
          self.addressable_fields = resolve_addressable_fields(mapping)
          self.addressable_required = Array(required).map(&:to_sym)
          self.addressable_default_country = default_country.to_s.upcase
          self.addressable_validate_state = validate_state
          self.addressable_verifier = verify_with
          ensure_required_columns!
        end

        private

        def resolve_addressable_fields(mapping)
          unknown = mapping.keys.map(&:to_sym) - DEFAULT_FIELDS.keys
          raise ArgumentError, "ConcernsOnRails::Models::Addressable: unknown address part(s): #{unknown.join(', ')}" if unknown.any?

          overrides = mapping.to_h { |part, column| [part.to_sym, column.to_sym] }
          ensure_columns!("ConcernsOnRails::Models::Addressable", overrides.values)
          DEFAULT_FIELDS.merge(overrides).select { |_part, column| column_names.include?(column.to_s) }
        end

        def ensure_required_columns!
          missing = addressable_required.reject { |part| addressable_fields.key?(part) }
          return if missing.empty?

          raise ArgumentError,
                "ConcernsOnRails::Models::Addressable: required address part(s) #{missing.join(', ')} " \
                "have no matching column (table: #{table_name})"
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

      # The 2-letter country code driving postal/state checks: the record's own
      # country when it's a recognized code, otherwise the configured default.
      def resolved_country
        column = self.class.addressable_fields[:country]
        value = column && self[column]
        return self.class.addressable_default_country unless value.is_a?(String)

        code = value.strip.upcase
        ConcernsOnRails::Support::AddressData.valid_country?(code) ? code : self.class.addressable_default_country
      end

      def normalize_part(part, country, value)
        squished = value.strip.squish
        case part
        when :postal_code then ConcernsOnRails::Support::AddressData.normalize_postal(country, value)
        when :country, :state then squished.length == 2 ? squished.upcase : squished
        else squished
        end
      end

      def validate_required_parts
        fields = self.class.addressable_fields
        self.class.addressable_required.each do |part|
          column = fields[part]
          errors.add(column, "can't be blank") if column && self[column].blank?
        end
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
