require "active_support/concern"
require "concerns_on_rails/support/html_sanitizers"

module ConcernsOnRails
  module Models
    # Opt-in HTML sanitization for string attributes — defense-in-depth, NOT a
    # substitute for Rails' default output escaping.
    #
    # ESCAPE-FIRST: Rails already HTML-escapes `<%= record.body %>` via
    # SafeBuffer, so for ordinary columns you need nothing here. Reach for this
    # concern only for the rare column you render as trusted HTML
    # (`raw` / `html_safe`) or that must be kept plain text. For full
    # user-authored rich text, prefer Action Text.
    #
    #   class Article < ApplicationRecord
    #     include ConcernsOnRails::Models::Sanitizable
    #
    #     # DEFAULT (on: :read) — non-destructive. The stored column stays raw;
    #     # a `sanitized_<field>` reader returns the cleaned value:
    #     sanitizable :body, with: :safe_list           # => article.sanitized_body
    #     sanitizable :summary, with: :strip            # => article.sanitized_summary
    #     sanitizable :body, with: { tags: %w[b i a], attributes: %w[href] }
    #
    #     # EXPLICIT destructive opt-in — for plain-text-only columns only:
    #     sanitizable :title, with: :strip, on: :write  # overwrites in before_validation
    #   end
    #
    # WARNING: `on: :write` is lossy and irreversible — never use it on code,
    # Markdown, math, or anything where `<` / `>` are legitimate. It is also
    # bypassed by `update_column` / `update_all` / raw SQL, which skip
    # callbacks. The non-destructive `on: :read` default is preferred.
    #
    # Presets (the `with:` argument):
    #   :strip      — remove all tags, keep inner text (the default)
    #   :safe_list  — Rails' allow-list: keep formatting tags, drop <script> etc.
    #   :no_links   — strip only <a> tags, keep their text
    #   :none       — no-op (declare the field / reader without transforming)
    #   Array       — custom tag allow-list, e.g. with: %w[b i a]
    #   Hash        — { tags: [...], attributes: [...] } allow-list
    #   Proc        — used as-is (the caller owns the non-String guard)
    module Sanitizable
      extend ActiveSupport::Concern

      # Frozen, string-safe lambdas — non-String values pass through untouched,
      # exactly like Normalizable::PRESETS. Each resolves its sanitizer through
      # the shared Support helper (fully qualified, so there is no lexical-scope
      # dependency and libgumbo is probed once, not per access) and always
      # returns a plain String via #to_s, so a SafeBuffer is never persisted.
      PRESETS = {
        strip:     ->(v) { v.is_a?(String) ? ConcernsOnRails::Support::HtmlSanitizers.full.sanitize(v).to_s : v },
        safe_list: ->(v) { v.is_a?(String) ? ConcernsOnRails::Support::HtmlSanitizers.safe.sanitize(v).to_s : v },
        no_links:  ->(v) { v.is_a?(String) ? ConcernsOnRails::Support::HtmlSanitizers.link.sanitize(v).to_s : v },
        none:      ->(v) { v }
      }.freeze

      included do
        # field => { sanitizer: <lambda>, on: :read|:write }
        class_attribute :sanitizable_rules, instance_accessor: false, default: {}
        before_validation :apply_sanitizations
      end

      class_methods do
        include ConcernsOnRails::Support::ColumnGuard

        # Declare which string fields to sanitize, how, and when.
        #   sanitizable :body, with: :safe_list           # non-destructive reader
        #   sanitizable :title, with: :strip, on: :write  # destructive overwrite
        def sanitizable(*fields, with: :strip, on: :read)
          raise ArgumentError, "ConcernsOnRails::Models::Sanitizable: at least one field is required" if fields.empty?

          unless %i[read write].include?(on)
            raise ArgumentError,
                  "ConcernsOnRails::Models::Sanitizable: :on must be :read or :write, got #{on.inspect}"
          end

          sanitizer = resolve_sanitizer(with)
          ensure_columns!("ConcernsOnRails::Models::Sanitizable", fields)

          fields.each do |field|
            key = field.to_sym
            self.sanitizable_rules = sanitizable_rules.merge(key => { sanitizer: sanitizer, on: on })

            # Non-destructive default: a clean reader, with the raw column intact.
            define_method("sanitized_#{field}") { sanitizer.call(self[key]) } if on == :read
          end
        end
      end

      class_methods do
        private

        # Accepts a preset Symbol, a Proc (used as-is), an Array (custom tags
        # allow-list), or a Hash with :tags / :attributes.
        def resolve_sanitizer(with)
          case with
          when Symbol
            PRESETS.fetch(with) do
              raise ArgumentError,
                    "ConcernsOnRails::Models::Sanitizable: unknown preset '#{with}'. " \
                    "Valid presets: #{PRESETS.keys.join(', ')}"
            end
          when Proc then with
          when Array
            tags = with.map(&:to_s)
            ->(v) { v.is_a?(String) ? ConcernsOnRails::Support::HtmlSanitizers.safe.sanitize(v, tags: tags).to_s : v }
          when Hash
            unknown = with.keys - %i[tags attributes]
            unless unknown.empty?
              raise ArgumentError,
                    "ConcernsOnRails::Models::Sanitizable: allow-list keys must be :tags / :attributes, got #{unknown.inspect}"
            end

            tags  = with[:tags]&.map(&:to_s)
            attrs = with[:attributes]&.map(&:to_s)
            ->(v) { v.is_a?(String) ? ConcernsOnRails::Support::HtmlSanitizers.safe.sanitize(v, tags: tags, attributes: attrs).to_s : v }
          else
            raise ArgumentError,
                  "ConcernsOnRails::Models::Sanitizable: :with must be a preset symbol, an allow-list " \
                  "(Array or Hash), or a Proc/lambda, got #{with.class}"
          end
        end
      end

      # Only fields declared with on: :write are mutated; on: :read fields keep
      # their raw column value and are exposed through their sanitized_ reader.
      def apply_sanitizations
        self.class.sanitizable_rules.each do |field, rule|
          next unless rule[:on] == :write

          value = self[field]
          next if value.nil?

          self[field] = rule[:sanitizer].call(value) # plain String, never a SafeBuffer
        end
      end
    end
  end
end
