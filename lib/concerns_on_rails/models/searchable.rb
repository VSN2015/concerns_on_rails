require "active_support/concern"
require "concerns_on_rails/support/column_guard"

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
    #     searchable_by :title, :body, ranked: true                    # best matches first
    #   end
    #
    #   Article.search("hello")            # WHERE title ILIKE '%hello%' OR body ILIKE '%hello%'
    #   Article.search("")                 # no-op — returns the full relation
    #   Article.search("foo").where(...)   # chainable like any scope
    #   Article.search("foo", ranked: true) # per-call ranking override
    #
    # Options (all optional; the defaults reproduce a single-term, case-insensitive
    # "contains" search across the given columns):
    #   mode:           :any (default) treats the whole query as one term;
    #                   :all splits on whitespace and requires every term to match.
    #   match:          :contains (default, "%q%"), :prefix ("q%"), or :exact ("q").
    #   case_sensitive: false (default) emits ILIKE on Postgres; true emits LIKE.
    #                   NOTE: this only affects Postgres. On MySQL/SQLite, LIKE
    #                   case sensitivity is governed by the column collation, so
    #                   the flag is effectively a no-op there.
    #   ranked:         false (default). true orders results by relevance: exact
    #                   matches, then prefix matches, then substring matches, and
    #                   within a tier the earlier-declared column wins. Implemented
    #                   as a portable CASE expression (no full-text index needed);
    #                   the relation's existing ORDER BY becomes the tiebreaker.
    #                   `search(q, ranked: true/false)` overrides per call and
    #                   `search_rank(q)` exposes the expression for select/pluck.
    #
    # Uses Arel's `matches`. The query is escaped before interpolation, so
    # `%` / `_` / `\` from user input are treated as literals.
    module Searchable
      extend ActiveSupport::Concern

      LIKE_ESCAPE = "\\".freeze
      LIKE_SPECIAL = /[\\%_]/
      VALID_MODES = %i[any all].freeze
      VALID_MATCHES = %i[contains prefix exact].freeze
      # Which match tiers can be told apart under each match mode (best first).
      # Under :exact every hit is exact, so only the column position ranks.
      RANK_TIERS = { contains: %i[exact prefix contains], prefix: %i[exact prefix], exact: %i[exact] }.freeze

      included do
        class_attribute :searchable_fields, instance_accessor: false, default: []
        class_attribute :searchable_mode, instance_accessor: false, default: :any
        class_attribute :searchable_match, instance_accessor: false, default: :contains
        class_attribute :searchable_case_sensitive, instance_accessor: false, default: false
        class_attribute :searchable_ranked, instance_accessor: false, default: false
      end

      class_methods do
        include ConcernsOnRails::Support::ColumnGuard

        def searchable_by(*fields, mode: :any, match: :contains, case_sensitive: false, ranked: false)
          raise ArgumentError, "ConcernsOnRails::Models::Searchable: at least one field is required" if fields.empty?

          ensure_columns!("ConcernsOnRails::Models::Searchable", fields)
          validate_search_options!(mode, match, ranked: ranked)

          self.searchable_fields = fields.map(&:to_sym)
          self.searchable_mode = mode.to_sym
          self.searchable_match = match.to_sym
          self.searchable_case_sensitive = case_sensitive
          self.searchable_ranked = ranked

          scope :search, ->(query, ranked: nil) { search_relation(query, ranked: ranked) }
        end

        # `ranked:` nil defers to the macro's setting; true/false override it.
        def search_relation(query, ranked: nil)
          terms = search_terms(query)
          return all if terms.empty?

          relation = terms.reduce(all) { |memo, term| memo.where(search_term_predicate(term)) }
          ranked = searchable_ranked if ranked.nil?
          ranked ? search_apply_rank(relation, terms) : relation
        end

        # The relevance expression `ranked:` orders by — lower is better, 0 is an
        # exact match on the first column. Pluck or select it to show scores:
        #   Article.search(q).pluck(:id, Article.search_rank(q))
        # Under mode: :all it is the sum of the per-term scores.
        def search_rank(query)
          terms = search_terms(query)
          raise ArgumentError, "ConcernsOnRails::Models::Searchable: search_rank needs a non-blank query" if terms.empty?

          terms.map { |term| search_term_rank(term) }.reduce(:+)
        end
      end

      module ClassMethods
        private

        def search_terms(query)
          return [] if query.nil? || query.to_s.strip.empty?

          searchable_mode == :all ? query.to_s.split : [query.to_s]
        end

        # OR the per-field LIKE predicate for a single term.
        def search_term_predicate(term)
          pattern = search_like_pattern(term)
          predicates = searchable_fields.map do |field|
            arel_table[field].matches(pattern, LIKE_ESCAPE, searchable_case_sensitive)
          end
          predicates.reduce { |memo, predicate| memo.or(predicate) }
        end

        def search_like_pattern(term, match = searchable_match)
          escaped = term.to_s.gsub(LIKE_SPECIAL) { |char| "#{LIKE_ESCAPE}#{char}" }
          case match
          when :prefix then "#{escaped}%"
          when :exact  then escaped
          else "%#{escaped}%"
          end
        end

        # reorder (not order) so relevance leads and whatever ORDER BY the
        # relation already carried breaks ties.
        def search_apply_rank(relation, terms)
          rank = terms.map { |term| search_term_rank(term) }.reduce(:+)
          relation.reorder(rank.asc, *relation.order_values)
        end

        # CASE WHEN <col1 exact> THEN 0 WHEN <col2 exact> THEN 1 WHEN <col1 prefix>
        # THEN 2 ... ELSE <worst> END — one WHEN per (tier, column), so the
        # score is tier * columns + column position.
        def search_term_rank(term)
          fields = searchable_fields
          tiers = RANK_TIERS.fetch(searchable_match)
          node = Arel::Nodes::Case.new
          tiers.each_with_index do |tier, tier_index|
            pattern = search_like_pattern(term, tier)
            fields.each_with_index do |field, field_index|
              matched = arel_table[field].matches(pattern, LIKE_ESCAPE, searchable_case_sensitive)
              node = node.when(matched).then((tier_index * fields.size) + field_index)
            end
          end
          node.else(tiers.size * fields.size)
        end

        def validate_search_options!(mode, match, ranked: false)
          unless VALID_MODES.include?(mode.to_sym)
            raise ArgumentError, "ConcernsOnRails::Models::Searchable: unknown mode '#{mode}'. Valid modes: #{VALID_MODES.join(', ')}"
          end
          unless VALID_MATCHES.include?(match.to_sym)
            raise ArgumentError, "ConcernsOnRails::Models::Searchable: unknown match '#{match}'. Valid matches: #{VALID_MATCHES.join(', ')}"
          end
          return if [true, false].include?(ranked)

          raise ArgumentError, "ConcernsOnRails::Models::Searchable: ranked: must be true or false (got #{ranked.inspect})"
        end
      end
    end
  end
end
