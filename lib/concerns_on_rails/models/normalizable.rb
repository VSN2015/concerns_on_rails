require "active_support/concern"
# The presets call String#squish / #titleize / #parameterize, which are
# core_ext, not part of active_support/concern. Each concern file requires
# what it uses so a direct require of this file still works.
require "active_support/core_ext/string/filters"
require "active_support/core_ext/string/inflections"
require "uri"
require "concerns_on_rails/support/column_guard"

module ConcernsOnRails
  module Models
    # Declarative attribute normalization that runs in before_validation.
    #
    #   normalizable :email,   with: :email                     # one preset
    #   normalizable :name,    with: %i[squish titleize]        # a chain, applied left to right
    #   normalizable :bio,     with: %i[squish nullify_blank]   # "" / "   " -> nil
    #   normalizable :website, with: :url                       # "Example.COM/x" -> "https://example.com/x"
    #   normalizable :slug,    with: ->(v) { v.to_s.parameterize }
    #
    #   User.normalize(:email, params[:email])   # the same rule, outside a record — for lookups
    #
    # On Rails 7.1+ you may prefer the framework-native `normalizes` macro for
    # new code; this concern provides the same ergonomics on Rails 5.0–7.0.
    module Normalizable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Models::Normalizable".freeze
      # "scheme:" — but a colon followed by a digit is a port ("localhost:3000"),
      # not a scheme, so those still get https:// prepended.
      URL_SCHEME = /\A[a-z][a-z0-9+.-]*:(?!\d)/i

      # `:url` — strip, default the scheme to https://, lowercase the scheme and
      # host (the case-insensitive parts) and leave path/query alone. Input that
      # doesn't parse as a URI comes back stripped but otherwise untouched, so a
      # format validator can still reject it.
      def self.normalize_url(value)
        stripped = value.strip
        return stripped if stripped.empty?

        uri = URI.parse(stripped.match?(URL_SCHEME) ? stripped : "https://#{stripped}")
        uri.scheme = uri.scheme.downcase
        uri.host = uri.host.downcase if uri.host
        uri.to_s
      rescue URI::InvalidURIError, URI::InvalidComponentError
        stripped
      end

      # Built-in normalization presets. Each is string-safe — non-string values
      # pass through unchanged so callers don't have to guard themselves.
      PRESETS = {
        email: ->(v) { v.is_a?(String) ? v.strip.downcase : v },
        phone: ->(v) { v.is_a?(String) ? v.gsub(/\D/, "") : v },
        whitespace: ->(v) { v.is_a?(String) ? v.strip : v },
        strip: ->(v) { v.is_a?(String) ? v.strip : v },
        squish: ->(v) { v.is_a?(String) ? v.squish : v },
        downcase: ->(v) { v.is_a?(String) ? v.downcase : v },
        upcase: ->(v) { v.is_a?(String) ? v.upcase : v },
        capitalize: ->(v) { v.is_a?(String) ? v.capitalize : v },
        titleize: ->(v) { v.is_a?(String) ? v.titleize : v },
        parameterize: ->(v) { v.is_a?(String) ? v.parameterize : v },
        nullify_blank: ->(v) { v.is_a?(String) && v.strip.empty? ? nil : v },
        url: ->(v) { v.is_a?(String) ? Normalizable.normalize_url(v) : v }
      }.freeze

      included do
        class_attribute :normalizable_rules, instance_accessor: false, default: {}
        before_validation :apply_normalizations
      end

      class_methods do
        include ConcernsOnRails::Support::ColumnGuard

        # Declare which fields should be normalized and how. `with:` is a preset
        # Symbol, a Proc, or an Array of those applied in order.
        # Example:
        #   normalizable :email, with: :email
        #   normalizable :first_name, :last_name, with: :whitespace
        #   normalizable :name, with: %i[squish titleize]
        #   normalizable :slug, with: ->(v) { v.to_s.parameterize }
        def normalizable(*fields, with:)
          raise ArgumentError, "#{LABEL}: at least one field is required" if fields.empty?

          normalizer = resolve_normalizer(with)
          ensure_columns!(LABEL, fields)
          self.normalizable_rules = normalizable_rules.merge(fields.to_h { |f| [f.to_sym, normalizer] })
        end

        # Run a field's rule on a bare value — the same transform the record
        # applies, for lookups and params:
        #   User.find_by(email: User.normalize(:email, params[:email]))
        # nil stays nil (records skip nil too); an undeclared field raises.
        def normalize(field, value)
          normalizer = normalizable_rules[field.to_sym]
          unless normalizer
            raise ArgumentError,
                  "#{LABEL}: no normalization rule for #{field.to_sym.inspect} (declared: #{normalizable_rules.keys.join(', ')})"
          end

          value.nil? ? nil : normalizer.call(value)
        end
      end

      module ClassMethods
        private

        # An Array composes: each step receives the previous step's output.
        def resolve_normalizer_chain(with)
          raise ArgumentError, "#{LABEL}: with: [] needs at least one normalizer" if with.empty?

          steps = with.map { |step| resolve_normalizer(step) }
          ->(v) { steps.reduce(v) { |memo, step| step.call(memo) } }
        end

        def resolve_normalizer(with)
          case with
          when Array then resolve_normalizer_chain(with)
          when Symbol
            PRESETS.fetch(with) do
              raise ArgumentError, "#{LABEL}: unknown preset '#{with}'. Valid presets: #{PRESETS.keys.join(', ')}"
            end
          when Proc then with
          else
            raise ArgumentError, "#{LABEL}: :with must be a preset symbol or a Proc/lambda (or an Array of them), got #{with.class}"
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
