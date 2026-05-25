require "active_support/concern"

module ConcernsOnRails
  module Controllers
    # Whitelisted association sideloading + sparse fieldsets for JSON APIs.
    # Same allow-list philosophy as Controllers::Sortable: a client can only ask
    # for associations/fields you've explicitly permitted, so `?include=` can
    # never trigger an arbitrary `.includes` (N+1 / data-exposure risk).
    #
    #   class ArticlesController < ApplicationController
    #     include ConcernsOnRails::Controllers::Includable
    #
    #     includable :author, :comments,
    #                fields: { articles: %i[id title], authors: %i[id name] }
    #
    #     def index
    #       render json: with_includes(Article.all),
    #              include: requested_includes,
    #              fields: requested_fields
    #     end
    #   end
    #
    # URL params:
    #   ?include=author,comments         -> eager-loads only whitelisted associations
    #   ?fields[articles]=id,title       -> sanitized down to the allowed columns
    #
    # `requested_includes` / `requested_fields` return sanitized values you can
    # hand to your serializer; they never mutate the rendered output themselves.
    module Includable
      extend ActiveSupport::Concern

      included do
        class_attribute :includable_associations, default: []
        class_attribute :includable_fields, default: {}
      end

      class_methods do
        # Whitelist sideloadable associations and (optionally) the columns
        # exposable per resource via sparse fieldsets.
        def includable(*associations, fields: {})
          self.includable_associations = associations.map(&:to_sym)
          self.includable_fields = fields.each_with_object({}) do |(table, cols), memo|
            memo[table.to_sym] = Array(cols).map(&:to_sym)
          end
        end
      end

      # Eager-load only the whitelisted associations requested via ?include=.
      # Returns the relation unchanged when nothing valid was requested.
      def with_includes(relation)
        associations = requested_includes
        associations.empty? ? relation : relation.includes(*associations)
      end

      # Sanitized association list: requested ∩ allow-list.
      def requested_includes
        requested = params[:include].to_s.split(",").map { |token| token.strip.to_sym }
        requested & self.class.includable_associations
      end

      # Sanitized sparse fieldsets: { table => [cols] }, each intersected with
      # the allowed columns for that table. Unknown tables/columns are dropped.
      def requested_fields
        raw = params[:fields]
        return {} unless raw.respond_to?(:each_pair)

        allowed = self.class.includable_fields
        raw.each_with_object({}) do |(table, cols), memo|
          key = table.to_sym
          next unless allowed.key?(key)

          permitted = split_field_list(cols) & allowed[key]
          memo[key] = permitted unless permitted.empty?
        end
      end

      private

      def split_field_list(cols)
        list = cols.is_a?(Array) ? cols : cols.to_s.split(",")
        list.map { |col| col.to_s.strip.to_sym }
      end
    end
  end
end
