require "active_support/concern"
require "concerns_on_rails/support/column_guard"

# Loaded here — with the concern, on first use — rather than at gem boot, so
# apps that never include Sortable never load acts_as_list.
begin
  require "acts_as_list"
rescue LoadError
  raise ConcernsOnRails::MissingDependency,
        "ConcernsOnRails::Models::Sortable requires the acts_as_list gem. " \
        'Add `gem "acts_as_list"` to your Gemfile to use it.'
end

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
      # A real module (not `class_methods do`) so the helpers aren't constrained
      # by Metrics/BlockLength (the Stateable precedent).
      LABEL = "ConcernsOnRails::Models::Sortable".freeze
      MISSING_MODES = %i[append raise].freeze

      module ClassMethods
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
          field, direction = resolve_sortable_config(field_config, field_options)

          # set class attributes
          self.sortable_default_scope = default_scope ? true : false
          self.sortable_field = field
          self.sortable_direction = direction

          ensure_columns!("ConcernsOnRails::Models::Sortable", sortable_field, types: :integer)

          return unless use_acts_as_list

          # Thread acts_as_list's own options through (scope: for per-group ordering,
          # add_new_at: for where freshly-inserted rows land).
          list_options = { column: sortable_field }
          list_options[:scope] = scope unless scope.nil?
          list_options[:add_new_at] = add_new_at unless add_new_at.nil?
          acts_as_list(list_options)
        end

        # Apply an explicit id order as positions — the "save this drag-and-drop
        # order" operation acts_as_list lacks — in ONE UPDATE (`SET position =
        # CASE id WHEN … END`) inside the current relation, in a transaction.
        # Rows in the relation but not in `ids` are pushed after them in their
        # current order (`missing: :append`) or make the call raise
        # (`missing: :raise`); ids outside the relation, duplicates and an
        # unknown `missing:` raise before anything is written. The first id gets
        # the top position; on a :desc list it gets the highest value instead.
        # Returns the number of rows updated. Bypasses acts_as_list callbacks by
        # design (no per-row shifting).
        def reposition!(ids, missing: :append)
          unless MISSING_MODES.include?(missing)
            raise ArgumentError,
                  "#{LABEL}: missing: must be :append or :raise (got #{missing.inspect})"
          end

          ordered = sortable_reposition_order(sortable_cast_ids(ids), missing)
          return 0 if ordered.empty?

          node = Arel::Nodes::Case.new(arel_table[primary_key])
          sortable_positions_for(ordered).each { |id, position| node.when(id).then(position) }
          transaction { unscoped.where(primary_key => ordered).update_all(sortable_field => node) }
        end

        private

        # Params arrive as Strings; compare on the primary key's own type.
        def sortable_cast_ids(ids)
          type = type_for_attribute(primary_key)
          Array(ids).map { |id| type.cast(id.respond_to?(:id) ? id.id : id) }
        end

        # The relation's members in the requested order, validated: no
        # duplicates, nothing foreign, and the unlisted rest appended (or raised).
        def sortable_reposition_order(ids, missing)
          duplicates = ids.tally.select { |_id, n| n > 1 }.keys
          raise ArgumentError, "#{LABEL}: duplicate id(s) #{duplicates.join(', ')} in ids" if duplicates.any?

          current = all.reorder(sortable_field => sortable_direction, primary_key => :asc).pluck(primary_key)
          unknown = ids - current
          raise ArgumentError, "#{LABEL}: id(s) #{unknown.join(', ')} are not in this relation" if unknown.any?

          rest = current - ids
          if rest.any? && missing == :raise
            raise ArgumentError,
                  "#{LABEL}: #{rest.size} record(s) in this relation are missing from ids (pass missing: :append to push them after)"
          end

          ids + rest
        end

        # [[id, position], ...] from the top of the list; reversed for :desc so
        # the first id sorts first.
        def sortable_positions_for(ordered)
          top = sortable_top_of_list
          positions = Array.new(ordered.size) { |index| top + index }
          positions.reverse! if sortable_direction == :desc
          ordered.zip(positions)
        end

        def sortable_top_of_list
          method_defined?(:acts_as_list_top) ? new.acts_as_list_top : 1
        end

        def resolve_sortable_config(field_config, field_options)
          if field_config.nil? && field_options.any?
            # `sortable_by position: :desc` — the trailing keywords ARE the config.
            field_config = field_options
          elsif field_options.any?
            # `sortable_by :position, ad_new_at: :top` — a typo'd option used to
            # ride into **field_options and vanish silently.
            raise ArgumentError,
                  "ConcernsOnRails::Models::Sortable: unknown option(s): #{field_options.keys.join(', ')}"
          end
          # A bare `sortable_by` keeps the documented defaults (:position asc)
          # instead of crashing on nil (pre-1.22 NoMethodError).
          field_config = sortable_field || :position if field_config.nil?

          field, direction = parse_sortable_config(field_config)
          unless %i[asc desc].include?(direction)
            # Raise instead of the old silent :asc fallback — a misspelled
            # direction reordered the whole default scope without a whisper.
            raise ArgumentError,
                  "ConcernsOnRails::Models::Sortable: direction must be :asc or :desc, got '#{direction}'"
          end
          [field, direction]
        end

        def parse_sortable_config(config)
          if config.is_a?(Hash)
            if config.size > 1
              raise ArgumentError,
                    "ConcernsOnRails::Models::Sortable: pass exactly one field => direction pair, " \
                    "got #{config.inspect}"
            end
            key, value = config.first
            [key.to_sym, value.to_s.to_sym]
          else
            [config.to_sym, :asc]
          end
        end
      end
    end
  end
end
