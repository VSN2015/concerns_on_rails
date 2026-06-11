require "active_support/concern"
require "json"
require "time" # Time#iso8601(fraction_digits) lives in the stdlib time library

module ConcernsOnRails
  module Controllers
    # Cursor (keyset) pagination for API controllers — the constant-time
    # complement to Paginatable's offset pagination. No COUNT query, stable
    # under concurrent inserts, suitable for infinite scroll and sync feeds.
    #
    #   class ArticlesController < ApplicationController
    #     include ConcernsOnRails::Controllers::CursorPaginatable
    #     cursor_paginate_by order: { created_at: :desc }, per_page: 25, max_per_page: 200
    #
    #     def index
    #       render json: cursor_paginated(Article.all)
    #     end
    #   end
    #
    # Reads params[:cursor] (the opaque token from X-Next-Cursor) and
    # params[:per_page]. The primary key is always appended as a tiebreaker.
    # Ordering columns are chosen in code (never from params), must live on the
    # base model's table, be selected by the relation, and should be NOT NULL.
    #
    # Malformed or mismatched cursors raise CursorPaginatable::InvalidCursor;
    # on real controllers a rescue_from is registered automatically and renders
    # a 400 (via Respondable's render_error when included). Override
    # #render_invalid_cursor to customize the body.
    #
    # Do not combine with Controllers::Sortable#sorted — cursor_paginated uses
    # reorder, which replaces any prior ORDER BY (including Models::Sortable's
    # default_scope). Pass `order:` per call instead.
    module CursorPaginatable
      extend ActiveSupport::Concern

      DEFAULT_PER_PAGE = 25
      DEFAULT_MAX_PER_PAGE = 200
      VALID_DIRECTIONS = %i[asc desc].freeze

      # Raised when params[:cursor] is malformed, tampered with, or was minted
      # under a different table/order configuration. Auto-rescued to a 400 when
      # the including class supports rescue_from (real controllers do).
      class InvalidCursor < StandardError; end

      # Normalizes Symbol / Array-of-Symbols / Hash order declarations to
      # [[column, direction], ...]. Raises ArgumentError on anything else.
      def self.normalize_order!(order)
        pairs =
          case order
          when Hash then order.map { |col, dir| [col.to_sym, dir.to_sym] }
          when Array then order.map { |col| [normalize_order_column!(col), :asc] }
          else [[normalize_order_column!(order), :asc]]
          end
        raise ArgumentError, "#{name}: at least one order column is required" if pairs.empty?

        validate_order_directions!(pairs)
        pairs
      end

      def self.validate_order_directions!(pairs)
        pairs.each do |col, dir|
          next if VALID_DIRECTIONS.include?(dir)

          raise ArgumentError, "#{name}: direction for '#{col}' must be :asc or :desc"
        end
      end

      def self.normalize_order_column!(col)
        return col.to_sym if col.is_a?(Symbol) || col.is_a?(String)

        raise ArgumentError, "#{name}: order entries must be column names (Symbol/String); " \
                             "use a Hash like { column: :desc } to set directions"
      end

      included do
        class_attribute :cursor_paginatable_order, default: nil
        class_attribute :cursor_paginatable_per_page, default: DEFAULT_PER_PAGE
        class_attribute :cursor_paginatable_max_per_page, default: DEFAULT_MAX_PER_PAGE

        # Real controllers (anything with ActiveSupport::Rescuable) get the 400
        # handler automatically; bare objects let InvalidCursor propagate.
        rescue_from InvalidCursor, with: :render_invalid_cursor if respond_to?(:rescue_from)
      end

      class_methods do
        # Configure the keyset ordering and page-size defaults.
        # Example:
        #   cursor_paginate_by order: { created_at: :desc }, per_page: 50, max_per_page: 500
        def cursor_paginate_by(order:, per_page: DEFAULT_PER_PAGE, max_per_page: DEFAULT_MAX_PER_PAGE)
          self.cursor_paginatable_order = CursorPaginatable.normalize_order!(order)
          self.cursor_paginatable_per_page = per_page.to_i
          self.cursor_paginatable_max_per_page = max_per_page.to_i
        end
      end

      # Run the keyset query (limit + 1 to detect has_more), set the standard
      # response headers, and return the page as a loaded Array (laziness is
      # impossible here: has_more detection materializes limit + 1 rows).
      # Raises InvalidCursor (rescued to a 400 on real controllers) on bad
      # cursors.
      def cursor_paginated(relation, order: nil, per_page: nil)
        @cursor_pagination_meta = nil # never expose a previous call's meta after a failure
        result = cursor_paginate_result(relation, order: order, per_page: per_page)
        @cursor_pagination_meta = result[:meta]
        apply_cursor_pagination_headers(result[:meta])
        result[:records]
      end

      # With no arguments: the meta Hash memoized by the last cursor_paginated
      # call (no extra query; nil if that call failed or never ran). With a
      # relation: runs the query and returns meta WITHOUT setting headers or
      # touching the memo — for body-based pagination (Respondable's meta:).
      def cursor_pagination_meta(relation = nil, order: nil, per_page: nil)
        return @cursor_pagination_meta if relation.nil?

        cursor_paginate_result(relation, order: order, per_page: per_page)[:meta]
      end

      # Public override point (mirrors ErrorHandleable's public handlers):
      # delegates to Respondable#render_error when available.
      def render_invalid_cursor(error)
        return render_error(message: error.message, status: :bad_request, code: "invalid_cursor") if respond_to?(:render_error)

        render json: { success: false, error: { message: error.message, code: "invalid_cursor" } }, status: :bad_request
      end

      private

      def cursor_paginate_result(relation, order:, per_page:)
        relation = relation.all if relation.is_a?(Class)
        pairs = cursor_order_pairs(relation, order)
        limit = cursor_per_page(per_page)
        boundary = decode_cursor(params[:cursor], pairs, relation.model)

        # reorder (not order) so the keyset columns REPLACE any prior ORDER BY
        # — including a Models::Sortable default_scope order.
        scoped = relation.reorder(pairs.to_h)
        scoped = scoped.where(cursor_predicate(relation.model, pairs, boundary)) if boundary
        rows = scoped.limit(limit + 1).to_a

        has_more = rows.size > limit
        records = rows.first(limit)
        next_cursor = has_more ? encode_cursor(relation.model, pairs, records.last) : nil
        { records: records,
          meta: { per_page: limit, count: records.size, has_more: has_more, next_cursor: next_cursor } }
      end

      # Resolved [[column, direction], ...] with the primary key appended as a
      # tiebreaker (inheriting the last column's direction) when not declared.
      def cursor_order_pairs(relation, override)
        pairs = override ? CursorPaginatable.normalize_order!(override) : self.class.cursor_paginatable_order
        pairs = (pairs || []).dup
        pk = relation.model.primary_key
        unless pk.is_a?(String) # Array under composite PKs, nil for PK-less tables
          raise ArgumentError,
                "#{CursorPaginatable.name}: #{relation.model.table_name} needs a single-column primary key"
        end

        pk = pk.to_sym
        pairs << [pk, pairs.empty? ? :asc : pairs.last.last] unless pairs.any? { |col, _| col == pk }
        validate_cursor_columns!(relation.model, pairs)
        pairs
      end

      def validate_cursor_columns!(model, pairs)
        pairs.map(&:first).each do |col|
          next if model.column_names.include?(col.to_s)

          raise ArgumentError,
                "#{CursorPaginatable.name}: '#{col}' does not exist in the database (table: #{model.table_name})"
        end
      end

      def cursor_per_page(override)
        requested = (override || params[:per_page]).to_i
        requested = self.class.cursor_paginatable_per_page if requested < 1
        cap = self.class.cursor_paginatable_max_per_page
        cap.positive? ? [requested, cap].min : requested
      end

      # ----- cursor encode/decode -----

      def encode_cursor(model, pairs, record)
        payload = {
          "t" => model.table_name, # pin the table so cross-model replay is rejected
          "o" => pairs.map { |col, dir| "#{col}:#{dir}" },
          "v" => pairs.map { |col, _dir| serialize_cursor_value(cursor_boundary_value!(record, col)) }
        }
        cursor_base64_encode(JSON.generate(payload))
      end

      # A NULL boundary value would emit `col > NULL` — never TRUE in SQL
      # three-valued logic — and silently drop rows from every later page.
      # Fail loudly instead: this is a data/configuration problem.
      def cursor_boundary_value!(record, col)
        value = record.public_send(col)
        return value unless value.nil?

        raise ArgumentError,
              "#{CursorPaginatable.name}: ordering column '#{col}' is NULL on the page-boundary row " \
              "(id: #{record.id.inspect}) — cursor pagination needs non-NULL ordering values; " \
              "use NOT NULL columns or COALESCE"
      end

      # Explicit is_a? checks (NOT acts_like?, which needs an un-required
      # core_ext; NOT case/when, whose Module#=== misses TimeWithZone — its
      # redefined #is_a? returns true for Time). iso8601(6) keeps microsecond
      # precision so boundary equality survives the round trip.
      def serialize_cursor_value(value)
        return value.to_time.utc.iso8601(6) if value.is_a?(Time) || value.is_a?(DateTime)
        return value.iso8601 if value.is_a?(Date)
        return value.to_s if value.is_a?(BigDecimal)

        value
      end

      # nil → no cursor param (first page). Otherwise the boundary values cast
      # back to native types via the model's attribute types, so Arel quotes
      # them correctly per database adapter (SQLite stores datetimes with a
      # space, not ISO "T" — raw string comparison would silently break).
      def decode_cursor(raw, pairs, model)
        return nil if raw.nil? || raw.to_s.strip.empty?

        payload = parse_cursor_payload(raw.to_s)
        raise InvalidCursor, "Invalid pagination cursor." unless payload

        verify_cursor_scope!(payload, pairs, model)
        values = payload["v"]
        raise InvalidCursor, "Invalid pagination cursor." unless valid_cursor_values?(values, pairs.size)

        pairs.zip(values).map { |(col, _dir), value| model.type_for_attribute(col.to_s).cast(value) }
      end

      def parse_cursor_payload(raw)
        parsed = JSON.parse(cursor_base64_decode(raw))
        parsed.is_a?(Hash) ? parsed : nil
      # ArgumentError: unpack1("m0") on invalid Base64; JSON::ParserError:
      # malformed JSON. Nothing else in the body raises either.
      rescue ArgumentError, JSON::ParserError
        nil
      end

      # Hand-rolled URL-safe Base64 (pack("m0") is strict RFC 4648, raising
      # ArgumentError on garbage) — same trick as WebhookVerifiable, keeping
      # the gem off the base64 gem, which left Ruby's default gems in 3.4.
      def cursor_base64_encode(json)
        [json].pack("m0").tr("+/", "-_").delete("=")
      end

      def cursor_base64_decode(raw)
        standard = raw.tr("-_", "+/")
        standard += "=" * ((4 - (standard.length % 4)) % 4)
        standard.unpack1("m0")
      end

      # Exact match on table + column:direction list rejects cursors minted on
      # another model, under another order config, or after a config change.
      def verify_cursor_scope!(payload, pairs, model)
        expected = pairs.map { |col, dir| "#{col}:#{dir}" }
        return if payload["t"] == model.table_name && payload["o"] == expected

        raise InvalidCursor, "Cursor does not match the current pagination configuration."
      end

      # Only non-null JSON scalars may be cast — a tampered Hash/Array value
      # would cast to nil (silently empty page) or raise adapter-dependent
      # errors, and we never mint null boundary values (see
      # cursor_boundary_value!), so a null here is tampering too.
      def valid_cursor_values?(values, expected_size)
        values.is_a?(Array) && values.size == expected_size && values.all? { |v| cursor_scalar?(v) }
      end

      def cursor_scalar?(value)
        value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
      end

      # ----- keyset WHERE (Arel OR-expansion; portable, supports mixed asc/desc)
      # (c1 > v1) OR (c1 = v1 AND c2 > v2) OR ... with gt/lt per column
      # direction; strict comparisons exclude the boundary row itself.
      def cursor_predicate(model, pairs, values)
        table = model.arel_table
        branches = pairs.each_index.map do |i|
          eqs = (0...i).map { |j| table[pairs[j][0]].eq(values[j]) }
          cmp = pairs[i][1] == :asc ? table[pairs[i][0]].gt(values[i]) : table[pairs[i][0]].lt(values[i])
          (eqs + [cmp]).reduce(:and)
        end
        branches.reduce(:or)
      end

      def apply_cursor_pagination_headers(meta)
        return unless respond_to?(:response) && response

        response.set_header("X-Per-Page", meta[:per_page].to_s)
        response.set_header("X-Count", meta[:count].to_s)
        response.set_header("X-Has-More", meta[:has_more].to_s)
        response.set_header("X-Next-Cursor", meta[:next_cursor]) if meta[:next_cursor]
      end
    end
  end
end
