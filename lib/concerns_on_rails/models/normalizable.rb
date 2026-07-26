require "active_support/concern"
require "concerns_on_rails/support/column_guard"

module ConcernsOnRails
  module Models
    # Declarative attribute normalization that runs in before_validation.
    #
    # On Rails 7.1+ you may prefer the framework-native `normalizes` macro for
    # new code; this concern provides the same ergonomics on Rails 5.0–7.0.
    module Normalizable
      extend ActiveSupport::Concern

      # Built-in normalization presets. Each is string-safe — non-string values
      # pass through unchanged so callers don't have to guard themselves.
      PRESETS = {
        email: ->(v) { v.is_a?(String) ? v.strip.downcase : v },
        phone: ->(v) { v.is_a?(String) ? v.gsub(/\D/, "") : v },
        whitespace: ->(v) { v.is_a?(String) ? v.strip : v },
        squish: ->(v) { v.is_a?(String) ? v.squish : v },
        downcase: ->(v) { v.is_a?(String) ? v.downcase : v },
        upcase: ->(v) { v.is_a?(String) ? v.upcase : v }
      }.freeze

      included do
        class_attribute :normalizable_rules, instance_accessor: false, default: {}
        before_validation :apply_normalizations
      end

      class_methods do
        include ConcernsOnRails::Support::ColumnGuard

        # Declare which fields should be normalized and how.
        # Example:
        #   normalizable :email, with: :email
        #   normalizable :first_name, :last_name, with: :whitespace
        #   normalizable :slug, with: ->(v) { v.to_s.parameterize }
        def normalizable(*fields, with:)
          raise ArgumentError, "ConcernsOnRails::Models::Normalizable: at least one field is required" if fields.empty?

          normalizer = resolve_normalizer(with)
          ensure_columns!("ConcernsOnRails::Models::Normalizable", fields)
          self.normalizable_rules = normalizable_rules.merge(fields.to_h { |f| [f.to_sym, normalizer] })
        end
      end

      class_methods do
        private

        def resolve_normalizer(with)
          case with
          when Symbol
            PRESETS.fetch(with) do
              raise ArgumentError,
                    "ConcernsOnRails::Models::Normalizable: unknown preset '#{with}'. " \
                    "Valid presets: #{PRESETS.keys.join(', ')}"
            end
          when Proc then with
          else
            raise ArgumentError,
                  "ConcernsOnRails::Models::Normalizable: :with must be a preset symbol or a Proc/lambda, got #{with.class}"
          end
        end
      end

      def apply_normalizations
        self.class.normalizable_rules.each do |field, normalizer|
          value = self[field]
          next if value.nil?
          # Persisted records: a field not part of this save already went
          # through normalization when it was written — skip it instead of
          # re-running every rule on every validation.
          next if persisted? && respond_to?(:will_save_change_to_attribute?) &&
                  !will_save_change_to_attribute?(field)

          normalized = normalizer.call(value)
          self[field] = normalized unless normalized == value
        end
      end
    end
  end
end
