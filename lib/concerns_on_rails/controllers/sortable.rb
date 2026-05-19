require "active_support/concern"

module ConcernsOnRails
  module Controllers
    # URL-param-driven ordering for index actions, with a strict allow-list to
    # prevent ordering by arbitrary user-supplied columns (SQL injection / data
    # exposure risk).
    #
    #   class ArticlesController < ApplicationController
    #     include ConcernsOnRails::Controllers::Sortable
    #     sortable_by :created_at, :title, :published_at, default: :created_at, direction: :desc
    #
    #     def index
    #       render json: sorted(Article.all)
    #     end
    #   end
    #
    # Reads params[:sort] and params[:direction]. Falls back to the configured
    # defaults if either is missing or invalid.
    module Sortable
      extend ActiveSupport::Concern

      VALID_DIRECTIONS = %i[asc desc].freeze

      included do
        class_attribute :sortable_allowed_fields, default: []
        class_attribute :sortable_default_field, default: nil
        class_attribute :sortable_default_direction, default: :asc
      end

      class_methods do
        # Whitelist sortable columns and set defaults.
        # Example:
        #   sortable_by :created_at, :title, default: :created_at, direction: :desc
        def sortable_by(*allowed_fields, default: nil, direction: :asc)
          raise ArgumentError, "ConcernsOnRails::Controllers::Sortable: at least one field is required" if allowed_fields.empty?

          self.sortable_allowed_fields = allowed_fields.map(&:to_sym)
          self.sortable_default_field = (default || allowed_fields.first).to_sym
          self.sortable_default_direction = VALID_DIRECTIONS.include?(direction.to_sym) ? direction.to_sym : :asc
        end
      end

      # Apply ordering to a relation based on params[:sort] / params[:direction].
      # Falls back to defaults; never orders by a non-whitelisted column.
      def sorted(relation)
        field = sort_field
        return relation unless field

        relation.order(field => sort_direction)
      end

      private

      def sort_field
        requested = params[:sort]&.to_sym
        if requested && self.class.sortable_allowed_fields.include?(requested)
          requested
        else
          self.class.sortable_default_field
        end
      end

      def sort_direction
        raw = params[:direction]
        requested = raw && raw.to_s.downcase.to_sym
        VALID_DIRECTIONS.include?(requested) ? requested : self.class.sortable_default_direction
      end
    end
  end
end
