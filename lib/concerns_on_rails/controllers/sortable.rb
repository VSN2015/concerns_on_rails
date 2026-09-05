require "active_support/concern"

module ConcernsOnRails
  module Controllers
    # URL-param-driven ordering for index actions, with a strict allow-list to
    # prevent ordering by arbitrary user-supplied columns (SQL injection / data
    # exposure risk).
    #
    #   class ArticlesController < ApplicationController
    #     include ConcernsOnRails::Controllers::Sortable
    #     sortable_by :created_at, :title, :published_at,
    #                 author: { column: "authors.name", joins: :author },   # an association column
    #                 price:  { nulls: :last },                             # NULLs after the values
    #                 default: :created_at, direction: :desc
    #
    #     def index
    #       render json: sorted(Article.all)
    #     end
    #   end
    #
    # Reads params[:sort] — comma-separated sort KEYS, each optionally prefixed
    # with `-` (descending) or `+` (ascending), the JSON:API convention:
    # `?sort=-created_at,title`. Un-prefixed keys take params[:direction]
    # (asc/desc), then the configured default direction. Unknown keys are
    # dropped; when nothing valid remains the default key applies.
    #
    # A plain Symbol key sorts by that column of the relation's own table. A
    # `key: { ... }` rule may point at another table — `column: "table.column"`
    # plus `joins:` (anything `left_outer_joins`/`joins` accepts; LEFT OUTER by
    # default so rows without the association are kept, `join: :inner` to drop
    # them) — and/or ask for `nulls: :first | :last` (Rails 6.1+, PostgreSQL /
    # SQLite; MySQL has no NULLS FIRST/LAST syntax). Joins are added only when
    # that key is actually requested.
    module Sortable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Controllers::Sortable".freeze
      VALID_DIRECTIONS = %i[asc desc].freeze
      VALID_NULLS = %i[first last].freeze
      VALID_JOINS = %i[left inner].freeze
      RULE_OPTIONS = %i[column joins join nulls].freeze
      QUALIFIED_COLUMN = /\A[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*\z/

      included do
        class_attribute :sortable_rules, default: {}
        class_attribute :sortable_allowed_fields, default: []
        class_attribute :sortable_default_field, default: nil
        class_attribute :sortable_default_direction, default: :asc
      end

      module ClassMethods
        # Allow-list sortable keys and set defaults. Plain symbols are columns;
        # `key: { column:, joins:, join:, nulls: }` describes anything else.
        # Example:
        #   sortable_by :created_at, :title, author: { column: "authors.name", joins: :author },
        #               default: :created_at, direction: :desc
        def sortable_by(*allowed_fields, default: nil, direction: :asc, **rules)
          raise ArgumentError, "#{LABEL}: at least one field is required" if allowed_fields.empty? && rules.empty?

          declared = allowed_fields.flatten.to_h { |field| [field.to_sym, { column: field.to_sym }] }
          rules.each { |key, options| declared[key.to_sym] = sortable_normalize_rule!(key, options) }

          self.sortable_rules = declared
          self.sortable_allowed_fields = declared.keys
          self.sortable_default_field = sortable_normalize_default!(default, declared)
          self.sortable_default_direction = VALID_DIRECTIONS.include?(direction.to_sym) ? direction.to_sym : :asc
        end

        private

        def sortable_normalize_rule!(key, options)
          raise ArgumentError, "#{LABEL}: rule for #{key} must be a Hash" unless options.is_a?(Hash)

          unknown = options.keys - RULE_OPTIONS
          raise ArgumentError, "#{LABEL}: unknown option(s) for #{key}: #{unknown.join(', ')}" if unknown.any?

          {
            column: sortable_rule_column!(key, options.fetch(:column, key)),
            joins: options[:joins],
            join: sortable_rule_join!(key, options[:join]),
            nulls: sortable_rule_nulls!(key, options[:nulls])
          }
        end

        def sortable_rule_column!(key, column)
          return column if column.is_a?(Symbol) || (column.is_a?(String) && column.match?(QUALIFIED_COLUMN))

          raise ArgumentError, "#{LABEL}: #{key} column: must be a Symbol or a \"table.column\" String"
        end

        def sortable_rule_join!(key, join)
          join = (join || :left).to_sym
          raise ArgumentError, "#{LABEL}: #{key} join: must be :left or :inner" unless VALID_JOINS.include?(join)

          join
        end

        def sortable_rule_nulls!(key, nulls)
          return nil if nulls.nil?

          nulls = nulls.to_sym
          raise ArgumentError, "#{LABEL}: #{key} nulls: must be :first or :last" unless VALID_NULLS.include?(nulls)

          sortable_check_nulls_support!
          nulls
        end

        # NULLS FIRST/LAST rides Arel's Ordering#nulls_first/nulls_last (Rails 6.1+).
        def sortable_check_nulls_support!
          return if Arel::Nodes::Ascending.method_defined?(:nulls_last)

          raise ArgumentError, "#{LABEL}: nulls: needs Rails 6.1+ (Arel ordering nodes without NULLS FIRST/LAST support)"
        end

        def sortable_normalize_default!(default, declared)
          key = (default || declared.keys.first).to_sym
          raise ArgumentError, "#{LABEL}: default: #{key.inspect} is not a declared sort key" unless declared.key?(key)

          key
        end
      end

      # Apply ordering to a relation based on params[:sort] / params[:direction].
      # Falls back to defaults; never orders by a non-allow-listed key.
      def sorted(relation)
        requested = sort_requests
        return relation if requested.empty?

        # reorder (not order) so the requested columns REPLACE any prior
        # ORDER BY — including a model default_scope order.
        joined = requested.reduce(relation) { |rel, (key, _)| sort_apply_join(rel, self.class.sortable_rules[key]) }
        joined.reorder(*requested.map { |key, direction| sort_ordering(joined, key, direction) })
      end

      private

      # [[key, :asc|:desc], ...] from params[:sort]: allow-listed keys in
      # request order, each with its prefix direction or the request/default
      # fallback; the default key when none is valid.
      def sort_requests
        rules = self.class.sortable_rules
        fallback = sort_direction
        parsed = params[:sort].to_s.split(",").filter_map do |token|
          token = token.strip
          key = token.sub(/\A[-+]/, "").to_sym
          [key, sort_prefix_direction(token, fallback)] if rules.key?(key)
        end
        return parsed unless parsed.empty?

        default = self.class.sortable_default_field
        default ? [[default, fallback]] : []
      end

      # Allow-listed sort columns from params[:sort]. Kept for subclasses that
      # relied on it; `sort_requests` carries the per-column directions.
      def sort_fields
        sort_requests.map(&:first)
      end

      # `-key` → desc, `+key` → asc, bare key → the request/default fallback.
      def sort_prefix_direction(token, fallback)
        case token[0]
        when "-" then :desc
        when "+" then :asc
        else fallback
        end
      end

      def sort_direction
        raw = params[:direction]
        requested = raw && raw.to_s.downcase.to_sym
        VALID_DIRECTIONS.include?(requested) ? requested : self.class.sortable_default_direction
      end

      def sort_apply_join(relation, rule)
        return relation unless rule[:joins]

        rule[:join] == :inner ? relation.joins(rule[:joins]) : relation.left_outer_joins(rule[:joins])
      end

      # An Arel ordering node: the relation's own column for a Symbol, a quoted
      # "table"."column" literal for a qualified String, with NULLS FIRST/LAST
      # appended when the rule asks for it.
      def sort_ordering(relation, key, direction)
        rule = self.class.sortable_rules[key]
        node = sort_column_node(relation, rule[:column])
        ordering = direction == :desc ? node.desc : node.asc
        case rule[:nulls]
        when :first then ordering.nulls_first
        when :last then ordering.nulls_last
        else ordering
        end
      end

      def sort_column_node(relation, column)
        return relation.model.arel_table[column] if column.is_a?(Symbol)

        table, name = column.split(".", 2)
        connection = relation.model.connection
        Arel.sql("#{connection.quote_table_name(table)}.#{connection.quote_column_name(name)}")
      end
    end
  end
end
