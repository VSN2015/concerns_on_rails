require "weakref"
require "active_support/concern"
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/callable"
require "concerns_on_rails/support/batch_ops"
require "concerns_on_rails/support/locking"

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
    #   * Optimistic locking on the parent: each adjustment's UPDATE bumps the
    #     parent's `lock_version` in SQL, and the parent instance the child's
    #     association holds (the one `post.comments.create!` was called on, or
    #     the one passed as `post:`) gets the bump — and the counter delta —
    #     mirrored in memory (increment!'s in-memory half; a counter the
    #     caller assigned and has not saved is left pending), so it saves
    #     afterwards without StaleObjectError. A rolled-back save of the child
    #     takes the mirror back off it. Other loaded copies of the parent go
    #     stale, as they would natively.
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
    #     adapters, but O(n)) — a maintenance operation, run it offline. On an
    #     STI table it tallies every class's rows under that class's own rule,
    #     so it repairs the shared column from whichever class it is called on.
    #   * Reach for the `counter_culture` gem when you need multi-level rollups,
    #     delta columns, or after-commit execution.
    module CounterCacheable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Models::CounterCacheable".freeze
      # Distinguishes "parents: not passed" (repair every parent) from an
      # explicit nil, which would otherwise silently widen a scoped repair into
      # a full-table zero-and-rewrite.
      UNSET = Object.new

      # Takes one in-memory mirror (#counter_cacheable_sync_target) back off
      # the parent instance when the UPDATE it mirrors is rolled back — a
      # caller's Rollback, a later callback raising, a Stateable/HookedWrite
      # veto. Without it the parent was left one version (and one count)
      # ahead of its row, and its next save raised StaleObjectError.
      #
      # The undo is its own transaction record, enrolled in the transaction
      # the UPDATE ran in, so Rails tells it exactly when that UPDATE is
      # undone: a savepoint's rollback reaches the records enrolled in it, a
      # released savepoint hands its records to the parent, and the outermost
      # rollback reaches everything left (6.0–8.1 drive the same four-method
      # protocol). Enrolling the CHILD instead — the record that was saved —
      # held every child created in a long transaction until it ended (Rails
      # holds a callback-less record only weakly), and it missed one case
      # entirely: a savepoint released into a `joinable: false` transaction
      # is COMMITTED at once (that is where after_commit runs there), so the
      # child never heard of the outer rollback. The undo follows its
      # UPDATE into such a parent instead, and forgets it only once no
      # transaction is left open.
      #
      # Memory: the undo holds the parent only WEAKLY (a parent nobody holds
      # any more needs no undo), never the child, and there is one undo per
      # (transaction, parent): every further mirror onto that parent in that
      # transaction adds to it, and a savepoint's undo that follows its
      # UPDATE into a still-open transaction merges into the one open there.
      # A batch inside a long transaction — or inside the transaction that
      # transactional tests, `console --sandbox` and DatabaseCleaner wrap
      # everything in — therefore keeps neither its parents nor its children
      # alive, and holds one small object per parent.
      #
      # Order-independence: Rails rolls records back oldest first, and it may
      # already have restored the parent itself (a parent with after_commit
      # callbacks, saved in the same transaction, is restored before the undo
      # runs, and that restore turns the mirrored counter into an "unsaved
      # change"). So each column (the counters, and lock_version) is moved
      # back only while it is still the mirrors' value: unchanged since (also
      # true for a `becomes` copy sharing the attributes), or holding exactly
      # the value they left it at — tracked on the parent instance. A value
      # the caller assigned since is left alone.
      class MirrorUndo
        LEDGER = :@concerns_on_rails_counter_mirror
        OPEN = :@concerns_on_rails_counter_undo

        # Note one mirror onto `target` (an UPDATE through `klass` moved
        # `counters` by their deltas, and bumped lock_version when `bumped`).
        # Nothing to undo outside a transaction: the UPDATE committed on its own.
        def self.record(connection, target, klass, counters, bumped)
          return unless connection.transaction_open?
          return if counters.empty? && !bumped

          remember(target, klass, counters, bumped)
          transaction = connection.current_transaction
          bumps = bumped ? 1 : 0
          open = open_for(target, transaction)
          return open.add(counters, bumps) if open

          undo = new(connection, target, klass)
          undo.add(counters, bumps)
          undo.enroll(transaction, target)
        end

        # The parent's list of open undos (one per transaction level holding a
        # mirror), replaced, never mutated, since a dup of the parent shares
        # the ivar. Marshal — a Rails.cache write of the parent under the
        # pre-7.1 marshalling format — dumps it as empty: an undo references
        # the connection and its transaction, which cannot be dumped and mean
        # nothing in another process.
        class OpenList
          attr_reader :undos

          def initialize(undos)
            @undos = undos.freeze
          end

          def marshal_dump
            []
          end

          def marshal_load(_data)
            @undos = [].freeze
          end
        end

        def self.undos_on(target)
          target.instance_variable_get(OPEN)&.undos || []
        end

        # The undo open in `transaction` for `target`.
        def self.open_for(target, transaction)
          undos_on(target).find { |undo| undo.open_in?(transaction, target) }
        end

        # Keep only the undos still worth finding; drop the ivar when none is,
        # so a parent outside any transaction carries nothing.
        def self.keep_open(target, undos)
          if undos.empty?
            target.remove_instance_variable(OPEN) if target.instance_variable_defined?(OPEN)
          else
            target.instance_variable_set(OPEN, OpenList.new(undos))
          end
        end

        # The value each just-mirrored column now holds. The Hash is
        # replaced, never mutated: a dup of the parent shares the ivar.
        def self.remember(target, klass, counters, bumped)
          names = counters.keys
          names += [klass.locking_column] if bumped
          ledger = target.instance_variable_get(LEDGER) || {}
          target.instance_variable_set(LEDGER, ledger.merge(names.to_h { |name| [name, target[name]] }))
        end

        def initialize(connection, target, klass)
          @connection = connection
          @transaction = nil
          @target = WeakRef.new(target)
          @klass = klass
          @counters = Hash.new(0)
          @bumps = 0
          @settled = false
        end

        def add(counters, bumps)
          counters.each { |name, delta| @counters[name] += delta }
          @bumps += bumps
        end

        def open_in?(transaction, target)
          findable? && @transaction.equal?(transaction) && target.equal?(alive_target)
        end

        # Still worth finding: not settled, and its transaction not finished.
        # A savepoint's released (finalized) transaction handed this undo to
        # its parent, where Rails still settles it, but where no lookup can
        # tell it apart from a newer savepoint's undo.
        def findable?
          !@settled && !@transaction.nil? && !@transaction.state.finalized?
        end

        def enroll(transaction, target)
          @transaction = transaction
          @connection.add_transaction_record(self)
          open = self.class.undos_on(target).select { |undo| !undo.equal?(self) && undo.findable? }
          self.class.keep_open(target, open + [self])
        end

        # Never forwarded to the (weakly held, maybe collected) parent.
        def inspect
          "#<#{self.class.name} settled=#{@settled} counters=#{@counters.to_h} bumps=#{@bumps}>"
        end

        # The transaction-record protocol. No callbacks of its own.
        def trigger_transactional_callbacks?
          false
        end

        def before_committed!; end

        # A savepoint released into a non-joinable transaction, or the end of
        # the outermost one. Only the latter makes the UPDATE durable.
        def committed!(**)
          return if @settled

          @connection.transaction_open? ? follow(@connection.current_transaction) : settle!
        end

        def rolledback!(**)
          return if @settled

          settle!
          undo!
        end

        protected

        attr_reader :counters, :bumps

        def alive_target
          @target.weakref_alive? ? @target.__getobj__ : nil
        rescue WeakRef::RefError
          nil
        end

        private

        # Follow the UPDATE into the transaction the savepoint was released
        # into, merged into the undo already open there for this parent.
        def follow(transaction)
          parent = alive_target
          return settle! if parent.nil?

          open = self.class.open_for(parent, transaction)
          if open
            open.add(counters, bumps)
            settle!
          else
            enroll(transaction, parent)
          end
        end

        # Done: drop the transaction, and leave the parent's list.
        def settle!
          @settled = true
          @transaction = nil
          parent = alive_target
          self.class.keep_open(parent, self.class.undos_on(parent).select(&:findable?)) if parent
        end

        def undo!
          parent = alive_target
          return if parent.nil? || parent.frozen?

          ledger = parent.instance_variable_get(LEDGER) || {}
          moves(parent).each { |name, delta| ledger = move_back(parent, ledger, name, delta) }
          parent.instance_variable_set(LEDGER, ledger)
        end

        # { column => delta } to take back: the counters, then lock_version.
        def moves(parent)
          moves = @counters.reject { |_name, delta| delta.zero? }
          lock_loaded = @klass.locking_enabled? && parent.has_attribute?(@klass.locking_column)
          @bumps.positive? && lock_loaded ? moves.merge(@klass.locking_column => @bumps) : moves
        end

        # Move `name` back by `delta` while it is still the mirrors' value.
        def move_back(parent, ledger, name, delta)
          current = parent[name]
          mirrors_value = !parent.will_save_change_to_attribute?(name) || (ledger.key?(name) && current == ledger[name])
          return ledger unless mirrors_value

          value = current.to_i - delta
          parent[name] = value
          parent.send(:clear_attribute_change, name)
          ledger.merge(name => value)
        end
      end

      included do
        class_attribute :counter_cacheable_rules, instance_accessor: false, default: []

        after_create :counter_cacheable_run_create
        after_update :counter_cacheable_run_update
        # Destroy is handled in #destroy_row (below), not an after_destroy: only
        # there is it known whether the DELETE removed a row.
      end

      module ClassMethods
        include ConcernsOnRails::Support::ColumnGuard

        # Declare one counter. Repeatable — each call maintains another column
        # (rules accumulate, reassigned never mutated, so subclasses inherit).
        # A rule is keyed by (association, count column): re-declaring the same
        # counter REPLACES that rule, in place, for this class — so an STI
        # subclass can narrow an inherited counter with `if:` — where appending
        # a second rule made both fire and double-count every row.
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

          counter_cacheable_store_rule(
            association: association, count_column: count_column,
            condition: condition, touch: touch ? true : false
          )
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

        def counter_cacheable_store_rule(rule)
          key = rule.values_at(:association, :count_column)
          rules = counter_cacheable_rules
          index = rules.index { |existing| existing.values_at(:association, :count_column) == key }
          self.counter_cacheable_rules = index ? rules.dup.tap { |copy| copy[index] = rule } : rules + [rule]
        end

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

            children = base_class.unscoped.where.not(fk => nil)
            children = children.where(fk => parent_ids) if parent_ids
            counts = counter_cacheable_tally(children, fk, rule)

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

        # { parent key => count } for one (association, column) counter. The
        # column is shared by every class of an STI tree, and each class may
        # carry its own rule for it (a subclass narrowing it with `if:`), so
        # the rows are tallied per stored type under THAT class's effective
        # rule and summed: a recount agrees with the live counts whichever
        # class of the tree it is called on — the parent no longer counts
        # subclass rows under its own rule, and a subclass no longer zeroes
        # the column and re-tallies its own rows only. A table without an
        # inheritance column is the one-class case.
        def counter_cacheable_tally(children, foreign_key, rule)
          type_column = inheritance_column.to_s
          return counter_cacheable_rule_tally(children, foreign_key, rule) unless base_class.column_names.include?(type_column)

          key = rule.values_at(:association, :count_column)
          children.distinct.pluck(type_column).each_with_object(Hash.new(0)) do |type, tally|
            klass = counter_cacheable_sti_class(type)
            effective = counter_cacheable_rule_on(klass || base_class, key)
            next unless effective

            rows = counter_cacheable_type_rows(children.where(type_column => type), type_column, klass, effective)
            counter_cacheable_rule_tally(rows, foreign_key, effective).each { |id, n| tally[id] += n }
          end
        end

        # A stored type that no longer resolves (`klass` nil) can't be
        # instantiated, so a conditional scan loads those rows WITHOUT the
        # inheritance column: they then load as the base class, whose rule
        # they fall back to. An unconditional rule never loads a row.
        def counter_cacheable_type_rows(rows, type_column, klass, rule)
          return rows if klass || rule[:condition].nil?

          rows.select(*(base_class.column_names - [type_column]))
        end

        # The class a row stored as `type` loads as — blank => the base class,
        # exactly as the loader decides — resolved WITHOUT building a record
        # (`instantiate` would run after_find/after_initialize on a fabricated,
        # type-only row). nil for a type that no longer resolves (a removed or
        # renamed subclass): the caller falls back to the base class's rule
        # rather than failing the whole repair, as the pure-SQL tally never did.
        def counter_cacheable_sti_class(type)
          type.blank? ? base_class : base_class.send(:find_sti_class, type)
        rescue ActiveRecord::SubclassNotFound
          nil
        end

        # The rule `klass` applies for this (association, column) counter, or nil.
        def counter_cacheable_rule_on(klass, key)
          return nil unless klass.respond_to?(:counter_cacheable_rules)

          klass.counter_cacheable_rules.find { |candidate| candidate.values_at(:association, :count_column) == key }
        end

        def counter_cacheable_rule_tally(children, foreign_key, rule)
          condition = rule[:condition]
          condition ? counter_cacheable_recount_tally(children, foreign_key, condition) : children.group(foreign_key).count
        end

        def counter_cacheable_recount_tally(children, foreign_key, condition)
          tally = Hash.new(0)
          ConcernsOnRails::Support::BatchOps.each_record(children) do |record|
            tally[record[foreign_key]] += 1 if ConcernsOnRails::Support::Callable.invoke(record, condition)
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
      # condition flip in memory must not redirect the decrement. So is the
      # class judging it: the persisted STI type's, not an unsaved one's.
      def counter_cacheable_run_destroy
        adjustments = counter_cacheable_with_attributes(counter_cacheable_unsaved_changes) do
          counter_cacheable_presence_adjustments(-1) { |rule, judge| !counter_cacheable_destroyed_by_parent?(rule, judge) }
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
      def counter_cacheable_destroyed_by_parent?(rule, judge)
        by = destroyed_by_association
        return false unless by && by.macro == :has_many

        Array(by.foreign_key).map(&:to_s) == Array(counter_cacheable_reflection(rule, judge).foreign_key).map(&:to_s)
      end

      def counter_cacheable_run_update
        was, now = counter_cacheable_update_judges
        keys = [was, now].uniq.flat_map { |judge| counter_cacheable_rules_of(judge) }
                         .map { |rule| rule.values_at(:association, :count_column) }.uniq
        counter_cacheable_flush(
          keys.flat_map do |key|
            counter_cacheable_update_adjustments([was, counter_cacheable_rule_of(was, key)],
                                                 [now, counter_cacheable_rule_of(now, key)])
          end
        )
      end

      # create/destroy share one shape: ±1 on the current parent when counted,
      # under the rules of the class the row's type resolves to. An optional
      # block filters the rules (destroy skips the parent doing the destroying).
      def counter_cacheable_presence_adjustments(delta)
        judge = counter_cacheable_judge(counter_cacheable_type)
        counter_cacheable_rules_of(judge).filter_map do |rule|
          next if block_given? && !yield(rule, judge)
          next unless counter_cacheable_counted_now?(rule)

          counter_cacheable_adjustment(rule, counter_cacheable_fk_value(rule, judge), delta, judge)
        end
      end

      # The create × destroy × (reparent + condition-flip) matrix for one
      # counter. `was` and `now` are [class, rule]: the class judging the row
      # before / after the save and its rule for this counter (nil when that
      # class keeps none, i.e. the row is not counted in that state).
      def counter_cacheable_update_adjustments((was_judge, was_rule), (now_judge, now_rule))
        old_fk, new_fk = counter_cacheable_fk_move([was_judge, was_rule], [now_judge, now_rule])
        old_counted = counter_cacheable_counted_previously?(was_rule)
        new_counted = counter_cacheable_counted_now?(now_rule)
        decrement = -> { counter_cacheable_adjustment(was_rule, old_fk, -1, was_judge) }
        increment = -> { counter_cacheable_adjustment(now_rule, new_fk, 1, now_judge) }

        if old_fk == new_fk
          # Same parent — only a condition flip (or a type change) can change the count.
          return [] if old_counted == new_counted

          return [new_counted ? increment.call : decrement.call]
        end

        # Foreign key changed — settle the old parent and the new one independently.
        [(decrement.call if old_counted), (increment.call if new_counted)]
      end

      # [old, new] foreign-key value across the save, read through the rule
      # judging the row now (or before, when its new class keeps no such counter).
      def counter_cacheable_fk_move(was, now)
        judge, rule = now.last ? now : was
        fk = counter_cacheable_reflection(rule, judge).foreign_key.to_s
        changes = counter_cacheable_changes
        [changes.key?(fk) ? changes[fk].first : self[fk], self[fk]]
      end

      # The class whose rules judge the row before this save and the one
      # judging it now. They differ only when the save changed the STI type
      # (`becomes!`, or the inheritance column assigned): the old state is
      # then counted under the old type's class and the new state under the
      # new one's, as recount_counter_caches! tallies each stored type —
      # judging both under the receiving class left the counter drifted.
      def counter_cacheable_update_judges
        now = counter_cacheable_judge(counter_cacheable_type)
        column = self.class.inheritance_column.to_s
        changes = counter_cacheable_changes
        return [now, now] unless counter_cacheable_sti_row? && changes.key?(column)

        [counter_cacheable_judge(changes[column].first), now]
      end

      # The class a row stored as `type` loads as, resolved as the recount
      # resolves it (a type that no longer resolves falls back to the base
      # class). A row without a (loaded) inheritance column is judged by its
      # own class.
      def counter_cacheable_judge(type)
        return self.class unless counter_cacheable_sti_row?
        return self.class if type == self.class.sti_name

        self.class.send(:counter_cacheable_sti_class, type) || self.class.base_class
      end

      def counter_cacheable_sti_row?
        has_attribute?(self.class.inheritance_column.to_s)
      end

      def counter_cacheable_type
        self[self.class.inheritance_column.to_s] if counter_cacheable_sti_row?
      end

      # A class of the tree that never included the concern keeps no counters.
      def counter_cacheable_rules_of(judge)
        judge.respond_to?(:counter_cacheable_rules) ? judge.counter_cacheable_rules : []
      end

      def counter_cacheable_rule_of(judge, key)
        self.class.send(:counter_cacheable_rule_on, judge, key)
      end

      # `parent_key` is the foreign-key value: the parent's association key
      # (its `id`, or the belongs_to's `primary_key:` column).
      def counter_cacheable_adjustment(rule, parent_key, delta, judge = self.class)
        return nil if parent_key.nil?

        reflection = counter_cacheable_reflection(rule, judge)
        { klass: reflection.klass, key_column: reflection.association_primary_key.to_s, parent_key: parent_key,
          column: rule[:count_column], delta: delta, touch: rule[:touch], association: rule[:association] }
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

          touch = group.any? { |adj| adj[:touch] }
          affected = klass.unscoped.where(key_column => parent_key).update_counters(touch ? counters.merge(touch: true) : counters)
          counter_cacheable_sync_targets(klass, key_column, parent_key, group, counters) if affected.positive?
        end
      end

      # The UPDATE above bumped the parent row's lock_version (update_counters
      # goes through update_all), but no parent instance. Rails' native counter
      # cache adjusts the loaded belongs_to target with increment!, which
      # mirrors the counter AND the lock_version bump in memory; without that
      # the very parent `post.comments.create!` was called on raised
      # StaleObjectError on its next save. Same here, for every instance this
      # record's associations hold for that row — once per instance, however
      # many rules (associations) share the UPDATE. Only under optimistic
      # locking: elsewhere the loaded parent is left exactly as before
      # (documented: reload it to read the counter).
      def counter_cacheable_sync_targets(klass, key_column, parent_key, group, counters)
        return unless klass.locking_enabled?

        targets = group.map { |adj| adj[:association] }.uniq.filter_map do |name|
          target = counter_cacheable_held_target(name)
          target if counter_cacheable_target_row?(target, key_column, parent_key)
        end
        targets.uniq(&:object_id).each { |target| counter_cacheable_sync_target(target, klass, counters) }
      end

      # What this record's association `name` holds — nil also when its class
      # does not declare `name`: a rule judged under another class of the STI
      # tree may name an association only that class declares.
      def counter_cacheable_held_target(name)
        association(name).target if self.class.reflect_on_association(name)
      end

      # The instance is a live copy of the adjusted row — matched by its key,
      # so a reparent syncs the new parent the writer assigned or the OLD one
      # a foreign-key reassignment left loaded, whichever the UPDATE touched.
      def counter_cacheable_target_row?(target, key_column, parent_key)
        target.is_a?(ActiveRecord::Base) && target.persisted? && !target.frozen? &&
          target.has_attribute?(key_column) && target[key_column].to_s == parent_key.to_s
      end

      # increment!'s in-memory half: each counter moves by its delta (COALESCE
      # to 0, like the SQL) and stays clean — a counter the caller assigned
      # and has not saved is theirs to write, so it is left pending — then the
      # lock_version bump. Mirroring the counter is what keeps the lock sync
      # safe: a current lock_version over a stale count would let a full-row
      # save (partial updates off) write the old count back.
      def counter_cacheable_sync_target(target, klass, counters)
        applied = counter_cacheable_apply_counters(target, counters)
        bumped = ConcernsOnRails::Support::Locking.mirror_bump!(target, klass)
        MirrorUndo.record(klass.connection, target, klass, applied, bumped)
      end

      # Move each (clean, loaded) counter up by its delta; the columns moved.
      def counter_cacheable_apply_counters(target, counters)
        counters.filter_map do |column, delta|
          name = column.to_s
          next unless target.has_attribute?(name)
          next if target.will_save_change_to_attribute?(name)
          # attr_readonly: never written on update, and assigning it raises
          # under raise_on_assign_to_attr_readonly (7.1+). Left as loaded.
          next if target.class.readonly_attributes.include?(name)

          target[name] = target[name].to_i + delta
          target.send(:clear_attribute_change, name)
          [name, delta]
        end.to_h
      end

      # Sum per column, dropping zero-sum entries (nothing to write).
      def counter_cacheable_merged_counters(group)
        group.each_with_object(Hash.new(0)) { |adj, acc| acc[adj[:column]] += adj[:delta] }
             .reject { |_column, delta| delta.zero? }
      end

      def counter_cacheable_fk_value(rule, judge = self.class)
        self[counter_cacheable_reflection(rule, judge).foreign_key]
      end

      # Looked up on the judging class: after a type change its rule may name
      # an association this record's own class does not declare.
      def counter_cacheable_reflection(rule, judge = self.class)
        judge.reflect_on_association(rule[:association])
      end

      # A nil rule: the judging class keeps no such counter, so the row is not
      # counted in that state.
      def counter_cacheable_counted_now?(rule)
        return false unless rule

        condition = rule[:condition]
        return true unless condition

        ConcernsOnRails::Support::Callable.invoke(self, condition) ? true : false
      end

      # Evaluate the condition against the record as it was BEFORE this save by
      # temporarily restoring the changed attributes to their previous values.
      def counter_cacheable_counted_previously?(rule)
        return false unless rule

        condition = rule[:condition]
        return true unless condition

        counter_cacheable_with_attributes(counter_cacheable_changes) { ConcernsOnRails::Support::Callable.invoke(self, condition) ? true : false }
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
