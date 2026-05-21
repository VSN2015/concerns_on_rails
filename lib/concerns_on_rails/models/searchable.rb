require "active_support/concern"

module ConcernsOnRails
  module Models
    # LIKE-based search across one or more columns.
    #
    #   class Article < ApplicationRecord
    #     include ConcernsOnRails::Searchable
    #
    #     searchable_by :title, :body
    #   end
    #
    #   Article.search("hello")            # WHERE title ILIKE '%hello%' OR body ILIKE '%hello%'
    #   Article.search("")                 # no-op — returns the full relation
    #   Article.search("foo").where(...)   # chainable like any scope
    #
    # Uses Arel's `matches`, which emits ILIKE on Postgres and LIKE elsewhere —
    # so case-insensitivity comes for free on PG. The query is escaped before
    # interpolation, so `%` / `_` / `\` from user input are treated as literals.
    module Searchable
      extend ActiveSupport::Concern

      LIKE_ESCAPE = "\\".freeze
      LIKE_SPECIAL = /[\\%_]/

      included do
        class_attribute :searchable_fields, instance_accessor: false, default: []
      end

      class_methods do
        def searchable_by(*fields)
          raise ArgumentError, "ConcernsOnRails::Models::Searchable: at least one field is required" if fields.empty?

          fields.each do |field|
            unless column_names.include?(field.to_s)
              raise ArgumentError,
                    "ConcernsOnRails::Models::Searchable: field '#{field}' does not exist in the database"
            end
          end

          self.searchable_fields = fields.map(&:to_sym)

          scope :search, ->(query) { search_relation(query) }
        end

        def search_relation(query)
          return all if query.nil? || query.to_s.strip.empty?

          escaped = query.to_s.gsub(LIKE_SPECIAL) { |c| "#{LIKE_ESCAPE}#{c}" }
          pattern = "%#{escaped}%"

          predicates = searchable_fields.map { |field| arel_table[field].matches(pattern, LIKE_ESCAPE) }
          where(predicates.reduce { |memo, p| memo.or(p) })
        end
      end
    end
  end
end
