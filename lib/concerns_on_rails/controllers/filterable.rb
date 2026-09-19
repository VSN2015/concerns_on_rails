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
    # unknown operators and non-scalar values are ignored, and a comparison
    # value the type cannot represent (`?price_gte=abc`) matches nothing;
    # nothing here raises at request time — for strict, validated params use
    # Permittable.
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
      LIKE_SPECIAL = /[\\%_]/
      NUMERIC_TYPES = %i[integer float decimal].freeze
      NUMERIC_STRING = /\A\s*[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?\s*\z/
      UNCASTABLE = Object.new.freeze

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

      # Apply all declared filters to a relation based on params. Unset values
      # are skipped so absent filters don't narrow the relation.
      def filtered(relation)
        self.class.filterable_rules.each do |field, options|
          value = params[field]
          relation = apply_filter(relation, field, value, options) unless filterable_unset?(value)
          relation = apply_filter_operator_suffixes(relation, field, options) if options[:operators]
        end
        relation
      end

      private

      # NOT `value.blank?`: `false.blank?` is true, so a genuine boolean false
      # read as "filter not supplied" and the relation came back UNFILTERED —
      # `filter_by :active` could never select the inactive rows. Query strings
      # were unaffected (they carry the String "false", which is not blank), so
      # this only bit JSON request bodies, where the value really is `false`.
      # Everything actually empty — nil, "", "   ", [], {} — is still skipped.
      def filterable_unset?(value)
        return false if value == false
        return true if value.nil?

        value.respond_to?(:blank?) ? value.blank? : false
      end

      def apply_filter(relation, field, value, options)
        if options[:with]
          apply_filter_lambda(relation, value, options)
        elsif options[:scope]
          # Scope mode discards the value, so an explicit `false` can only mean
          # "do not apply this scope" — applying it would hand the client the
          # exact opposite of what it asked for. (A query string still carries
          # the String "false", which has always triggered the scope; only a
          # real boolean is read as a negation.)
          value == false ? relation : relation.public_send(options[:scope])
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

      # `type:` pre-casts a with: lambda's value; the column's own type must
      # NOT, or every existing lambda on a column-backed param silently starts
      # receiving true / a Time where it used to get "1" / "2020-01-02".
      def apply_filter_lambda(relation, value, options)
        options[:with].call(relation, options[:type] ? options[:type].cast(value) : value)
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
          relation = apply_filter_operator(relation, field, operator, params[:"#{field}_#{operator}"], options)
        end
        relation
      end

      # The unset guard lives here, not in the two callers: the suffix form used
      # to skip blanks and the bracket form did not, so `?price[gte]=` cast ""
      # to nil and `price > NULL` handed back ZERO rows, while `?price_gte=` —
      # documented as the same filter — correctly returned everything. It is
      # `filterable_unset?`, not `blank?`, for the same reason `#filtered` uses
      # it: a JSON body's `false` is a value, not an absent param.
      def apply_filter_operator(relation, field, operator, raw, options)
        return relation if filterable_unset?(raw)

        case operator
        when :in, :not_in then apply_filter_list(relation, field, operator, raw)
        when :null then apply_filter_null(relation, field, raw)
        when :contains, :starts_with then apply_filter_like(relation, field, operator, raw)
        when :not then filterable_operand?(raw) ? relation.where.not(field => raw) : relation
        else apply_filter_comparison(relation, field, operator, raw, options)
        end
      end

      # `ScalarParam.scalar?` deliberately excludes booleans (nothing there is
      # safe to `.to_i`), but a JSON body carries a real `true`/`false` and
      # `?deleted_at[null]=true` means something — so `null` and `not` take one.
      def filterable_operand?(raw)
        ConcernsOnRails::Support::ScalarParam.scalar?(raw) || raw == true || raw == false
      end

      def apply_filter_comparison(relation, field, operator, raw, options)
        return relation unless ConcernsOnRails::Support::ScalarParam.scalar?(raw)

        value = filter_cast(relation, field, raw, options)
        # A value the column's type cannot represent matches nothing. Casting it
        # anyway is worse than useless: `?stock_gt=twelve` becomes `stock > 0`
        # (Integer#cast("twelve") is 0, not nil) and quietly returns rows the
        # caller never asked for, while the same typo against a datetime column
        # casts to nil and returns none — one request answered two opposite ways.
        return relation.none if value.equal?(UNCASTABLE)

        column = relation.model.arel_table[field]
        relation.where(column.public_send(COMPARISONS.fetch(operator), value))
      end

      def apply_filter_list(relation, field, operator, raw)
        list = filterable_list(raw)
        return relation if list.nil?

        operator == :in ? relation.where(field => list) : relation.where.not(field => list)
      end

      # A comma list ("a, b") or an array (?status_in[]=a) of scalars → the
      # cleaned list, or nil when unsafe or empty. A hash-shaped param is NOT a
      # list: `?status_in[x]=1` used to reach `to_s` and filter on the literal
      # string `{"x"=>"1"}` instead of being ignored as documented.
      def filterable_list(raw)
        list = filterable_raw_list(raw)
        return nil if list.nil? || !ConcernsOnRails::Support::ScalarParam.where_safe?(list)

        list = list.map { |item| item.is_a?(String) ? item.strip : item }.reject { |item| item.to_s.empty? }
        list.empty? ? nil : list
      end

      def filterable_raw_list(raw)
        return raw if raw.is_a?(Array)

        raw.to_s.split(",") if ConcernsOnRails::Support::ScalarParam.scalar?(raw)
      end

      def apply_filter_null(relation, field, raw)
        return relation unless filterable_operand?(raw)

        ActiveModel::Type::Boolean.new.cast(raw) ? relation.where(field => nil) : relation.where.not(field => nil)
      end

      # LIKE with the user's wildcards escaped — with an explicit ESCAPE clause,
      # since SQLite has no default escape character (Searchable does the same).
      # Arel `matches` is ILIKE on PostgreSQL and the adapter's LIKE elsewhere,
      # so matching is case-insensitive on all three supported adapters.
      # Escaped here rather than through `sanitize_sql_like`, which is only
      # public from Rails 5.1 while the gemspec supports >= 5.0 — Searchable
      # hand-rolls the identical gsub for the same reason.
      def apply_filter_like(relation, field, operator, raw)
        return relation unless ConcernsOnRails::Support::ScalarParam.scalar?(raw)

        escaped = raw.to_s.gsub(LIKE_SPECIAL) { |char| "#{LIKE_ESCAPE}#{char}" }
        pattern = operator == :contains ? "%#{escaped}%" : "#{escaped}%"
        relation.where(relation.model.arel_table[field].matches(pattern, LIKE_ESCAPE))
      end

      # `type:` wins; otherwise the column's own attribute type (what
      # `where(field => value)` would use); a virtual field passes through raw.
      # Returns UNCASTABLE when the value is not representable in that type.
      def filter_cast(relation, field, value, options)
        type = options[:type] || filterable_column_type(relation, field)
        return value if type.nil?
        return UNCASTABLE if filterable_uncastable?(type, value)

        type.cast(value)
      end

      def filterable_column_type(relation, field)
        model = relation.model
        return nil unless model.respond_to?(:attribute_types) && model.attribute_types.key?(field.to_s)

        model.type_for_attribute(field.to_s)
      end

      # Numeric types are checked against the string BEFORE casting, because
      # `Integer#cast`/`Decimal#cast` answer 0 for any non-numeric string rather
      # than nil — the cast result alone cannot tell "0" from "twelve". Every
      # other type reports the failure by casting to nil (blank values never get
      # this far; `apply_filter_operator` skipped them).
      def filterable_uncastable?(type, value)
        return type.cast(value).nil? unless NUMERIC_TYPES.include?(type.type)
        return false if value.is_a?(Numeric)

        !NUMERIC_STRING.match?(value.to_s)
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
