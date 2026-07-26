require "active_support/concern"
require "concerns_on_rails/support/scalar_param"

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
    module Paginatable
      extend ActiveSupport::Concern

      DEFAULT_PER_PAGE = 25
      DEFAULT_MAX_PER_PAGE = 200

      included do
        class_attribute :paginatable_per_page, default: DEFAULT_PER_PAGE
        class_attribute :paginatable_max_per_page, default: DEFAULT_MAX_PER_PAGE
      end

      class_methods do
        # Configure the default page size and the hard cap on per_page.
        # Example:
        #   paginate_by per_page: 50, max_per_page: 500
        def paginate_by(per_page: DEFAULT_PER_PAGE, max_per_page: DEFAULT_MAX_PER_PAGE)
          self.paginatable_per_page = per_page.to_i
          self.paginatable_max_per_page = max_per_page.to_i
        end
      end

      # Apply pagination to a relation and set the standard response headers.
      # Returns the paginated relation; the metadata is memoized so a follow-up
      # `pagination_meta` (no argument) reuses it. Safe on empty relations.
      def paginated(relation)
        @paginatable_meta = nil
        page = pagination_page
        per_page = pagination_per_page
        offset = (page - 1) * per_page

        total = paginatable_total(relation)
        total_pages = per_page.positive? ? (total.to_f / per_page).ceil : 0

        records = relation.limit(per_page).offset(offset)

        @paginatable_meta = { total: total, page: page, per_page: per_page, total_pages: total_pages }
        set_pagination_headers(**@paginatable_meta)
        records
      end

      # Pagination metadata WITHOUT applying limit/offset — handy for
      # body-based pagination (compose with Respondable's `meta:`). Call with
      # no argument after `paginated` to reuse its memoized meta — the
      # documented records+meta composition used to run the identical COUNT
      # twice per request. Pass a relation to compute fresh.
      def pagination_meta(relation = nil)
        return @paginatable_meta if relation.nil? && @paginatable_meta

        if relation.nil?
          raise ArgumentError,
                "ConcernsOnRails::Controllers::Paginatable: pagination_meta needs a relation " \
                "(no prior paginated call in this request to reuse)"
        end

        total = paginatable_total(relation)
        per_page = pagination_per_page
        {
          total: total,
          page: pagination_page,
          per_page: per_page,
          total_pages: per_page.positive? ? (total.to_f / per_page).ceil : 0
        }
      end

      private

      # COUNT with the clauses that break or skew it stripped: order/limit/
      # offset are irrelevant, a custom SELECT list would turn into the invalid
      # COUNT(a, b), and count(:all) keeps DISTINCT semantics. A grouped
      # relation counts as a Hash (group => count); the meaningful total is the
      # number of groups.
      def paginatable_total(relation)
        counted = relation.except(:order, :limit, :offset, :select).count(:all)
        counted.is_a?(Hash) ? counted.length : counted
      end

      # Both readers route through ScalarParam: `?page[]=1` / `?page[x]=1`
      # arrive as Array/Parameters, and calling .to_i on those was a 500.
      def pagination_page
        [ConcernsOnRails::Support::ScalarParam.to_i(params[:page], default: 0), 1].max
      end

      def pagination_per_page
        requested = ConcernsOnRails::Support::ScalarParam.to_i(params[:per_page], default: 0)
        requested = self.class.paginatable_per_page if requested < 1
        cap = self.class.paginatable_max_per_page
        cap.positive? ? [requested, cap].min : requested
      end

      def set_pagination_headers(total:, page:, per_page:, total_pages:)
        return unless respond_to?(:response) && response

        response.set_header("X-Total-Count", total.to_s)
        response.set_header("X-Page", page.to_s)
        response.set_header("X-Per-Page", per_page.to_s)
        response.set_header("X-Total-Pages", total_pages.to_s)
      end
    end
  end
end
