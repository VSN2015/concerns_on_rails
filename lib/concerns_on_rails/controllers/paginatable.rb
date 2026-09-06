require "active_support/concern"
require "concerns_on_rails/support/scalar_param"
require "concerns_on_rails/support/link_header"

module ConcernsOnRails
  module Controllers
    # Adds simple offset-based pagination to a controller, with no runtime
    # dependency on Kaminari/will_paginate. Use it like:
    #
    #   class ArticlesController < ApplicationController
    #     include ConcernsOnRails::Controllers::Paginatable
    #     paginate_by per_page: 25, max_per_page: 200   # optional
    #
    #     def index
    #       render json: paginated(Article.all)
    #     end
    #   end
    #
    # `paginated` also takes an in-memory collection — an Array, Set, Range or
    # any other non-Hash Enumerable — so results assembled outside the
    # database (an external API, a loaded association, a hand-built list of
    # Structs) get the same slicing, headers and `pagination_meta`:
    #
    #   def search
    #     render json: paginated(ExternalCatalog.search(params[:q]))
    #   end
    #
    # Every paginated response also carries an RFC 8288 `Link` header with
    # first/prev/next/last URLs rebuilt from the current request (other query
    # params preserved) — the GitHub convention, so clients can follow links
    # instead of computing page numbers. `paginate_by link_header: false` turns
    # it off.
    module Paginatable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Controllers::Paginatable".freeze
      DEFAULT_PER_PAGE = 25
      DEFAULT_MAX_PER_PAGE = 200

      included do
        class_attribute :paginatable_per_page, default: DEFAULT_PER_PAGE
        class_attribute :paginatable_max_per_page, default: DEFAULT_MAX_PER_PAGE
        class_attribute :paginatable_link_header, default: true
        # Where page / per_page are read from — a path of param names (`["page"]`,
        # or `["page", "number"]` for JSON:API's page[number]).
        class_attribute :paginatable_page_param, default: %w[page].freeze
        class_attribute :paginatable_per_page_param, default: %w[per_page].freeze
      end

      # A real module (not `class_methods do`) so the macro and its private
      # helpers share one `private` without tripping RuboCop's scope analysis.
      module ClassMethods
        # Configure the default page size, the hard cap on per_page, and whether
        # the RFC 8288 Link header is emitted.
        # Example:
        #   paginate_by per_page: 50, max_per_page: 500, link_header: false
        def paginate_by(per_page: DEFAULT_PER_PAGE, max_per_page: DEFAULT_MAX_PER_PAGE, link_header: true,
                        page_param: nil, per_page_param: nil, style: :flat)
          self.paginatable_per_page = per_page.to_i
          self.paginatable_max_per_page = max_per_page.to_i
          self.paginatable_link_header = link_header ? true : false
          defaults = paginatable_style_params!(style)
          self.paginatable_page_param = paginatable_param_path!(:page_param, page_param || defaults[0])
          self.paginatable_per_page_param = paginatable_param_path!(:per_page_param, per_page_param || defaults[1])
        end

        private

        # :flat → page / per_page; :jsonapi → page[number] / page[size].
        def paginatable_style_params!(style)
          case style.to_sym
          when :flat then [%w[page], %w[per_page]]
          when :jsonapi then [%w[page number], %w[page size]]
          else raise ArgumentError, "#{LABEL}: style: must be :flat or :jsonapi (got #{style.inspect})"
          end
        end

        # A name or a non-empty path of names, normalized to Strings.
        def paginatable_param_path!(option, value)
          path = Array(value)
          valid = path.any? && path.all? { |segment| (segment.is_a?(Symbol) || segment.is_a?(String)) && !segment.to_s.empty? }
          raise ArgumentError, "#{LABEL}: #{option}: must be a param name or a path of names (got #{value.inspect})" unless valid

          path.map(&:to_s).freeze
        end
      end

      # Apply pagination to a relation or an in-memory collection and set the
      # standard response headers. A relation comes back as a relation with
      # LIMIT/OFFSET applied (still lazy); an Enumerable comes back as the
      # current page's Array slice (`[]` past the last page). The metadata is
      # memoized so a follow-up `pagination_meta` (no argument) reuses it.
      # Safe on empty collections.
      #
      # `total:` says the collection IS the current page already — an external
      # API or search service returned page N of a result set it counted for
      # you. Nothing is sliced, limited or counted: the records come back
      # untouched and `total` drives X-Total-Count, X-Total-Pages and the Link
      # header. Ask the upstream for the same page/per_page you read here.
      def paginated(collection, total: nil)
        @paginatable_meta = nil
        source = paginatable_source(collection)
        pre_paginated = !total.nil?
        page = pagination_page
        per_page = pagination_per_page
        offset = (page - 1) * per_page

        total = pre_paginated ? paginatable_validate_total!(total) : paginatable_total(source)
        total_pages = per_page.positive? ? (total.to_f / per_page).ceil : 0

        records =
          if pre_paginated
            source # the caller already fetched exactly this page: an Array stays an Array, a relation is not limited
          elsif source.is_a?(Array)
            source[offset, per_page] || []
          else
            source.limit(per_page).offset(offset)
          end

        @paginatable_meta = { total: total, page: page, per_page: per_page, total_pages: total_pages }
        set_pagination_headers(**@paginatable_meta)
        set_pagination_links(page: page, total_pages: total_pages)
        records
      end

      # Pagination metadata WITHOUT applying limit/offset (or slicing) — handy
      # for body-based pagination (compose with Respondable's `meta:`). Call
      # with no argument after `paginated` to reuse its memoized meta — the
      # documented records+meta composition used to run the identical COUNT
      # twice per request. Pass a relation or collection to compute fresh.
      # With `total:` the COUNT is skipped (and the collection may be omitted).
      def pagination_meta(collection = nil, total: nil)
        return @paginatable_meta if collection.nil? && total.nil? && @paginatable_meta

        total = paginatable_meta_total(collection, total)
        per_page = pagination_per_page
        {
          total: total,
          page: pagination_page,
          per_page: per_page,
          total_pages: per_page.positive? ? (total.to_f / per_page).ceil : 0
        }
      end

      private

      # Relations — anything answering `limit` and `offset`: an
      # ActiveRecord::Relation, an association CollectionProxy, a model class —
      # pass through untouched so they keep paginating in SQL. Any other
      # non-Hash Enumerable is materialized ONCE into an Array, so an
      # Enumerator is not consumed twice (once to count, once to slice). A Hash
      # is rejected rather than silently paginated as [key, value] pairs.
      def paginatable_source(collection)
        return collection if collection.respond_to?(:limit) && collection.respond_to?(:offset)
        return collection.to_a if collection.is_a?(Enumerable) && !collection.is_a?(Hash)

        hint = collection.is_a?(Hash) ? " — call .to_a to paginate a Hash as [key, value] pairs" : ""
        raise ArgumentError,
              "#{LABEL}: expected an ActiveRecord relation or an Enumerable (Array, Set, Range, ...), " \
              "got #{collection.class}#{hint}"
      end

      # `total:` wins (validated); otherwise COUNT the collection; neither
      # given and nothing memoized is a caller error.
      def paginatable_meta_total(collection, total)
        return paginatable_validate_total!(total) unless total.nil?
        return paginatable_total(paginatable_source(collection)) unless collection.nil?

        raise ArgumentError,
              "#{LABEL}: pagination_meta needs a relation or collection " \
              "(no prior paginated call in this request to reuse)"
      end

      def paginatable_validate_total!(total)
        return total if total.is_a?(Integer) && total >= 0

        raise ArgumentError, "#{LABEL}: total: must be a non-negative Integer (got #{total.inspect})"
      end

      # Arrays already know their size. Relations COUNT with the clauses that
      # break or skew it stripped: order/limit/offset are irrelevant, a custom
      # SELECT list would turn into the invalid COUNT(a, b), and count(:all)
      # keeps DISTINCT semantics. A grouped relation counts as a Hash
      # (group => count); the meaningful total is the number of groups.
      def paginatable_total(source)
        return source.size if source.is_a?(Array)

        counted = source.except(:order, :limit, :offset, :select).count(:all)
        counted.is_a?(Hash) ? counted.length : counted
      end

      # Both readers route through ScalarParam: `?page[]=1` / `?page[x]=1`
      # arrive as Array/Parameters, and calling .to_i on those was a 500.
      def pagination_page
        [ConcernsOnRails::Support::ScalarParam.to_i(pagination_param(self.class.paginatable_page_param), default: 0), 1].max
      end

      def pagination_per_page
        requested = ConcernsOnRails::Support::ScalarParam.to_i(pagination_param(self.class.paginatable_per_page_param), default: 0)
        requested = self.class.paginatable_per_page if requested < 1
        cap = self.class.paginatable_max_per_page
        cap.positive? ? [requested, cap].min : requested
      end

      # Dig the configured path out of params: `["page"]` → params[:page];
      # `["page", "number"]` → params[:page][:number]. A scalar where a Hash
      # is expected yields nil (→ the default), like any other garbage.
      def pagination_param(path)
        path.reduce(params) do |node, key|
          break nil unless node.respond_to?(:[]) && !node.is_a?(String) && !node.is_a?(Array)

          node[key]
        end
      end

      # The `overrides` for LinkHeader.url_for that set the page number under the
      # configured name — replacing the whole nested Hash for a path so the
      # other keys in it (page[size]) survive.
      def pagination_page_override(number)
        path = self.class.paginatable_page_param
        return { path.first.to_sym => number } if path.size == 1

        nested = request.query_parameters.to_h.transform_keys(&:to_s)[path.first]
        nested = nested.is_a?(Hash) ? nested.deep_dup : {}
        node = nested
        path[1...-1].each { |key| node = (node[key] = node[key].is_a?(Hash) ? node[key] : {}) }
        node[path.last] = number
        { path.first.to_sym => nested }
      end

      def set_pagination_headers(total:, page:, per_page:, total_pages:)
        return unless respond_to?(:response) && response

        response.set_header("X-Total-Count", total.to_s)
        response.set_header("X-Page", page.to_s)
        response.set_header("X-Per-Page", per_page.to_s)
        response.set_header("X-Total-Pages", total_pages.to_s)
      end

      # Link: <…?page=1>; rel="first", <…?page=1>; rel="prev", <…?page=3>;
      # rel="next", <…?page=5>; rel="last". prev/next only when such a page
      # exists; past the end, prev points at the last page. Nothing is emitted
      # for an empty collection, when disabled, or without a real request.
      def set_pagination_links(page:, total_pages:)
        return unless pagination_links_applicable?(total_pages)

        page_url = ->(number) { ConcernsOnRails::Support::LinkHeader.url_for(request, **pagination_page_override(number)) }
        ConcernsOnRails::Support::LinkHeader.append(
          response,
          first: page_url.call(1),
          prev: page > 1 ? page_url.call([page - 1, total_pages].min) : nil,
          next: page < total_pages ? page_url.call(page + 1) : nil,
          last: page_url.call(total_pages)
        )
      end

      def pagination_links_applicable?(total_pages)
        return false unless self.class.paginatable_link_header && total_pages.positive?
        return false unless respond_to?(:response) && response

        ConcernsOnRails::Support::LinkHeader.available?(self)
      end
    end
  end
end
