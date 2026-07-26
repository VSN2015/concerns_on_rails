require "active_support/concern"
require "concerns_on_rails/support/column_guard"
require "acts_as_list"

module ConcernsOnRails
  module Models
    module Sortable
      extend ActiveSupport::Concern

      # instance methods
      # include Sortable in model to enable sorting
      # Example:
      #   class Task < ApplicationRecord
      #     include Sortable
      #     sortable_by :priority
      #   end
      included do
        # declare class attributes
        class_attribute :sortable_field, instance_accessor: false
        class_attribute :sortable_direction, instance_accessor: false
        class_attribute :sortable_default_scope, instance_accessor: false

        # set default values
        self.sortable_field ||= :position
        self.sortable_direction ||= :asc
        self.sortable_default_scope = true if sortable_default_scope.nil?

        # Explicit ordering that works regardless of the default_scope setting.
        scope :sorted, -> { order(sortable_field => sortable_direction) }

        # Evaluated lazily so `sortable_by ..., default_scope: false` takes
        # effect. Column validation happens once in the macro, not here — the
        # old per-relation-construction ensure_columns! re-checked the schema
        # on every query. A sticky ordering default_scope breaks `.last`,
        # `distinct.pluck`, window queries etc.; opt out and chain `.sorted`.
        default_scope { sortable_default_scope ? order(sortable_field => sortable_direction) : all }
      end

      # class methods
      # Example: Task.sortable_by(priority: :asc)
      class_methods do
        include ConcernsOnRails::Support::ColumnGuard

        # Define sortable field and direction.
        # Example:
        #   sortable_by :position
        #   sortable_by position: :asc
        #   sortable_by position: :desc
        #
        #   sortable_by :position, use_acts_as_list: false
        #   sortable_by :position, scope: :list_id        # independent ordering within each list
        #   sortable_by :position, add_new_at: :top       # new records go to the top of the list
        #   sortable_by :position, default_scope: false   # no sticky ordering; chain .sorted
        def sortable_by(field_config = nil, use_acts_as_list: true, scope: nil, add_new_at: nil,
                        default_scope: true, **field_options)
          field_config = field_options if field_config.nil? && field_options.any?
          # A bare `sortable_by` keeps the documented defaults (:position asc)
          # instead of crashing on nil (pre-1.22 NoMethodError).
          field_config = sortable_field || :position if field_config.nil?

          self.sortable_default_scope = default_scope ? true : false

          # parse field_config
          field, direction = parse_sortable_config(field_config)

          # validate direction and must be :asc or :desc
          direction = :asc unless %i[asc desc].include?(direction)

          # set class attributes
          self.sortable_field = field
          self.sortable_direction = direction

          ensure_columns!("ConcernsOnRails::Models::Sortable", sortable_field)

          return unless use_acts_as_list

          # Thread acts_as_list's own options through (scope: for per-group ordering,
          # add_new_at: for where freshly-inserted rows land).
          list_options = { column: sortable_field }
          list_options[:scope] = scope unless scope.nil?
          list_options[:add_new_at] = add_new_at unless add_new_at.nil?
          acts_as_list(list_options)
        end

        private

        def parse_sortable_config(config)
          if config.is_a?(Hash)
            # extract key and value
            # when we call .first, we get the first key-value pair
            # Example: { position: :asc }.first => ["position", :asc]
            key, value = config.first
            [key.to_sym, value.to_sym]
          else
            [config.to_sym, :asc]
          end
        end
      end
    end
  end
end
