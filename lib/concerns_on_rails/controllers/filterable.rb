require "active_support/concern"
require "active_model/type"
require "concerns_on_rails/support/scalar_param"

module ConcernsOnRails
  module Controllers
    # Declarative URL-param filtering for index actions. Three modes per filter:
    #
    #   filter_by :status, :category                         # ?status=draft       -> .where(status: 'draft')
    #   filter_by :published, scope: :published              # ?published=1        -> .published
    #   filter_by :q, with: ->(rel, v) { rel.where(...) }    # ?q=foo              -> lambda is called
    #
    # Direct-where filters can opt into comparison operators, accepted either as
    # a suffix (`?price_gte=10`) or in bracket form (`?price[gte]=10`):
    #
    #   filter_by :price, :stock, operators: true            # every operator below
    #   filter_by :created_at, operators: %i[gte lte]        # a subset
    #
    #   not · gt · gte · lt · lte · in · not_in (comma list or array) ·
    #   null (true/false) · contains · starts_with (LIKE, wildcards escaped)
    #
    # Comparison values are cast the way ActiveRecord casts them — through the
    # column's own attribute type — or through `type:` (any ActiveModel type
    # name: :integer, :decimal, :boolean, :date, :datetime, ...). `type:` also
    # pre-casts the value handed to a `with:` lambda. Blank values are skipped,
    # unknown operators and non-scalar values are ignored; nothing here raises
    # at request time — for strict, validated params use Permittable.
    #
    # Usage:
    #   class ArticlesController < ApplicationController
    #     include ConcernsOnRails::Controllers::Filterable
    #     filter_by :status
    #     filter_by :q, with: ->(rel, v) { rel.where("title ILIKE ?", "%#{v}%") }
    #
    #     def index
    #       render json: filtered(Article.all)
    #     end
    #   end
    module Filterable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Controllers::Filterable".freeze
      OPERATORS = %i[not gt gte lt lte in not_in null contains starts_with].freeze
      COMPARISONS = { gt: :gt, gte: :gteq, lt: :lt, lte: :lteq }.freeze
      LIKE_ESCAPE = "\\".freeze

      included do
        class_attribute :filterable_rules, default: {}
      end

      module ClassMethods
        # Declare one or more filterable params. Modes are mutually exclusive
        # per call; pass either `scope:` or `with:`, or neither (direct where).
        # `operators:` (true or a list) is direct-where only; `type:` applies to
        # direct-where comparisons and to `with:` lambdas.
        def filter_by(*fields, scope: nil, with: nil, type: nil, operators: nil)
          raise ArgumentError, "#{LABEL}: at least one field is required" if fields.empty?
          raise ArgumentError, "#{LABEL}: pass either :scope or :with, not both" if scope && with

          operators = filterable_normalize_operators(operators, direct: scope.nil? && with.nil?)
          type = filterable_normalize_type(type)

          new_rules = filterable_rules.dup
          fields.each do |field|
            new_rules[field.to_sym] = { scope: scope, with: with, type: type, operators: operators }
          end
          self.filterable_rules = new_rules
        end

        def filterable_normalize_operators(operators, direct:)
          return nil if operators.nil? || operators == false
          raise ArgumentError, "#{LABEL}: operators: only apply to direct-where filters (not scope:/with:)" unless direct

          operators == true ? OPERATORS : filterable_operator_list(operators)
        end

        def filterable_operator_list(operators)
          list = Array(operators).map(&:to_sym)
          unknown = list - OPERATORS
          return list if unknown.empty?

          raise ArgumentError,
                "#{LABEL}: unknown operator(s) #{unknown.map(&:inspect).join(', ')} — " \
                "valid: #{OPERATORS.map(&:inspect).join(', ')}"
        end

        # Resolved eagerly so a typo fails at class load, not on the first request.
        def filterable_normalize_type(type)
          return nil if type.nil?

          ActiveModel::Type.lookup(type.to_sym)
        rescue ArgumentError
          raise ArgumentError, "#{LABEL}: type: #{type.inspect} is not an ActiveModel type (try :integer, :decimal, :date, ...)"
        end
        private :filterable_normalize_operators, :filterable_operator_list, :filterable_normalize_type
      end

      # Apply all declared filters to a relation based on params. Blank values
      # are skipped so unset filters don't narrow the relation.
      def filtered(relation)
        self.class.filterable_rules.each do |field, options|
          value = params[field]
          relation = apply_filter(relation, field, value, options) unless value.blank?
          relation = apply_filter_operator_suffixes(relation, field, options) if options[:operators]
        end
        relation
      end

      private

      def apply_filter(relation, field, value, options)
        if options[:with]
          options[:with].call(relation, filter_cast(relation, field, value, options))
        elsif options[:scope]
          relation.public_send(options[:scope])
        elsif filterable_scalar?(value)
          relation.where(field => value)
        elsif options[:operators] && value.respond_to?(:each_pair)
          apply_filter_operator_hash(relation, field, value, options)
        else
          # A nested/structured param (e.g. ?status[gt]=5) in direct-where mode
          # would raise TypeError ("can't quote Hash") and surface as a 500.
          # Ignore it instead — hash/array shaping must go through a `with:`
          # lambda or `operators:`.
          relation
        end
      end

      # ?price[gte]=10&price[lte]=50 — unknown keys are ignored.
      def apply_filter_operator_hash(relation, field, hash, options)
        hash.each do |key, raw|
          operator = key.to_s.to_sym
          next unless options[:operators].include?(operator)

          relation = apply_filter_operator(relation, field, operator, raw, options)
        end
        relation
      end

      # ?price_gte=10 — one param per declared operator.
      def apply_filter_operator_suffixes(relation, field, options)
        options[:operators].each do |operator|
          raw = params[:"#{field}_#{operator}"]
          next if raw.blank?

          relation = apply_filter_operator(relation, field, operator, raw, options)
        end
        relation
      end

      def apply_filter_operator(relation, field, operator, raw, options)
        case operator
        when :in, :not_in then apply_filter_list(relation, field, operator, raw)
        when :null then apply_filter_null(relation, field, raw)
        when :contains, :starts_with then apply_filter_like(relation, field, operator, raw)
        when :not then ConcernsOnRails::Support::ScalarParam.scalar?(raw) ? relation.where.not(field => raw) : relation
        else apply_filter_comparison(relation, field, operator, raw, options)
        end
      end

      def apply_filter_comparison(relation, field, operator, raw, options)
        return relation unless ConcernsOnRails::Support::ScalarParam.scalar?(raw)

        column = relation.model.arel_table[field]
        relation.where(column.public_send(COMPARISONS.fetch(operator), filter_cast(relation, field, raw, options)))
      end

      def apply_filter_list(relation, field, operator, raw)
        list = filterable_list(raw)
        return relation if list.nil?

        operator == :in ? relation.where(field => list) : relation.where.not(field => list)
      end

      # A comma list ("a, b") or an array (?status_in[]=a) of scalars → the
      # cleaned list, or nil when unsafe or empty.
      def filterable_list(raw)
        list = raw.is_a?(Array) ? raw : raw.to_s.split(",")
        return nil unless ConcernsOnRails::Support::ScalarParam.where_safe?(list)

        list = list.map { |item| item.is_a?(String) ? item.strip : item }.reject { |item| item.to_s.empty? }
        list.empty? ? nil : list
      end

      def apply_filter_null(relation, field, raw)
        return relation unless ConcernsOnRails::Support::ScalarParam.scalar?(raw)

        ActiveModel::Type::Boolean.new.cast(raw) ? relation.where(field => nil) : relation.where.not(field => nil)
      end

      # LIKE with the user's wildcards escaped — with an explicit ESCAPE clause,
      # since SQLite has no default escape character (Searchable does the same).
      # Arel `matches` is ILIKE on PostgreSQL and the adapter's LIKE elsewhere.
      def apply_filter_like(relation, field, operator, raw)
        return relation unless ConcernsOnRails::Support::ScalarParam.scalar?(raw)

        escaped = relation.model.sanitize_sql_like(raw.to_s, LIKE_ESCAPE)
        pattern = operator == :contains ? "%#{escaped}%" : "#{escaped}%"
        relation.where(relation.model.arel_table[field].matches(pattern, LIKE_ESCAPE))
      end

      # `type:` wins; otherwise the column's own attribute type (what
      # `where(field => value)` would use); a virtual field passes through raw.
      def filter_cast(relation, field, value, options)
        return options[:type].cast(value) if options[:type]

        model = relation.model
        return value unless model.respond_to?(:attribute_types) && model.attribute_types.key?(field.to_s)

        model.type_for_attribute(field.to_s).cast(value)
      end

      # Scalars (and arrays of scalars, which AR turns into `IN (...)`) are safe
      # to pass to .where; a Hash / ActionController::Parameters is not — and
      # since 1.22 neither is an array CONTAINING one (`?status[][x]=1` used to
      # slip through as [Parameters] and 500 with a TypeError).
      def filterable_scalar?(value)
        ConcernsOnRails::Support::ScalarParam.where_safe?(value)
      end
    end
  end
end
