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
    # Optional capabilities (all opt-in, defaults unchanged):
    #   * bidirectional: true — mints X-Prev-Cursor / X-Has-Prev alongside the
    #     next cursor, so clients can page back without keeping old tokens.
    #   * order_presets: { newest: { created_at: :desc }, top: { score: :desc } }
    #     — allow-listed, client-selectable named orderings (?order= picks a
    #     preset NAME; columns stay code-chosen). Unknown names raise
    #     InvalidOrderPreset (auto-rescued to a 400).
    #   * predicate: :auto (default) — on adapters with row-value support
    #     (PostgreSQL/MySQL/SQLite) and uniform directions, the keyset WHERE is
    #     a tuple comparison `(a, b, id) > (x, y, z)` that walks a composite
    #     index directly; everything else falls back to the OR-expansion.
    #
    # Malformed or mismatched cursors raise CursorPaginatable::InvalidCursor;
    # on real controllers a rescue_from is registered automatically and renders
    # a 400 (via Respondable's render_error when included). Override
    # #render_invalid_cursor to customize the body. Cursors are opaque but NOT
    # signed — boundary values are cast through the model's attribute types
    # and bound by Arel (no injection) and the relation's scoping still
    # applies, so treat a cursor as a page position, never an authorization
    # boundary.
    #
    # Do not combine with Controllers::Sortable#sorted — cursor_paginated uses
    # reorder, which replaces any prior ORDER BY (including Models::Sortable's
    # default_scope). Pass `order:` per call instead.
    module CursorPaginatable
      extend ActiveSupport::Concern

      DEFAULT_PER_PAGE = 25
      DEFAULT_MAX_PER_PAGE = 200
      VALID_DIRECTIONS = %i[asc desc].freeze
      VALID_PREDICATES = %i[auto row or].freeze
      CURSOR_DIRECTIONS = %w[next prev].freeze
      # Adapters whose SQL supports row-value (tuple) comparison: (a, b) > (x, y).
      ROW_PREDICATE_ADAPTERS = /postgres|mysql|trilogy|sqlite/i

      # Raised when params[:cursor] is malformed, tampered with, or was minted
      # under a different table/order configuration. Auto-rescued to a 400 when
      # the including class supports rescue_from (real controllers do).
      class InvalidCursor < StandardError; end

      # Raised when params[?order=] (or the configured order_param) names no
      # configured preset. Auto-rescued to a 400 like InvalidCursor.
      class InvalidOrderPreset < StandardError; end

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

      # Macro-time validation/normalization for order_presets / default_preset
      # / predicate (module functions so class_methods stays thin).
      def self.normalize_presets!(presets)
        raise ArgumentError, "#{name}: order_presets must be a non-empty Hash" unless presets.is_a?(Hash) && presets.any?

        presets.to_h { |key, order| [key.to_sym, normalize_order!(order)] }
      end

      def self.resolve_default_preset!(presets, default_preset, order)
        validate_order_sources!(presets, default_preset, order)
        return nil unless presets

        key = (default_preset || presets.keys.first).to_sym
        raise ArgumentError, "#{name}: default_preset '#{key}' is not one of the order_presets" unless presets.key?(key)

        key
      end

      def self.validate_order_sources!(presets, default_preset, order)
        raise ArgumentError, "#{name}: pass order: or order_presets:, not both" if order && presets
        raise ArgumentError, "#{name}: order: or order_presets: is required" if order.nil? && presets.nil?
        raise ArgumentError, "#{name}: default_preset: requires order_presets:" if default_preset && presets.nil?
      end

      def self.validate_predicate!(predicate)
        predicate = predicate.to_sym
        return predicate if VALID_PREDICATES.include?(predicate)

        raise ArgumentError, "#{name}: predicate: must be one of #{VALID_PREDICATES.join(', ')}"
      end

      included do
        class_attribute :cursor_paginatable_order, default: nil
        class_attribute :cursor_paginatable_order_presets, default: nil
        class_attribute :cursor_paginatable_default_preset, default: nil
        class_attribute :cursor_paginatable_order_param, default: :order
        class_attribute :cursor_paginatable_per_page, default: DEFAULT_PER_PAGE
        class_attribute :cursor_paginatable_max_per_page, default: DEFAULT_MAX_PER_PAGE
        class_attribute :cursor_paginatable_bidirectional, default: false
        class_attribute :cursor_paginatable_predicate, default: :auto

        # Real controllers (anything with ActiveSupport::Rescuable) get the 400
        # handlers automatically; bare objects let the errors propagate.
        if respond_to?(:rescue_from)
          rescue_from InvalidCursor, with: :render_invalid_cursor
          rescue_from InvalidOrderPreset, with: :render_invalid_order_preset
        end
      end

      class_methods do
        # Configure the keyset ordering and page-size defaults. Exactly one of
        # order: (a fixed ordering) or order_presets: (named orderings the
        # client picks via ?<order_param>=) is required.
        # Examples:
        #   cursor_paginate_by order: { created_at: :desc }, per_page: 50, max_per_page: 500
        #   cursor_paginate_by order_presets: { newest: { created_at: :desc }, top: { score: :desc } },
        #                      default_preset: :newest, bidirectional: true
        # max_per_page: 0 (or negative) disables the per_page cap.
        def cursor_paginate_by(order: nil, order_presets: nil, default_preset: nil, order_param: :order,
                               per_page: DEFAULT_PER_PAGE, max_per_page: DEFAULT_MAX_PER_PAGE,
                               bidirectional: false, predicate: :auto)
          self.cursor_paginatable_order = order && CursorPaginatable.normalize_order!(order)
          self.cursor_paginatable_order_presets = order_presets && CursorPaginatable.normalize_presets!(order_presets)
          self.cursor_paginatable_default_preset =
            CursorPaginatable.resolve_default_preset!(cursor_paginatable_order_presets, default_preset, order)
          self.cursor_paginatable_order_param = order_param.to_sym
          self.cursor_paginatable_per_page = per_page.to_i
          self.cursor_paginatable_max_per_page = max_per_page.to_i
          self.cursor_paginatable_bidirectional = bidirectional ? true : false
          self.cursor_paginatable_predicate = CursorPaginatable.validate_predicate!(predicate)
        end
      end

      # Run the keyset query (limit + 1 to detect has_more), set the standard
      # response headers, and return the page as a loaded Array (laziness is
      # impossible here: has_more detection materializes limit + 1 rows).
      # Raises InvalidCursor (rescued to a 400 on real controllers) on bad
      # cursors.
      def cursor_paginated(relation, order: nil, per_page: nil, bidirectional: nil)
        @cursor_pagination_meta = nil # never expose a previous call's meta after a failure
        result = cursor_paginate_result(relation, order: order, per_page: per_page, bidirectional: bidirectional)
        @cursor_pagination_meta = result[:meta]
        apply_cursor_pagination_headers(result[:meta])
        result[:records]
      end

      # With no arguments: the meta Hash memoized by the last cursor_paginated
      # call (no extra query; nil if that call failed or never ran). With a
      # relation: runs the query and returns meta WITHOUT setting headers or
      # touching the memo — for body-based pagination (Respondable's meta:).
      def cursor_pagination_meta(relation = nil, order: nil, per_page: nil, bidirectional: nil)
        return @cursor_pagination_meta if relation.nil?

        cursor_paginate_result(relation, order: order, per_page: per_page, bidirectional: bidirectional)[:meta]
      end

      # Public override point (mirrors ErrorHandleable's public handlers):
      # delegates to Respondable#render_error when available.
      def render_invalid_cursor(error)
        return render_error(message: error.message, status: :bad_request, code: "invalid_cursor") if respond_to?(:render_error)

        render json: { success: false, error: { message: error.message, code: "invalid_cursor" } }, status: :bad_request
      end

      # Same override contract for unknown ?order= preset names.
      def render_invalid_order_preset(error)
        return render_error(message: error.message, status: :bad_request, code: "invalid_order_preset") if respond_to?(:render_error)

        render json: { success: false, error: { message: error.message, code: "invalid_order_preset" } }, status: :bad_request
      end

      private

      def cursor_paginate_result(relation, order:, per_page:, bidirectional: nil)
        relation = relation.all if relation.is_a?(Class)
        pairs = cursor_order_pairs(relation, order)
        limit = cursor_per_page(per_page)
        bidi = bidirectional.nil? ? self.class.cursor_paginatable_bidirectional : bidirectional
        cursor = decode_cursor(params[:cursor], pairs, relation.model, bidirectional: bidi)
        fetch = cursor_fetch_page(relation, pairs, limit, cursor)
        { records: fetch[:page],
          meta: cursor_build_meta(relation.model, pairs, limit, fetch, bidi) }
      end

      # A backward ("prev") cursor walks the INVERTED ordering so LIMIT grabs
      # the rows nearest the boundary, then flips the page back to canonical
      # order. reorder (not order) so the keyset columns REPLACE any prior
      # ORDER BY — including a Models::Sortable default_scope order.
      def cursor_fetch_page(relation, pairs, limit, cursor)
        backward = cursor ? cursor[:backward] : false
        effective = backward ? cursor_invert_pairs(pairs) : pairs
        scoped = relation.reorder(effective.to_h)
        scoped = scoped.where(cursor_predicate(relation.model, effective, cursor[:values])) if cursor
        rows = scoped.limit(limit + 1).to_a

        page = rows.first(limit)
        page.reverse! if backward
        { page: page, extra: rows.size > limit, backward: backward, arrived: !cursor.nil? }
      end

      def cursor_invert_pairs(pairs)
        pairs.map { |col, dir| [col, dir == :asc ? :desc : :asc] }
      end

      # The limit+1 probe detects "more" in the direction of travel; the
      # other side is implied by the cursor we arrived on. Cursors are only
      # minted from a non-empty page — an over-walked empty page returns no
      # cursors and both flags false (clients keep their previous tokens).
      # prev_cursor/has_prev appear in the meta only in bidirectional mode,
      # so the forward-only meta shape is unchanged.
      def cursor_build_meta(model, pairs, limit, fetch, bidi)
        page = fetch[:page]
        has_next = page.any? && (fetch[:backward] || fetch[:extra])
        meta = { per_page: limit, count: page.size, has_more: has_next,
                 next_cursor: has_next ? encode_cursor(model, pairs, page.last, "next") : nil }
        meta.merge!(cursor_prev_meta(model, pairs, fetch)) if bidi
        meta
      end

      def cursor_prev_meta(model, pairs, fetch)
        page = fetch[:page]
        has_prev = page.any? && (fetch[:backward] ? fetch[:extra] : fetch[:arrived])
        { has_prev: has_prev,
          prev_cursor: has_prev ? encode_cursor(model, pairs, page.first, "prev") : nil }
      end

      # Resolved [[column, direction], ...] with the primary key appended as a
      # tiebreaker (inheriting the last column's direction) when not declared.
      def cursor_order_pairs(relation, override)
        pairs = override ? CursorPaginatable.normalize_order!(override) : cursor_configured_pairs
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

      def cursor_configured_pairs
        self.class.cursor_paginatable_order || cursor_preset_order_pairs
      end

      # Resolves params[<order_param>] against the allow-listed presets. The
      # param only ever picks a preset NAME — columns stay code-chosen. An
      # unknown name raises (→ 400) rather than silently falling back: a
      # typo'd ?order= must not quietly reorder the walk. Switching presets
      # mid-walk invalidates the cursor via the pinned column:direction list.
      def cursor_preset_order_pairs
        presets = self.class.cursor_paginatable_order_presets
        return nil unless presets

        raw = params[self.class.cursor_paginatable_order_param]
        return presets[self.class.cursor_paginatable_default_preset] if raw.nil? || raw.to_s.strip.empty?

        key = presets.keys.find { |k| k.to_s == raw.to_s }
        return presets[key] if key

        raise InvalidOrderPreset, "Unknown order preset '#{raw}'. Available: #{presets.keys.join(', ')}."
      end

      def cursor_per_page(override)
        requested = (override || params[:per_page]).to_i
        requested = self.class.cursor_paginatable_per_page if requested < 1
        cap = self.class.cursor_paginatable_max_per_page
        cap.positive? ? [requested, cap].min : requested
      end

      # ----- cursor encode/decode -----

      # "o" always pins the CANONICAL column:direction list (scope checks
      # compare against it regardless of travel direction); "d" carries the
      # direction this cursor travels.
      def encode_cursor(model, pairs, record, direction)
        payload = {
          "t" => model.table_name, # pin the table so cross-model replay is rejected
          "o" => pairs.map { |col, dir| "#{col}:#{dir}" },
          "d" => direction,
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

      # nil → no cursor param (first page). Otherwise {values:, backward:}:
      # the boundary values cast back to native types via the model's
      # attribute types, so Arel quotes them correctly per database adapter
      # (SQLite stores datetimes with a space, not ISO "T" — raw string
      # comparison would silently break).
      def decode_cursor(raw, pairs, model, bidirectional:)
        return nil if raw.nil? || raw.to_s.strip.empty?

        payload = parse_cursor_payload(raw.to_s)
        raise InvalidCursor, "Invalid pagination cursor." unless payload

        verify_cursor_scope!(payload, pairs, model)
        direction = cursor_direction!(payload, bidirectional)
        values = payload["v"]
        raise InvalidCursor, "Invalid pagination cursor." unless valid_cursor_values?(values, pairs.size)

        { values: pairs.zip(values).map { |(col, _dir), value| model.type_for_attribute(col.to_s).cast(value) },
          backward: direction == "prev" }
      end

      # Pre-bidirectional cursors carry no "d" — they are forward cursors and
      # stay valid. "prev" requires bidirectional mode: a backward token
      # replayed against a forward-only endpoint is a configuration mismatch,
      # not a first page.
      def cursor_direction!(payload, bidirectional)
        direction = payload["d"] || "next"
        raise InvalidCursor, "Invalid pagination cursor." unless CURSOR_DIRECTIONS.include?(direction)
        raise InvalidCursor, "Cursor does not match the current pagination configuration." if direction == "prev" && !bidirectional

        direction
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

      # ----- keyset WHERE -----
      # Two strategies, same strict lexicographic semantics (the boundary row
      # itself is excluded):
      #   :or  — (c1 > v1) OR (c1 = v1 AND c2 > v2) OR ... with gt/lt per
      #          column direction; portable, supports mixed asc/desc.
      #   :row — (c1, c2, id) > (v1, v2, v3) tuple comparison; lets the
      #          planner walk a composite index directly, but only expresses
      #          uniform directions and needs adapter support.
      def cursor_predicate(model, pairs, values)
        if cursor_row_predicate?(model, pairs)
          cursor_row_predicate(model, pairs, values)
        else
          cursor_or_predicate(model, pairs, values)
        end
      end

      # :auto picks :row when it is expressible (>= 2 uniform-direction
      # columns) and the adapter supports tuples, silently falling back
      # otherwise; an explicit :row raises on mixed directions instead of
      # silently changing strategy.
      def cursor_row_predicate?(model, pairs)
        mode = self.class.cursor_paginatable_predicate
        return false if mode == :or || pairs.size < 2

        uniform = pairs.map(&:last).uniq.size == 1
        if mode == :row
          raise ArgumentError, "#{CursorPaginatable.name}: predicate: :row requires uniform order directions" unless uniform

          return true
        end
        uniform && model.connection.adapter_name.match?(ROW_PREDICATE_ADAPTERS)
      end

      def cursor_row_predicate(model, pairs, values)
        table = model.arel_table
        lhs = Arel::Nodes::Grouping.new(pairs.map { |col, _dir| table[col] })
        rhs = Arel::Nodes::Grouping.new(
          pairs.each_with_index.map { |(col, _dir), i| Arel::Nodes.build_quoted(values[i], table[col]) }
        )
        pairs.first.last == :asc ? Arel::Nodes::GreaterThan.new(lhs, rhs) : Arel::Nodes::LessThan.new(lhs, rhs)
      end

      def cursor_or_predicate(model, pairs, values)
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
        return unless meta.key?(:has_prev)

        response.set_header("X-Has-Prev", meta[:has_prev].to_s)
        response.set_header("X-Prev-Cursor", meta[:prev_cursor]) if meta[:prev_cursor]
      end
    end
  end
end
