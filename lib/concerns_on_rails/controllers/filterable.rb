require "active_support/concern"
require "active_model/type"
require "concerns_on_rails/support/scalar_param"
require "concerns_on_rails/support/numeric_operand"

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
    # Numeric columns read every operand as an exact decimal, never
    # truncated: on an integer column "1e3" is 1000 and "5.0" is 5, while 5.5
    # compares exactly (`> 5.5` is `>= 6`, `< 5.5` is `<= 5`) and equals
    # nothing — a decimal finer than its column's scale likewise. A value
    # beyond what the column can hold is answered per operator
    # (`?stock_lt=99999999999999999999` is every non-NULL row, `?stock_gt=`
    # the same value is none). contains / starts_with apply to string/text
    # (non-array) columns only and match nothing on any other column.
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
      NUMERIC_STRING = ConcernsOnRails::Support::NumericOperand::NUMERIC_STRING
      # Column types LIKE is defined on. Anything else — integer, decimal,
      # datetime, uuid, a PostgreSQL enum — is an operator error on
      # PostgreSQL (`integer ~~* unknown`), so contains/starts_with fail closed.
      LIKE_TYPES = %i[string text citext].freeze
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
          apply_filter_equality(relation, field, value)
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
        when :not then filterable_operand?(raw) ? apply_filter_equality(relation, field, raw, negate: true) : relation
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

        column_type = filterable_column_type(relation, field)
        operand = ConcernsOnRails::Support::NumericOperand.classify(raw, options[:type] || column_type, column_type: column_type)
        return apply_filter_numeric_comparison(relation, field, operator, operand) if operand

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

      # A plain numeric column, read without ActiveModel's lossy casts (see
      # Support::NumericOperand). An exponent/fraction on an integer column
      # used to TRUNCATE (`?stock_gt=1e3` ran `stock > 1`, `?stock_lt=5.5`
      # ran `stock < 5`); every operand is now read as an exact decimal. A
      # value beyond what the column holds used to bind as 1=0 for every
      # operator — `stock < 10**20` came back empty — and is now answered per
      # operator: nothing is above an over-max bound, every non-NULL row is
      # below it (and the mirror image for an under-min bound). A value finer
      # than the column's scale cannot be bound as-is — the column type
      # rounds or truncates it (`price > 99.985` became `price > 99.99` and
      # lost the 99.99 row) — so the comparison is rewritten exactly.
      def apply_filter_numeric_comparison(relation, field, operator, operand)
        case operand.status
        when :uncastable then relation.none
        when :above then %i[gt gte].include?(operator) ? relation.none : relation.where.not(field => nil)
        when :below then %i[lt lte].include?(operator) ? relation.none : relation.where.not(field => nil)
        when :inexact then apply_filter_inexact_comparison(relation, field, operator, operand)
        else relation.where(relation.model.arel_table[field].public_send(COMPARISONS.fetch(operator), operand.value))
        end
      end

      # v is not representable at the column's scale s, so nothing stored lies
      # between floor_s(v) and v: `> v` and `>= v` are exactly `> floor_s(v)`,
      # and `< v` / `<= v` exactly `<= floor_s(v)` (on an integer column,
      # `> 5.5` is `> 5`, i.e. `>= 6`; `<= 5.5` is `<= 5`). The floor IS
      # representable — and range-checked by NumericOperand, so it can never be
      # the unbindable one-past-the-maximum a ceiling could be — so it binds
      # through the column type unchanged, and no unrounded literal (which a
      # PostgreSQL money column or MySQL's 65-digit DECIMAL literal limit could
      # choke on) reaches SQL.
      def apply_filter_inexact_comparison(relation, field, operator, operand)
        column = relation.model.arel_table[field]
        if %i[gt gte].include?(operator)
          relation.where(column.gt(operand.floor))
        else
          relation.where(column.lteq(operand.floor))
        end
      end

      def apply_filter_list(relation, field, operator, raw)
        list = filterable_list(raw)
        return relation if list.nil?

        apply_filter_equality(relation, field, list, negate: operator == :not_in)
      end

      # Equality — the direct-where filter, `not`, `in`, `not_in` — keeps
      # ActiveRecord's own `where`, EXCEPT on a plain numeric column, where the
      # column type's cast was lossy: `?stock=5.5` matched stock 5, and
      # `?stock_in=1e1` matched stock 1. There each value is read strictly
      # against the COLUMN's type (what `where` casts with): an uncastable one
      # fails the whole filter closed (none, `not`/`not_in` included); one no
      # stored value can equal — beyond the column's range, or finer than its
      # scale — simply matches nothing, so it drops out of the list, and a
      # list left empty matches nothing (`in`) or every non-NULL row
      # (`not_in`, exactly what `!=` / NOT IN would answer).
      def apply_filter_equality(relation, field, value, negate: false)
        kept = filterable_numeric_equality_values(relation, field, value.is_a?(Array) ? value : [value])
        return filterable_where(relation, field, value, negate) if kept.nil?
        return relation.none if kept == :uncastable
        return negate ? relation.where.not(field => nil) : relation.none if kept.empty?

        filterable_where(relation, field, value.is_a?(Array) ? kept : kept.first, negate)
      end

      def filterable_where(relation, field, value, negate)
        negate ? relation.where.not(field => value) : relation.where(field => value)
      end

      # nil when the column is not plain numeric (the caller keeps the raw
      # value, unchanged behaviour); :uncastable; or the exact values to keep.
      # nil / blank members of a direct-where array pass through untouched,
      # as ActiveRecord always treated them (`IS NULL`).
      def filterable_numeric_equality_values(relation, field, values)
        column_type = filterable_column_type(relation, field)
        return nil unless ConcernsOnRails::Support::NumericOperand.kind(column_type)

        operands = values.map { |member| filterable_equality_operand(member, column_type) }
        return :uncastable if operands.any? { |operand| operand.status == :uncastable }

        operands.select { |operand| operand.status == :exact }.map(&:value)
      end

      def filterable_equality_operand(member, column_type)
        return ConcernsOnRails::Support::NumericOperand::Operand.new(:exact, member) if member.nil? || member == ""

        ConcernsOnRails::Support::NumericOperand.classify(member, column_type)
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
      # so matching folds case on PostgreSQL, on SQLite (ASCII letters only —
      # SQLite's LIKE does not fold non-ASCII), and on MySQL under the default
      # case-insensitive `_ci` collations; a MySQL column with a `_bin` or `_cs`
      # collation compares case-SENSITIVELY. (Wrapping both sides in LOWER()
      # would make MySQL fold too, but it would also stop starts_with from
      # using the column's index on every adapter, so it is left to the
      # column's collation.)
      # Escaped here rather than through `sanitize_sql_like`, which is only
      # public from Rails 5.1 while the gemspec supports >= 5.0 — Searchable
      # hand-rolls the identical gsub for the same reason.
      #
      # Only on a text column: LIKE on an integer/decimal/datetime/uuid column
      # is an operator error on PostgreSQL — a 500 from `?stock_contains=1` —
      # and on SQLite/MySQL the pattern went through the column's type
      # (Integer#serialize("1%") is 1), so it silently turned into equality.
      # Such a request now fails closed. A field with no attribute type (not a
      # column) is left to the database as before. A PostgreSQL ARRAY column
      # reports its ELEMENT type (`t.string :tags, array: true` is :string),
      # so it is refused on the column itself: `varchar[] ILIKE` is an error.
      def apply_filter_like(relation, field, operator, raw)
        return relation unless ConcernsOnRails::Support::ScalarParam.scalar?(raw)

        column_type = filterable_column_type(relation, field)
        return relation.none if column_type && !LIKE_TYPES.include?(column_type.type)
        return relation.none if filterable_array_column?(relation, field)

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

      # PostgreSQL's Column answers `array` (its sql_type drops the "[]", so
      # that alone cannot tell); the sql_type suffix covers adapters that keep it.
      def filterable_array_column?(relation, field)
        model = relation.model
        return false unless model.respond_to?(:columns_hash)

        column = model.columns_hash[field.to_s]
        return false unless column
        return true if column.respond_to?(:array) && column.array

        column.respond_to?(:sql_type) && column.sql_type.to_s.end_with?("[]")
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
