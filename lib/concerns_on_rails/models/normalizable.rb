require "active_support/concern"
# The presets call String#squish / #parameterize, which are core_ext, not
# part of active_support/concern. Each concern file requires what it uses so
# a direct require of this file still works.
require "active_support/core_ext/string/filters"
require "active_support/core_ext/string/inflections"
require "uri"
require "concerns_on_rails/support/column_guard"

module ConcernsOnRails
  module Models
    # Declarative attribute normalization that runs in before_validation (and,
    # as a backstop, in before_save for saves that skip validation).
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
      # "scheme:" — but a colon followed by a port number is "host:port"
      # ("localhost:3000"), not a scheme, so those still get https:// prepended.
      # A longer digit run is no port, so "tel:14155551234" reads as a scheme.
      URL_SCHEME = %r{\A([a-z][a-z0-9+.-]*):(?!\d{1,5}(?:[/?#]|\z))}i
      # The only schemes `:url` canonicalizes. Anything else — "javascript:",
      # "data:", "mailto:", "tel:" — comes back stripped but otherwise untouched:
      # rewriting it would bless it as a normalized URL, and `link_to` renders
      # whichever scheme it is handed.
      URL_SCHEMES = %w[http https].freeze
      # A `:titleize` word: a run of letters that starts one, so the tail of
      # "3rd" or "O'Brien" keeps the case it was typed with. Capitalizing these
      # in place is what String#titleize is mistaken for — that is
      # humanize(underscore(v)), which rewrites "Jean-Luc" to "Jean Luc" and
      # drops the suffix of "customer_id" outright.
      TITLEIZE_WORD = /(?<![[:alnum:]'])[[:alpha:]]+/
      # Leading/trailing Unicode whitespace (plus NUL, which String#strip also
      # removed), for the stripping presets.
      EDGE_SPACE = /\A[[:space:]\0]+|[[:space:]\0]+\z/

      # `:url` — strip, default the scheme to https://, lowercase the scheme and
      # host (the case-insensitive parts) and leave path/query alone. Input that
      # carries a non-http(s) scheme, or that doesn't parse as a URI, comes back
      # stripped but otherwise untouched, so a format validator can reject it.
      def self.normalize_url(value)
        stripped = strip(value)
        return stripped if stripped.empty?

        scheme = stripped[URL_SCHEME, 1]
        return stripped if scheme && !URL_SCHEMES.include?(scheme.downcase)

        uri = URI.parse(scheme ? stripped : "https://#{stripped}")
        uri.scheme = uri.scheme.downcase
        downcase_host!(uri)
        uri.to_s
      rescue URI::InvalidURIError, URI::InvalidComponentError
        stripped
      end

      # String#strip only removes ASCII whitespace (and NUL): a pasted no-break
      # space, em space or ideographic space survived it. Strip every
      # Unicode space from both ends instead (String#squish already collapses
      # [[:space:]]); :nullify_blank uses it too, so a value of nothing but
      # no-break spaces is blank.
      def self.strip(value)
        value.gsub(EDGE_SPACE, "")
      end

      # `host=` also clears the userinfo on uri >= 1.1 (Ruby 3.2's bundled
      # uri 0.12.1 keeps it), so put it back — silently dropping credentials
      # would leave the stored URL pointing somewhere else entirely.
      def self.downcase_host!(uri)
        return unless uri.host

        userinfo = uri.userinfo
        uri.host = uri.host.downcase
        uri.userinfo = userinfo if userinfo
      end
      private_class_method :downcase_host!

      # Built-in normalization presets. Each is string-safe — non-string values
      # pass through unchanged so callers don't have to guard themselves.
      PRESETS = {
        email: ->(v) { v.is_a?(String) ? Normalizable.strip(v).downcase : v },
        phone: ->(v) { v.is_a?(String) ? v.gsub(/\D/, "") : v },
        whitespace: ->(v) { v.is_a?(String) ? Normalizable.strip(v) : v },
        strip: ->(v) { v.is_a?(String) ? Normalizable.strip(v) : v },
        squish: ->(v) { v.is_a?(String) ? v.squish : v },
        downcase: ->(v) { v.is_a?(String) ? v.downcase : v },
        upcase: ->(v) { v.is_a?(String) ? v.upcase : v },
        capitalize: ->(v) { v.is_a?(String) ? v.capitalize : v },
        titleize: ->(v) { v.is_a?(String) ? v.gsub(TITLEIZE_WORD, &:capitalize) : v },
        parameterize: ->(v) { v.is_a?(String) ? v.parameterize : v },
        nullify_blank: ->(v) { v.is_a?(String) && Normalizable.strip(v).empty? ? nil : v },
        url: ->(v) { v.is_a?(String) ? Normalizable.normalize_url(v) : v }
      }.freeze

      included do
        class_attribute :normalizable_rules, instance_accessor: false, default: {}
        before_validation :apply_normalizations
        # Backstop for the saves that skip validation — update_attribute,
        # save(validate: false) — which otherwise stored the raw value.
        before_save :normalizable_apply_unvalidated
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
        # field => the value this pass left it holding, so the before_save
        # backstop can tell "already normalized" from "changed since".
        @normalizable_applied = {}
        normalizable_each_pending_rule do |field, normalizer, value|
          normalized = normalizer.call(value)
          self[field] = normalized unless normalized == value
          @normalizable_applied[field] = self[field]
        end
      end

      private

      # Normalize only what before_validation did not: a field it already
      # handled, still holding the value it produced, is skipped, so a
      # non-idempotent Proc runs exactly once in a validated save. A field
      # assigned after that validation (or never validated at all) is
      # normalized here. The record is cleared for the next save.
      def normalizable_apply_unvalidated
        applied = @normalizable_applied || {}
        @normalizable_applied = nil
        normalizable_each_pending_rule do |field, normalizer, value|
          next if applied.key?(field) && applied[field] == value

          normalized = normalizer.call(value)
          self[field] = normalized unless normalized == value
        end
      end

      def normalizable_each_pending_rule
        self.class.normalizable_rules.each do |field, normalizer|
          # A partial `select` load lacks the column: reading it would raise
          # MissingAttributeError, and there is nothing to normalize.
          next unless has_attribute?(field)

          value = self[field]
          next if value.nil?
          # Persisted records: a field not part of this save already went
          # through normalization when it was written — skip it instead of
          # re-running every rule on every validation.
          next if persisted? && respond_to?(:will_save_change_to_attribute?) &&
                  !will_save_change_to_attribute?(field)

          yield field, normalizer, value
        end
      end
    end
  end
end
