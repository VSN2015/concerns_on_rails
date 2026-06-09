require "active_support/concern"

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
      # Returns the paginated relation. Safe on empty relations.
      def paginated(relation)
        page = pagination_page
        per_page = pagination_per_page
        offset = (page - 1) * per_page

        counted = relation.except(:order, :limit, :offset).count
        # `.count` on a grouped relation returns a Hash (group => count); for
        # offset pagination the meaningful total is the number of groups.
        total = counted.is_a?(Hash) ? counted.length : counted
        total_pages = per_page.positive? ? (total.to_f / per_page).ceil : 0

        records = relation.limit(per_page).offset(offset)

        set_pagination_headers(total: total, page: page, per_page: per_page, total_pages: total_pages)
        records
      end

      private

      def pagination_page
        value = params[:page].to_i
        [value, 1].max
      end

      def pagination_per_page
        requested = params[:per_page].to_i
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
