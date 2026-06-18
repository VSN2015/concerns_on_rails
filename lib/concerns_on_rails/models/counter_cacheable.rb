require "active_support/concern"

module ConcernsOnRails
  module Models
    # Conditional, denormalized association counters ("counter_culture-lite").
    # Rails' native `belongs_to ..., counter_cache: true` maintains exactly one
    # column counting *every* child — it cannot keep an `approved_comments_count`
    # next to a `comments_count`, and it has no way to repair drift after a
    # backfill or a counter_cache-less write. This concern, declared on the
    # CHILD, keeps one or many parent columns in sync, each with an optional
    # `if:` condition, and ships a `recount_counter_caches!` repair method.
    #
    #   class Comment < ApplicationRecord
    #     include ConcernsOnRails::CounterCacheable
    #     belongs_to :post                       # declare the belongs_to FIRST
    #     belongs_to :author, class_name: "User"
    #
    #     counter_cacheable_by :post                          # posts.comments_count
    #     counter_cacheable_by :post, count: :approved_comments_count,
    #                                 if: -> { approved? }    # conditional counter
    #     counter_cacheable_by :author, count: :posts_count, touch: true
    #   end
    #
    #   Post.find(1).comments_count            # maintained on create/destroy/update
    #   Comment.recount_counter_caches!        # repair/backfill every counter
    #
    # Behaviour:
    #   * create/destroy adjust the counter by ±1 when the foreign key is present
    #     and the `if:` condition holds for the record's current state.
    #   * update handles BOTH a foreign-key reparent (the row moved to another
    #     parent) AND a condition flip (the `if:` result changed): the old parent
    #     is decremented if it used to count the row, the new parent incremented
    #     if it counts it now. A no-op save writes nothing.
    #   * Adjustments use `update_counters` — a single SQL `COALESCE(col,0) ± 1`,
    #     atomic under concurrency — and run inside the record's own save
    #     transaction, so a rolled-back save rolls back the counter too.
    #
    # Notes:
    #   * The `belongs_to` must be declared BEFORE the macro (the reflection is
    #     validated at declaration time). Polymorphic associations are not
    #     supported in this version.
    #   * Do NOT also set native `counter_cache: true` on the same column — both
    #     would fire and double-count.
    #   * Counters track the PERSISTED record. Writes that skip callbacks
    #     (`update_column(s)`, `update_all`, `delete`, raw SQL) are not tracked —
    #     run `recount_counter_caches!` to reconcile.
    #   * `if:` conditions should read the record's OWN columns; the previous
    #     state is reconstructed from the changed attributes, not the
    #     associations.
    #   * `recount_counter_caches!` rewrites every parent's counter and, for a
    #     conditional counter, scans the children in Ruby (portable across
    #     adapters, but O(n)) — a maintenance operation, run it offline.
    #   * Reach for the `counter_culture` gem when you need multi-level rollups,
    #     delta columns, or after-commit execution.
    module CounterCacheable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Models::CounterCacheable".freeze

      included do
        class_attribute :counter_cacheable_rules, instance_accessor: false, default: []

        after_create  :counter_cacheable_run_create
        after_update  :counter_cacheable_run_update
        after_destroy :counter_cacheable_run_destroy
      end

      module ClassMethods
        # Declare one counter. Repeatable — each call maintains another column
        # (rules accumulate, reassigned never mutated, so subclasses inherit).
        # `count:` defaults to "<table_name>_count" (e.g. comments → comments_count).
        def counter_cacheable_by(association, count: nil, touch: false, **options)
          association = association.to_sym
          condition = options[:if]
          extra = options.keys - [:if]
          raise ArgumentError, "#{LABEL}: unknown option(s): #{extra.join(', ')}" unless extra.empty?

          reflection = reflect_on_association(association)
          validate_counter_cacheable!(association, reflection, condition, touch)

          count_column = (count || "#{table_name}_count").to_sym
          counter_cacheable_ensure_parent_column!(reflection, count_column)

          self.counter_cacheable_rules = counter_cacheable_rules + [{
            association: association, count_column: count_column,
            condition: condition, touch: touch ? true : false
          }]
        end

        # Recompute every (or one) counter from scratch — drift repair / backfill.
        # Returns { count_column => parents_with_a_nonzero_count }.
        def recount_counter_caches!(only_association = nil)
          rules = counter_cacheable_rules
          rules = rules.select { |r| r[:association] == only_association.to_sym } if only_association

          rules.to_h do |rule|
            [rule[:count_column], counter_cacheable_recount_rule(rule)]
          end
        end

        private

        def validate_counter_cacheable!(association, reflection, condition, touch)
          if reflection.nil?
            raise ArgumentError,
                  "#{LABEL}: no association `#{association}` — declare " \
                  "`belongs_to :#{association}` before `counter_cacheable_by :#{association}`"
          end
          unless reflection.macro == :belongs_to
            raise ArgumentError, "#{LABEL}: `#{association}` must be a belongs_to association (got #{reflection.macro})"
          end
          raise ArgumentError, "#{LABEL}: polymorphic association `#{association}` is not supported" if reflection.polymorphic?
          raise ArgumentError, "#{LABEL}: :if must be callable (respond to #call)" unless condition.nil? || condition.respond_to?(:call)
          return if [true, false].include?(touch)

          raise ArgumentError, "#{LABEL}: :touch must be true or false"
        end

        # Validate the column on the PARENT table when its class is already
        # loaded and connected; defer silently otherwise (load-order tolerant).
        def counter_cacheable_ensure_parent_column!(reflection, count_column)
          klass = begin
            reflection.klass
          rescue StandardError
            nil
          end
          return unless klass
          return unless counter_cacheable_table_exists?(klass)
          return if klass.column_names.include?(count_column.to_s)

          raise ArgumentError,
                "#{LABEL}: '#{count_column}' does not exist in the database (table: #{klass.table_name})"
        end

        def counter_cacheable_table_exists?(klass)
          klass.table_exists?
        rescue StandardError
          false
        end

        def counter_cacheable_recount_rule(rule)
          reflection = reflect_on_association(rule[:association])
          fk = reflection.foreign_key
          parent_class = reflection.klass
          column = rule[:count_column]
          condition = rule[:condition]

          tally = if condition
                    counter_cacheable_recount_tally(fk, condition)
                  else
                    unscoped.where.not(fk => nil).group(fk).count
                  end

          parent_class.unscoped.update_all(column => 0)
          tally.each do |parent_id, n|
            next if parent_id.nil? || n.to_i.zero?

            parent_class.unscoped.where(parent_class.primary_key => parent_id).update_all(column => n)
          end
          tally.count { |_id, n| n.to_i.positive? }
        end

        def counter_cacheable_recount_tally(foreign_key, condition)
          tally = Hash.new(0)
          unscoped.where.not(foreign_key => nil).find_each do |record|
            tally[record[foreign_key]] += 1 if record.instance_exec(&condition)
          end
          tally
        end
      end

      private

      def counter_cacheable_run_create
        self.class.counter_cacheable_rules.each do |rule|
          next unless counter_cacheable_counted_now?(rule)

          counter_cacheable_adjust(rule, counter_cacheable_fk_value(rule), 1)
        end
      end

      def counter_cacheable_run_destroy
        self.class.counter_cacheable_rules.each do |rule|
          next unless counter_cacheable_counted_now?(rule)

          counter_cacheable_adjust(rule, counter_cacheable_fk_value(rule), -1)
        end
      end

      def counter_cacheable_run_update
        self.class.counter_cacheable_rules.each { |rule| counter_cacheable_apply_update(rule) }
      end

      # The create × destroy × (reparent + condition-flip) matrix.
      def counter_cacheable_apply_update(rule)
        fk = counter_cacheable_reflection(rule).foreign_key.to_s
        changes = counter_cacheable_changes
        new_fk = self[fk]
        old_fk = changes.key?(fk) ? changes[fk].first : new_fk

        old_counted = counter_cacheable_counted_previously?(rule)
        new_counted = counter_cacheable_counted_now?(rule)

        if old_fk == new_fk
          counter_cacheable_apply_same_parent(rule, new_fk, old_counted, new_counted)
        else
          counter_cacheable_apply_reparent(rule, old_fk, new_fk, old_counted, new_counted)
        end
      end

      # Same parent — only a condition flip can change the count.
      def counter_cacheable_apply_same_parent(rule, parent_id, old_counted, new_counted)
        return if old_counted == new_counted

        counter_cacheable_adjust(rule, parent_id, new_counted ? 1 : -1)
      end

      # Foreign key changed — settle the old parent and the new one independently.
      def counter_cacheable_apply_reparent(rule, old_fk, new_fk, old_counted, new_counted)
        counter_cacheable_adjust(rule, old_fk, -1) if old_fk && old_counted
        counter_cacheable_adjust(rule, new_fk, 1) if new_fk && new_counted
      end

      def counter_cacheable_adjust(rule, parent_id, delta)
        return if parent_id.nil?

        counters = { rule[:count_column] => delta }
        counters[:touch] = true if rule[:touch]
        counter_cacheable_reflection(rule).klass.update_counters(parent_id, counters)
      end

      def counter_cacheable_fk_value(rule)
        self[counter_cacheable_reflection(rule).foreign_key]
      end

      def counter_cacheable_reflection(rule)
        self.class.reflect_on_association(rule[:association])
      end

      def counter_cacheable_counted_now?(rule)
        condition = rule[:condition]
        return true unless condition

        instance_exec(&condition) ? true : false
      end

      # Evaluate the condition against the record as it was BEFORE this save by
      # temporarily restoring the changed attributes to their previous values.
      def counter_cacheable_counted_previously?(rule)
        condition = rule[:condition]
        return true unless condition

        counter_cacheable_with_previous_attributes { instance_exec(&condition) ? true : false }
      end

      def counter_cacheable_with_previous_attributes
        changes = counter_cacheable_changes
        return yield if changes.empty?

        restore = {}
        changes.each do |attr, (old, _new)|
          restore[attr] = self[attr]
          self[attr] = old
        end
        begin
          yield
        ensure
          restore.each { |attr, value| self[attr] = value }
        end
      end

      # { "attr" => [old, new] } for the just-completed save. saved_changes is
      # Rails 5.1+; previous_changes is the 5.0 fallback.
      def counter_cacheable_changes
        respond_to?(:saved_changes) ? saved_changes : previous_changes
      end
    end
  end
end
