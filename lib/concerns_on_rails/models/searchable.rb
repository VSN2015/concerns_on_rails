require "active_support/concern"

module ConcernsOnRails
  module Models
    # LIKE-based search across one or more columns.
    #
    #   class Article < ApplicationRecord
    #     include ConcernsOnRails::Searchable
    #
    #     searchable_by :title, :body                                  # defaults below
    #     searchable_by :title, :body, mode: :all                      # every term must match
    #     searchable_by :sku,         match: :prefix                   # "abc" -> "abc%"
    #     searchable_by :code,        match: :exact, case_sensitive: true
    #   end
    #
    #   Article.search("hello")            # WHERE title ILIKE '%hello%' OR body ILIKE '%hello%'
    #   Article.search("")                 # no-op — returns the full relation
    #   Article.search("foo").where(...)   # chainable like any scope
    #
    # Options (all optional; the defaults reproduce a single-term, case-insensitive
    # "contains" search across the given columns):
    #   mode:           :any (default) treats the whole query as one term;
    #                   :all splits on whitespace and requires every term to match.
    #   match:          :contains (default, "%q%"), :prefix ("q%"), or :exact ("q").
    #   case_sensitive: false (default) emits ILIKE on Postgres; true emits LIKE.
    #
    # Uses Arel's `matches`. The query is escaped before interpolation, so
    # `%` / `_` / `\` from user input are treated as literals.
    module Searchable
      extend ActiveSupport::Concern

      LIKE_ESCAPE = "\\".freeze
      LIKE_SPECIAL = /[\\%_]/
      VALID_MODES = %i[any all].freeze
      VALID_MATCHES = %i[contains prefix exact].freeze

      included do
        class_attribute :searchable_fields, instance_accessor: false, default: []
        class_attribute :searchable_mode, instance_accessor: false, default: :any
        class_attribute :searchable_match, instance_accessor: false, default: :contains
        class_attribute :searchable_case_sensitive, instance_accessor: false, default: false
      end

      class_methods do
        include ConcernsOnRails::Support::ColumnGuard

        def searchable_by(*fields, mode: :any, match: :contains, case_sensitive: false)
          raise ArgumentError, "ConcernsOnRails::Models::Searchable: at least one field is required" if fields.empty?

          ensure_columns!("ConcernsOnRails::Models::Searchable", fields)
          validate_search_options!(mode, match)

          self.searchable_fields = fields.map(&:to_sym)
          self.searchable_mode = mode.to_sym
          self.searchable_match = match.to_sym
          self.searchable_case_sensitive = case_sensitive

          scope :search, ->(query) { search_relation(query) }
        end

        def search_relation(query)
          return all if query.nil? || query.to_s.strip.empty?

          terms = searchable_mode == :all ? query.to_s.split : [query.to_s]
          terms.reduce(all) { |relation, term| relation.where(search_term_predicate(term)) }
        end
      end

      class_methods do
        private

        # OR the per-field LIKE predicate for a single term.
        def search_term_predicate(term)
          pattern = search_like_pattern(term)
          predicates = searchable_fields.map do |field|
            arel_table[field].matches(pattern, LIKE_ESCAPE, searchable_case_sensitive)
          end
          predicates.reduce { |memo, predicate| memo.or(predicate) }
        end

        def search_like_pattern(term)
          escaped = term.to_s.gsub(LIKE_SPECIAL) { |char| "#{LIKE_ESCAPE}#{char}" }
          case searchable_match
          when :prefix then "#{escaped}%"
          when :exact  then escaped
          else "%#{escaped}%"
          end
        end

        def validate_search_options!(mode, match)
          unless VALID_MODES.include?(mode.to_sym)
            raise ArgumentError, "ConcernsOnRails::Models::Searchable: unknown mode '#{mode}'. Valid modes: #{VALID_MODES.join(', ')}"
          end
          return if VALID_MATCHES.include?(match.to_sym)

          raise ArgumentError, "ConcernsOnRails::Models::Searchable: unknown match '#{match}'. Valid matches: #{VALID_MATCHES.join(', ')}"
        end
      end
    end
  end
end
