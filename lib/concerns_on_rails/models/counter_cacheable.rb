require "active_support/concern"
require "concerns_on_rails/support/column_guard"

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
    #     and the `if:` condition holds for the record's PERSISTED state. A
    #     destroy only decrements when its DELETE actually removed the row (like
    #     Rails' native counter cache), so destroying a stale second instance of
    #     an already-deleted row, or a never-saved record, writes nothing — and
    #     an unsaved reparent or condition flip is ignored: the row that goes is
    #     the row the database held.
    #   * update handles BOTH a foreign-key reparent (the row moved to another
    #     parent) AND a condition flip (the `if:` result changed): the old parent
    #     is decremented if it used to count the row, the new parent incremented
    #     if it counts it now. A no-op save writes nothing.
    #   * Adjustments use `update_counters` — a single SQL `COALESCE(col,0) ± 1`,
    #     atomic under concurrency — and run inside the record's own save
    #     transaction, so a rolled-back save rolls back the counter too.
    #   * A `belongs_to ..., primary_key: :code` is honoured everywhere: the
    #     parent row is addressed by the association key (not its `id`), both by
    #     the live adjustments and by `recount_counter_caches!`.
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
      # Distinguishes "parents: not passed" (repair every parent) from an
      # explicit nil, which would otherwise silently widen a scoped repair into
      # a full-table zero-and-rewrite.
      UNSET = Object.new

      included do
        class_attribute :counter_cacheable_rules, instance_accessor: false, default: []

        after_create  :counter_cacheable_run_create
        after_update  :counter_cacheable_run_update
        # Destroy is handled in #destroy_row (below), not an after_destroy: only
        # there is it known whether the DELETE removed a row.
      end

      module ClassMethods
        include ConcernsOnRails::Support::ColumnGuard

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
        # `parents:` (ids, records, or a relation of the parent class) limits the
        # repair to those parents — zeroed and re-tallied — leaving every other
        # row untouched, so fixing one imported post is O(its children), not
        # O(the table). Needs the association when more than one is declared.
        # Returns { count_column => parents_with_a_nonzero_count }.
        def recount_counter_caches!(only_association = nil, parents: UNSET)
          rules = counter_cacheable_rules_for(only_association)
          parent_ids = counter_cacheable_parent_ids(parents, rules)
          return rules.to_h { |rule| [rule[:count_column], 0] } if parent_ids && parent_ids.empty?

          rules.to_h do |rule|
            [rule[:count_column], counter_cacheable_recount_rule(rule, parent_ids)]
          end
        end

        private

        # An association nobody declared a counter for would otherwise filter the
        # rules down to nothing and report a silent success — or, with `parents:`,
        # crash on the reflection that isn't there.
        def counter_cacheable_rules_for(only_association)
          return counter_cacheable_rules unless only_association

          rules = counter_cacheable_rules.select { |rule| rule[:association] == only_association.to_sym }
          return rules unless rules.empty?

          declared = counter_cacheable_rules.map { |rule| rule[:association] }.uniq
          raise ArgumentError,
                "#{LABEL}: no counter declared for association `#{only_association}` " \
                "(declared: #{declared.empty? ? 'none' : declared.join(', ')})"
        end

        # Not passed → every parent. Otherwise normalize records/relations to
        # the ASSOCIATION KEY values the children's foreign keys hold (the
        # parent's `id`, or its `belongs_to primary_key:` column); bare values
        # are the parent's primary-key ids, as documented. The rules must all
        # target one association or the ids are ambiguous. An explicit nil is a
        # mistake, not "every parent": it would turn a scoped repair into a
        # full-table rewrite.
        def counter_cacheable_parent_ids(parents, rules)
          return nil if parents.equal?(UNSET)
          raise ArgumentError, "#{LABEL}: parents: cannot be nil — omit it to repair every parent" if parents.nil?

          reflection = counter_cacheable_sole_reflection(rules)
          parent_class = reflection.klass
          key = counter_cacheable_parent_key(reflection)
          if parents.is_a?(ActiveRecord::Relation)
            counter_cacheable_check_parent_class!(parents.klass, parent_class)
            return parents.pluck(key)
          end

          ids = Array(parents).map do |parent|
            next parent unless parent.is_a?(ActiveRecord::Base)

            counter_cacheable_check_parent_class!(parent.class, parent_class)
            parent.id
          end
          counter_cacheable_ids_to_keys(parent_class, key, ids)
        end

        # Bare ids (and records, normalized to ids above) are primary-key
        # values; a custom association key needs one lookup to translate them.
        def counter_cacheable_ids_to_keys(parent_class, key, ids)
          return ids if key == parent_class.primary_key.to_s || ids.empty?

          parent_class.unscoped.where(parent_class.primary_key => ids).pluck(key)
        end

        # The ids address one parent table, so every rule in play must target the
        # same association — otherwise there is no telling which table they mean.
        def counter_cacheable_sole_reflection(rules)
          associations = rules.map { |rule| rule[:association] }.uniq
          if associations.size > 1
            raise ArgumentError,
                  "#{LABEL}: parents: needs the association when more than one is declared (#{associations.join(', ')})"
          end

          reflect_on_association(associations.first)
        end

        # The parent column the child's foreign key points at: `primary_key:`
        # on the belongs_to, else the parent's primary key.
        def counter_cacheable_parent_key(reflection)
          reflection.association_primary_key.to_s
        end

        # Ids from the wrong table would zero and rewrite whichever parent rows
        # happen to share them — silent corruption from a plausible mix-up, in
        # the one method whose job is destructive repair.
        def counter_cacheable_check_parent_class!(given, expected)
          return if given <= expected

          raise ArgumentError,
                "#{LABEL}: parents: must contain #{expected.name} records (got #{given.name})"
        end

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

          validate_counter_cacheable_touch!(touch)
        end

        def validate_counter_cacheable_touch!(touch)
          raise ArgumentError, "#{LABEL}: :touch must be true or false" unless [true, false].include?(touch)
          return unless touch && ActiveRecord::VERSION::MAJOR < 6

          # `update_counters(..., touch: true)` exists on Rails 6.0+; on 5.x the
          # option would be read as a counter column literally named `touch` and
          # produce a SQL error at runtime — fail loudly at macro time instead.
          raise ArgumentError, "#{LABEL}: `touch: true` requires Rails >= 6.0"
        end

        # Validate the column on the PARENT table when its class is already
        # loaded and connected; defer silently otherwise (load-order tolerant —
        # schema reachability is ColumnGuard's shared skip-don't-crash rule).
        def counter_cacheable_ensure_parent_column!(reflection, count_column)
          klass = begin
            reflection.klass
          rescue StandardError
            nil
          end
          return unless klass

          ensure_columns_on!(LABEL, klass, count_column, types: :integer)
        end

        def counter_cacheable_recount_rule(rule, parent_ids = nil)
          reflection = reflect_on_association(rule[:association])
          fk = reflection.foreign_key
          parent_class = reflection.klass
          key = counter_cacheable_parent_key(reflection)
          column = rule[:count_column]
          condition = rule[:condition]

          # One transaction so a crash mid-repair can't leave every counter at
          # the zeroed intermediate state. A scoped repair locks its (bounded)
          # set of parent rows BEFORE tallying, so a child inserted concurrently
          # either lands in the tally or waits for the rewrite instead of being
          # dropped between the two. The bare call can't lock the whole table —
          # which is why it stays an offline operation.
          tally = parent_class.transaction do
            targets = parent_class.unscoped
            if parent_ids
              targets = targets.where(key => parent_ids)
              targets.lock.pluck(parent_class.primary_key)
            end

            children = unscoped.where.not(fk => nil)
            children = children.where(fk => parent_ids) if parent_ids
            counts = condition ? counter_cacheable_recount_tally(children, fk, condition) : children.group(fk).count

            targets.update_all(column => 0)
            counter_cacheable_apply_tally(parent_class, key, column, counts)
            counts
          end
          tally.count { |_id, n| n.to_i.positive? }
        end

        # Grouped by tally value so the repair costs O(distinct counts)
        # statements instead of one UPDATE per parent row. The tally is keyed by
        # foreign-key value, i.e. the parent's association key.
        def counter_cacheable_apply_tally(parent_class, key, column, tally)
          tally.group_by { |_id, n| n.to_i }.each do |n, pairs|
            next if n.zero?

            ids = pairs.map(&:first).compact
            next if ids.empty?

            parent_class.unscoped.where(key => ids).update_all(column => n)
          end
        end

        def counter_cacheable_recount_tally(children, foreign_key, condition)
          tally = Hash.new(0)
          children.find_each do |record|
            tally[record[foreign_key]] += 1 if record.instance_exec(&condition)
          end
          tally
        end
      end

      private

      def counter_cacheable_run_create
        counter_cacheable_flush(counter_cacheable_presence_adjustments(1))
      end

      # Rails' own counter cache decrements here, and only when the DELETE
      # affected a row: a second, stale instance of an already-destroyed row
      # (or a never-saved record, which never reaches destroy_row) must not
      # decrement again. Runs inside the destroy transaction, before freeze.
      def destroy_row
        affected_rows = super
        counter_cacheable_run_destroy if affected_rows.to_i.positive?
        affected_rows
      end

      # The row being deleted is the PERSISTED one, so its parent and its `if:`
      # verdict are read from the database values — an unsaved reparent or
      # condition flip in memory must not redirect the decrement.
      def counter_cacheable_run_destroy
        adjustments = counter_cacheable_with_attributes(counter_cacheable_unsaved_changes) do
          counter_cacheable_presence_adjustments(-1) { |rule| !counter_cacheable_destroyed_by_parent?(rule) }
        end
        counter_cacheable_flush(adjustments)
      end

      # Rails' native counter cache skips the decrement when the child is being
      # destroyed by the parent's own `dependent: :destroy` on the same foreign
      # key: that parent row is about to be deleted, and bumping it first (the
      # UPDATE also increments lock_version) makes the parent's own DELETE fail
      # with StaleObjectError. Counters on other associations still decrement.
      # Only a has_many marks the parent as going away: a has_one sets
      # destroyed_by_association when a REPLACEMENT destroys the old record,
      # and there the parent survives and must be decremented.
      def counter_cacheable_destroyed_by_parent?(rule)
        by = destroyed_by_association
        return false unless by && by.macro == :has_many

        Array(by.foreign_key).map(&:to_s) == Array(counter_cacheable_reflection(rule).foreign_key).map(&:to_s)
      end

      def counter_cacheable_run_update
        counter_cacheable_flush(
          self.class.counter_cacheable_rules.flat_map { |rule| counter_cacheable_update_adjustments(rule) }
        )
      end

      # create/destroy share one shape: ±1 on the current parent when counted.
      # An optional block filters the rules (destroy skips the parent doing the
      # destroying).
      def counter_cacheable_presence_adjustments(delta)
        self.class.counter_cacheable_rules.filter_map do |rule|
          next if block_given? && !yield(rule)
          next unless counter_cacheable_counted_now?(rule)

          counter_cacheable_adjustment(rule, counter_cacheable_fk_value(rule), delta)
        end
      end

      # The create × destroy × (reparent + condition-flip) matrix.
      def counter_cacheable_update_adjustments(rule)
        fk = counter_cacheable_reflection(rule).foreign_key.to_s
        changes = counter_cacheable_changes
        new_fk = self[fk]
        old_fk = changes.key?(fk) ? changes[fk].first : new_fk

        old_counted = counter_cacheable_counted_previously?(rule)
        new_counted = counter_cacheable_counted_now?(rule)

        if old_fk == new_fk
          # Same parent — only a condition flip can change the count.
          return [] if old_counted == new_counted

          [counter_cacheable_adjustment(rule, new_fk, new_counted ? 1 : -1)]
        else
          # Foreign key changed — settle the old parent and the new one independently.
          [(counter_cacheable_adjustment(rule, old_fk, -1) if old_counted),
           (counter_cacheable_adjustment(rule, new_fk, 1) if new_counted)]
        end
      end

      # `parent_key` is the foreign-key value: the parent's association key
      # (its `id`, or the belongs_to's `primary_key:` column).
      def counter_cacheable_adjustment(rule, parent_key, delta)
        return nil if parent_key.nil?

        reflection = counter_cacheable_reflection(rule)
        { klass: reflection.klass, key_column: reflection.association_primary_key.to_s, parent_key: parent_key,
          column: rule[:count_column], delta: delta, touch: rule[:touch] }
      end

      # One update_counters per distinct (parent class, key column, key value):
      # sibling rules adjusting the same parent (comments_count +
      # approved_comments_count) ride a single UPDATE instead of one statement
      # each. Addressed by the association key, not `id` — the class-level
      # update_counters(id, ...) would hit whichever row's id equals the key.
      def counter_cacheable_flush(adjustments)
        groups = adjustments.compact.group_by { |adj| [adj[:klass], adj[:key_column], adj[:parent_key]] }
        groups.each do |(klass, key_column, parent_key), group|
          counters = counter_cacheable_merged_counters(group)
          next if counters.empty?

          counters[:touch] = true if group.any? { |adj| adj[:touch] }
          klass.unscoped.where(key_column => parent_key).update_counters(counters)
        end
      end

      # Sum per column, dropping zero-sum entries (nothing to write).
      def counter_cacheable_merged_counters(group)
        group.each_with_object(Hash.new(0)) { |adj, acc| acc[adj[:column]] += adj[:delta] }
             .reject { |_column, delta| delta.zero? }
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

        counter_cacheable_with_attributes(counter_cacheable_changes) { instance_exec(&condition) ? true : false }
      end

      # Temporarily put each changed attribute back to the FIRST value of its
      # [old, new] pair, run the block, then restore the current values.
      def counter_cacheable_with_attributes(changes)
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

      # { "attr" => [in_database, in_memory] } for changes not yet saved.
      def counter_cacheable_unsaved_changes
        respond_to?(:changes_to_save) ? changes_to_save : changes
      end
    end
  end
end
