require "active_support/concern"

module ConcernsOnRails
  module Controllers
    # Declarative URL-param filtering for index actions. Three modes per filter:
    #
    #   filter_by :status, :category                         # ?status=draft       -> .where(status: 'draft')
    #   filter_by :published, scope: :published              # ?published=1        -> .published
    #   filter_by :q, with: ->(rel, v) { rel.where(...) }    # ?q=foo              -> lambda is called
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

      included do
        class_attribute :filterable_rules, default: {}
      end

      class_methods do
        # Declare one or more filterable params. Modes are mutually exclusive
        # per call; pass either `scope:` or `with:`, or neither (direct where).
        def filter_by(*fields, scope: nil, with: nil)
          raise ArgumentError, "ConcernsOnRails::Controllers::Filterable: at least one field is required" if fields.empty?

          raise ArgumentError, "ConcernsOnRails::Controllers::Filterable: pass either :scope or :with, not both" if scope && with

          new_rules = filterable_rules.dup
          fields.each do |field|
            new_rules[field.to_sym] = { scope: scope, with: with }
          end
          self.filterable_rules = new_rules
        end
      end

      # Apply all declared filters to a relation based on params. Blank values
      # are skipped so unset filters don't narrow the relation.
      def filtered(relation)
        self.class.filterable_rules.each do |field, options|
          value = params[field]
          next if value.blank?

          relation = apply_filter(relation, field, value, options)
        end
        relation
      end

      private

      def apply_filter(relation, field, value, options)
        if options[:with]
          options[:with].call(relation, value)
        elsif options[:scope]
          relation.public_send(options[:scope])
        else
          relation.where(field => value)
        end
      end
    end
  end
end
