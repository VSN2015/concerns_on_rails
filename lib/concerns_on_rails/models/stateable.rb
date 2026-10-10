require "active_support/concern"
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/affix"
require "concerns_on_rails/support/batch_ops"
require "concerns_on_rails/support/hooked_write"
require "concerns_on_rails/support/locking"

module ConcernsOnRails
  module Models
    # Lightweight, string-backed state machine — the common 80% of a state
    # machine without an AASM-sized dependency.
    #
    #   class Article < ApplicationRecord
    #     include ConcernsOnRails::Stateable
    #
    #     stateable_by :status,
    #                  states: %i[draft pending published archived],
    #                  default: :draft,
    #                  transitions: {
    #                    publish: { from: %i[draft pending], to: :published },
    #                    archive: { to: :archived }          # :from omitted => any state
    #                  }
    #   end
    #
    # Generates, for each state (method names honor prefix:/suffix:):
    #   * predicate  — article.draft?       => status == "draft"
    #   * scope      — Article.draft        => where(status: "draft")
    #   * setter     — article.published!   => update!(status: "published")  (unguarded)
    #
    # And for each declared transition:
    #   * event!     — article.publish!     => guarded; raises InvalidTransition from a bad state
    #   * guard?     — article.may_publish? => whether the transition is allowed now
    #
    # Plus a generic `transition_to!(state)`.
    #
    # Per-event hooks: define `before_<event>` / `after_<event>` (affixed like the
    # event method — `before_status_publish` with prefix: true) and they fire
    # around that guarded transition, inside the generic before_transition /
    # after_transition pair and the same transaction.
    #
    # `timestamps: true` (or a list of states) stamps `<state>_at = Time.current`
    # in the same write as the state change — guarded events, direct setters
    # and transition_to! alike — so "when was it published / archived?" needs no
    # callback. The columns are checked at macro time (typed :datetime in the
    # migration hint, and a stamp Rails owns — `created_at`/`updated_at` — is
    # refused); the default state is not stamped on create.
    #
    # Options for stateable_by: default:, transitions:, prefix:, suffix:, lock:,
    # timestamps: (prefix:/suffix: take `true` to use the field name, or a
    # literal string/symbol).
    #
    # Notes:
    #   * String columns only (store the state name) — not integer-backed like Rails enum.
    #   * A state or event whose generated method/scope would override one the
    #     class already has — an AR method (`valid?`, `lock!`) or another
    #     concern's (`.active`, `restore!`) — raises ArgumentError at macro
    #     time; use prefix:/suffix: to disambiguate. Exception: a scope that is
    #     still SoftDeletable's/Publishable's/Schedulable's include-time
    #     default on this class's own singleton (the concern included BEFORE
    #     stateable_by), which that concern's affixing macro renames (called
    #     before or after this one) — until it does, calling the shared scope
    #     raises.
    #   * Re-declaring (same class or an STI subclass) replaces the config and
    #     the generated methods: names the new declaration no longer lists are
    #     removed (hidden in a subclass), unless the class redefined them
    #     itself. An omitted default: keeps the earlier
    #     one while it is still a declared state (else, or with `default: nil`,
    #     the column's DB default applies).
    #   * Guarded transitions check the in-memory state: two processes firing the
    #     same <event>! concurrently can both pass the guard (check-then-write).
    #     `lock: true` closes that race — each <event>! locks the row and
    #     re-checks the guard against the row's state first. A record without
    #     unsaved changes is reloaded under the lock (with_lock). One WITH
    #     unsaved changes can't be reloaded, so only its state column is read
    #     (SELECT <state> ... FOR UPDATE) and adopted, and the changes save
    #     with the transition, as with `lock: false` — under optimistic
    #     locking a stale one raises StaleObjectError. One SELECT per
    #     transition.
    module Stateable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Models::Stateable".freeze

      # Raised when a guarded transition is attempted from a disallowed state.
      class InvalidTransition < StandardError; end

      # The module a re-declaring subclass hides its parent's stale generated
      # methods in (see ClassMethods#stateable_hide_inherited!).
      class RetiredMethods < Module; end

      # Valid stateable_by keyword options (everything besides field/states:).
      OPTIONS = %i[default transitions prefix suffix lock timestamps].freeze

      # Columns Rails owns. A state named `created` or `updated` derives one of
      # them as its `<state>_at`, and ColumnGuard cannot catch it — the column
      # exists — so every write into that state would quietly rewrite the row's
      # creation time (or fight the automatic touch).
      RESERVED_STAMP_COLUMNS = %w[created_at created_on updated_at updated_on].freeze

      # Called by a state scope that shares its name with another concern's
      # include-time default scope (see ClassMethods#stateable_scope_body):
      # raises while that concern's macro has not yet renamed its own.
      def self.refuse_unrenamed_scope!(klass, name, owner)
        return unless ConcernsOnRails::Support::Affix.include_time_scope(klass, owner, name)

        raise ArgumentError,
              "#{LABEL}: scope '#{name}' is both a state scope and #{owner}'s default-named scope; " \
              "rename that concern's scopes with prefix:/suffix: on its macro (it may come after " \
              "stateable_by), or pass prefix:/suffix: to stateable_by"
      end

      included do
        class_attribute :stateable_field, instance_accessor: false
        class_attribute :stateable_states, instance_accessor: false, default: []
        class_attribute :stateable_default, instance_accessor: false
        class_attribute :stateable_transitions, instance_accessor: false, default: {}
        class_attribute :stateable_prefix, instance_accessor: false
        class_attribute :stateable_suffix, instance_accessor: false
        class_attribute :stateable_lock, instance_accessor: false, default: false
        # States whose `<state>_at` column is stamped on every explicit write.
        class_attribute :stateable_timestamps, instance_accessor: false, default: []
        # Every method name the current stateable_by generated (on this class
        # or, inherited, an ancestor): { instance: [...], scope: [...] }. The
        # collision guard lets a re-declaration overwrite exactly these, and
        # retires the ones it no longer generates.
        class_attribute :stateable_owned_methods, instance_accessor: false,
                                                  default: { instance: [].freeze, scope: [].freeze }.freeze
        # scope name => label of the concern (SoftDeletable, Publishable,
        # Schedulable) whose include-time default scope of that name a state
        # took over, pending that concern's affixing macro (see
        # stateable_guard_collisions!).
        class_attribute :stateable_deferred_scopes, instance_accessor: false, default: {}.freeze
        # Whether stateable_by installed an attribute default for the field,
        # so a re-declaration without default: knows to take it back out.
        class_attribute :stateable_default_applied, instance_accessor: false, default: false
        # field name => [declaring class, the attribute type captured before
        # Stateable first redeclared the field there] (see stateable_cast_type).
        class_attribute :stateable_cast_types, instance_accessor: false, default: {}.freeze
      end

      # Move to any declared state by name, bypassing transition guards.
      def transition_to!(state)
        state = state.to_sym
        raise InvalidTransition, "#{LABEL}: '#{state}' is not a declared state" unless self.class.stateable_states.include?(state)

        update!(stateable_write_attributes(state.to_s))
      end

      # Transition lifecycle hooks — override in the model. Fired by guarded
      # <event>! transitions (not by direct <state>! setters or transition_to!).
      # Per-event `before_<event>` / `after_<event>` methods fire inside them.
      def before_transition(_event, _from, _to); end
      def after_transition(_event, _from, _to); end

      # Defined as a real module (not `class_methods do`) so all the private
      # builder helpers live under a single `private` and aren't constrained by
      # Metrics/BlockLength. ActiveSupport::Concern auto-extends `ClassMethods`.
      module ClassMethods
        include ConcernsOnRails::Support::ColumnGuard

        # Configure the state column. See the module docs for the full DSL.
        def stateable_by(field, states:, **options)
          stateable_configure!(field, states, options)
          stateable_validate!
          stateable_adopt_names!(*stateable_guard_collisions!)
          stateable_define_states
          stateable_define_transitions
          stateable_record_defined!
          stateable_apply_default
        end

        # Run one declared transition across the relation. Returns the Integer
        # count of records transitioned; records whose current state the
        # event's guard rejects are skipped, not errors. So are records already
        # in the target state (the batch is idempotent) — unless `from:` names
        # that state, which makes re-entering it a declared self-transition.
        #
        # There is deliberately NO single-UPDATE fast path here: the
        # per-record path goes through `update!`, which runs validations,
        # while every fast path in this gem uses `update_all`, which does not.
        # Collapsing would silently skip validations that `<event>!` runs.
        # Guard membership is still filtered DB-side, so the scan is cheap.
        def transition_all(event)
          name = event.to_sym
          raise ArgumentError, "#{LABEL}: unknown transition '#{event}'" unless stateable_transition_config(name)

          ConcernsOnRails::Support::BatchOps.run(
            stateable_batch_relation(name),
            label: LABEL,
            message: "failed to transition record"
          ) do |record|
            stateable_batch_transition(record, name)
          end
        end

        # This class's declaration of `name` (Symbol or String key), or nil.
        # (Internal: public so transition_all can ask each record's class.)
        def stateable_transition_config(name)
          stateable_transitions[name.to_sym] || stateable_transitions[name.to_s]
        end

        private

        # The rows transition_all visits, filtered in SQL. On an STI table a
        # subclass may re-declare stateable_by — drop the event, widen or
        # narrow its `from:`, change its `to:` — and the relation holds every
        # subclass's rows, so the filter must admit any row SOME class's
        # declaration could accept; each record is then judged by its own
        # class (stateable_batch_transition). With one declaration across the
        # loaded hierarchy (the usual case) this is the exact filter it always
        # was: `from:` membership plus "not already in the target".
        #
        # NULL-safe: `where.not(field => to)` compiles to `NOT (state = 'x')`,
        # which SQL three-valued logic evaluates to NULL — never TRUE — for a
        # NULL state, so those rows were silently dropped from the batch and
        # from the returned count. They ARE eligible: a transition with no
        # `from:` is documented as allowed from any state, `may_<event>?`
        # returns true for them, and `record.<event>!` on the same row
        # succeeds. A NULL state is reachable through an imported row,
        # insert_all, or the documented `create!(status: nil)`.
        # A `from:` listing the target itself (`from: %i[draft submitted],
        # to: :submitted`) keeps those rows: the guard accepts them, and
        # `record.submit!` on one re-stamps it and fires the hooks.
        def stateable_batch_relation(name)
          declarations = stateable_batch_declarations(name)
          return all unless declarations.map(&:first).uniq == [stateable_field]

          froms = declarations.map { |declaration| declaration[1] }
          relation = froms.any?(&:empty?) ? all : all.where(stateable_field => froms.flatten.uniq)
          declarations.one? ? stateable_batch_target_filter(relation, *declarations.first.drop(1)) : relation
        end

        # Drop the rows already in the target state, unless `from:` lists it.
        def stateable_batch_target_filter(relation, from, to)
          return relation if from.include?(to)

          state = arel_table[stateable_field]
          relation.where(state.not_eq(to).or(state.eq(nil)))
        end

        # The distinct [field, from, to] declarations of `name` across this
        # class and its loaded subclasses (classes that do not declare it are
        # left out: their rows are skipped record by record).
        def stateable_batch_declarations(name)
          [self, *descendants].filter_map do |klass|
            config = klass.stateable_transition_config(name)
            next unless config

            [klass.stateable_field, Array(config[:from]).map(&:to_s).sort, config.fetch(:to).to_s]
          end.uniq
        end

        # One record of transition_all, judged by its OWN class's
        # declaration: a subclass that dropped the event (its `may_<event>?`
        # is a private retired stub) is skipped, as is a record already in
        # its class's target state (unless `from:` lists that state), and
        # otherwise its own guard decides.
        def stateable_batch_transition(record, name)
          klass = record.class
          config = klass.stateable_transition_config(name)
          return :skip unless config

          method_base = klass.send(:stateable_method_name, name)
          guard = :"may_#{method_base}?"
          return :skip unless record.respond_to?(guard)

          to = config.fetch(:to).to_s
          return :skip if record[klass.stateable_field].to_s == to && !Array(config[:from]).map(&:to_s).include?(to)

          record.public_send(guard) ? record.public_send(:"#{method_base}!") : :skip
        end

        def stateable_configure!(field, states, options)
          unknown = options.keys - OPTIONS
          raise ArgumentError, "#{LABEL}: unknown option(s): #{unknown.join(', ')}" if unknown.any?

          self.stateable_field = field.to_sym
          self.stateable_states = Array(states).map(&:to_sym)
          self.stateable_default = stateable_resolve_default(options)
          self.stateable_transitions = options[:transitions] || {}
          self.stateable_prefix = stateable_affix(options[:prefix])
          self.stateable_suffix = stateable_affix(options[:suffix])
          self.stateable_lock = options[:lock] ? true : false
          self.stateable_timestamps = stateable_timestamp_states(options[:timestamps])
          ensure_columns!(LABEL, stateable_field, types: :string)
        end

        # An explicit default: (nil included) wins. Omitted, the earlier or
        # inherited default is kept while it is still one of the declared
        # states — an STI subclass re-declaring only to add a state keeps it —
        # and dropped when it is not (it would start records in a state the
        # new declaration does not list).
        def stateable_resolve_default(options)
          return options[:default]&.to_sym if options.key?(:default)

          stateable_states.include?(stateable_default) ? stateable_default : nil
        end

        # timestamps: true => every state; an Array => those states (validated
        # against states: in stateable_validate!); nil/false => none.
        def stateable_timestamp_states(option)
          case option
          when nil, false then []
          when true then stateable_states.dup
          when Array then option.map(&:to_sym)
          else raise ArgumentError, "#{LABEL}: timestamps: must be true or an Array of states"
          end
        end

        def stateable_affix(option)
          ConcernsOnRails::Support::Affix.normalize(option, default: stateable_field)
        end

        def stateable_method_name(base)
          ConcernsOnRails::Support::Affix.name(base, prefix: stateable_prefix, suffix: stateable_suffix).to_s
        end

        def stateable_validate!
          raise ArgumentError, "#{LABEL}: states: cannot be empty" if stateable_states.empty?

          if stateable_default && !stateable_states.include?(stateable_default)
            raise ArgumentError, "#{LABEL}: default '#{stateable_default}' is not a declared state"
          end

          stateable_validate_timestamps!
          stateable_transitions.each { |event, config| stateable_validate_transition!(event, config) }
        end

        # Unknown states first (a config typo), then the columns Rails owns,
        # then the `<state>_at` columns — all missing ones in one typed
        # migration hint.
        def stateable_validate_timestamps!
          unknown = stateable_timestamps - stateable_states
          raise ArgumentError, "#{LABEL}: timestamps: references unknown states: #{unknown.join(', ')}" if unknown.any?
          return if stateable_timestamps.empty?

          columns = stateable_timestamps.map { |state| :"#{state}_at" }
          stateable_validate_stamp_columns!(columns)
          ensure_columns!(LABEL, columns, types: :datetime)
        end

        def stateable_validate_stamp_columns!(columns)
          reserved = columns.map(&:to_s) & RESERVED_STAMP_COLUMNS
          return if reserved.empty?

          raise ArgumentError, "#{LABEL}: timestamps: would stamp #{reserved.join(', ')}, which Rails owns; " \
                               "rename the state or pass timestamps: the states to stamp"
        end

        def stateable_validate_transition!(event, config)
          raise ArgumentError, "#{LABEL}: transition '#{event}' must declare :to" unless config[:to]

          unknown = (Array(config[:from]) + [config[:to]]).map(&:to_sym) - stateable_states
          raise ArgumentError, "#{LABEL}: transition '#{event}' references unknown states: #{unknown.join(', ')}" if unknown.any?

          return unless stateable_states.include?(event.to_sym)

          raise ArgumentError, "#{LABEL}: transition '#{event}' clashes with the same-named state setter; use prefix:/suffix:"
        end

        # Refuse a generated method that would silently override one this class
        # already has from ActiveRecord or another concern: an event named
        # `lock` defined `lock!` over AR's pessimistic lock! (breaking
        # with_lock), and `restore` beside SoftDeletable replaced its
        # restore!. Names an earlier stateable_by generated are ours to
        # redefine, so re-declaring
        # on the same class or a subclass still works. Checked before anything
        # is defined, so a refused declaration leaves the class untouched.
        # (Lazily generated column accessors are not considered: whether they
        # exist yet depends on load order.)
        #
        # One scope exemption: SoftDeletable, Publishable and Schedulable
        # define their default-named scopes at INCLUDE time, and their own
        # macro's prefix:/suffix: is what renames them — possibly on a later
        # line (`stateable_by ... states: %i[pending active]` then
        # `soft_deletable_by prefix: :trash`). A state may take such a name
        # while it is still that concern's untouched include-time scope on THIS
        # class's singleton (Affix.include_time_scope_owner: an inherited one
        # can never be renamed here, so it is refused at class load); the
        # shared scope then raises when CALLED until the concern's macro has
        # moved its own off the name (stateable_scope_body), so a rename that
        # never comes is still caught. Returns [instance names, scope names,
        # deferred scopes] for stateable_adopt_names!.
        def stateable_guard_collisions!
          instance_names, scope_names = stateable_generated_method_names
          owned = stateable_owned_methods

          instance_names.each do |name|
            next if owned[:instance].include?(name)
            raise stateable_collision_error(name) if stateable_instance_method_taken?(name)
          end
          [instance_names, scope_names, stateable_guard_scopes!(scope_names, owned[:scope])]
        end

        # The scope half of the guard. Returns the deferred scopes — name =>
        # the concern whose include-time default it takes over — carrying an
        # owned name's earlier entry forward.
        def stateable_guard_scopes!(scope_names, owned)
          deferred = stateable_deferred_scopes.slice(*scope_names)
          (scope_names - owned).each do |name|
            next unless singleton_class.method_defined?(name)

            owner = ConcernsOnRails::Support::Affix.include_time_scope_owner(self, name)
            raise stateable_collision_error(name, scope: true) unless owner

            deferred[name] = owner
          end
          deferred
        end

        # Record this declaration's names as the ones Stateable owns, retiring
        # those the previous declaration generated and this one does not: a
        # subclass re-declared with `states: %i[open closed]` must stop
        # answering its parent's `archive!` and `.draft` (a stale setter wrote
        # a state it never declared), and a stale owned name would make the
        # reverse-order check refuse a legitimate sibling. Only a method
        # Stateable itself defined is retired: one the class (re)defined
        # itself — `def archived? = archived_at.present?` above a subclass's
        # re-declaration — is left alone and simply stops being owned.
        def stateable_adopt_names!(instance_names, scope_names, deferred)
          owned = stateable_owned_methods
          (owned[:instance] - instance_names).each { |name| stateable_retire_method!(self, name, :instance) }
          (owned[:scope] - scope_names).each { |name| stateable_retire_scope!(name) }

          self.stateable_owned_methods = { instance: instance_names.freeze, scope: scope_names.freeze }.freeze
          self.stateable_deferred_scopes = deferred.freeze
        end

        # A retired scope that had taken over another concern's still-unrenamed
        # include-time scope hands the name back to that concern's method.
        def stateable_retire_scope!(name)
          return unless stateable_generated?(singleton_class, name, :scope)

          owner = stateable_deferred_scopes[name]
          captured = owner && ConcernsOnRails::Support::Affix.include_time_scope(self, owner, name)
          return singleton_class.send(:define_method, name, captured) if captured

          stateable_retire_method!(singleton_class, name, :scope)
        end

        # Retire `name` from `mod` (the class, or its singleton for a scope)
        # while what answers it is still a method a stateable_by defined:
        # remove it where this class defined it, and if an ancestor's
        # generated copy (a parent's declaration) is still reachable, hide it.
        # Anything else — the class's or a parent's own override, a module's
        # method such as a column's generated attribute method a state
        # predicate had shadowed — is left to answer.
        def stateable_retire_method!(mod, name, kind)
          return unless stateable_generated?(mod, name, kind)

          mod.send(:remove_method, name) if mod.method_defined?(name, false) || mod.private_method_defined?(name, false)
          stateable_hide_inherited!(mod, name) if stateable_generated?(mod, name, kind)
        end

        # Whether `mod` currently answers `name` with exactly the method a
        # stateable_by recorded on the class that owns it (see
        # stateable_record_defined!) — never a user's own override.
        def stateable_generated?(mod, name, kind)
          return false unless mod.method_defined?(name) || mod.private_method_defined?(name)

          method = mod.instance_method(name)
          owner = method.owner
          return false unless owner.is_a?(Class)

          declarer = owner.singleton_class? ? owner.attached_object : owner
          method == declarer.instance_variable_get(:@stateable_defined_methods)&.dig(kind, name)
        end

        # The UnboundMethods this declaration just defined, per class (an
        # ivar, never inherited), so a later re-declaration retires only
        # those — as Support::Affix.capture does for the scope-retiring concerns.
        def stateable_record_defined!
          owned = stateable_owned_methods
          @stateable_defined_methods = {
            instance: owned[:instance].to_h { |name| [name, instance_method(name)] },
            scope: owned[:scope].to_h { |name| [name, singleton_class.instance_method(name)] }
          }.freeze
        end

        # Hidden in a RetiredMethods module of this class's own rather than
        # with undef_method on the class: an undef also blocks every module
        # the class includes LATER (a sibling concern's `active?`) and a
        # column's lazily generated query method. The stub is private — so
        # `respond_to?` is false and an explicit call raises NoMethodError —
        # except for a column's `<column>?`, which is handed back to the
        # column instead of the parent's state predicate.
        def stateable_hide_inherited!(mod, name)
          hider = stateable_retired_module(mod)
          column = mod.singleton_class? ? nil : stateable_query_column(name)
          return hider.send(:define_method, name) { query_attribute(column) } if column

          hider.send(:define_method, name) do |*|
            raise NoMethodError.new("undefined method '#{name}' for #{is_a?(Module) ? self : self.class}", name)
          end
          hider.send(:private, name)
        end

        def stateable_retired_module(mod)
          ivar = mod.singleton_class? ? :@stateable_retired_scopes : :@stateable_retired_methods
          instance_variable_get(ivar) || instance_variable_set(ivar, RetiredMethods.new.tap { |hider| mod.include(hider) })
        end

        # The attribute `name` is the `?` query method of, or nil.
        def stateable_query_column(name)
          column = name.to_s.delete_suffix("?")
          return nil if column == name.to_s || !schema_reachable?

          column if attribute_names.include?(column) || attribute_alias?(column)
        end

        # [instance method names, scope names] this declaration will define.
        def stateable_generated_method_names
          state_bases = stateable_states.map { |state| stateable_method_name(state) }
          event_bases = stateable_transitions.keys.map { |event| stateable_method_name(event) }
          instance = state_bases.flat_map { |base| [:"#{base}?", :"#{base}!"] } +
                     event_bases.flat_map { |base| [:"may_#{base}?", :"#{base}!"] }
          [instance.uniq, state_bases.map(&:to_sym)]
        end

        # Column attribute methods are exempt wherever they live: an STI
        # subclass inherits its parent's generated-attribute module, which
        # only holds `flagged?` once the parent has been instantiated — so
        # checking just this class's own module made the guard depend on
        # load order. So are the stubs a re-declaration hid a parent's stale
        # names behind (RetiredMethods): declaring the name again takes it back.
        def stateable_instance_method_taken?(name)
          return false unless method_defined?(name) || private_method_defined?(name)

          owner = instance_method(name).owner
          !owner.is_a?(ActiveRecord::AttributeMethods::GeneratedAttributeMethods) && !owner.is_a?(RetiredMethods)
        end

        def stateable_collision_error(name, scope: false)
          kind = scope ? "scope" : "method"
          ArgumentError.new(
            "#{LABEL}: generated #{kind} '#{name}' would override an existing #{kind} of the same name " \
            "(from ActiveRecord or another concern); pass prefix: or suffix: to rename the generated methods"
          )
        end

        def stateable_define_states
          field = stateable_field
          stateable_states.each do |state|
            value = state.to_s
            name = stateable_method_name(state)
            scope name, stateable_scope_body(name.to_sym, field, value)
            define_method("#{name}?") { self[field].to_s == value }
            define_method("#{name}!") { update!(stateable_write_attributes(value)) }
          end
        end

        # A scope that took over another concern's include-time default name
        # refuses to run while that concern still claims the name — its macro
        # never renamed its own scopes — so the collision the guard let
        # through is caught at first use instead of silently answering with
        # Stateable's filter where the concern (or its own internals, e.g.
        # Publishable's default scope calling `.published`) expected its own.
        def stateable_scope_body(name, field, value)
          owner = stateable_deferred_scopes[name]
          return -> { where(field => value) } unless owner

          lambda do
            ConcernsOnRails::Models::Stateable.refuse_unrenamed_scope!(klass, name, owner)
            where(field => value)
          end
        end

        def stateable_define_transitions
          field = stateable_field
          stateable_transitions.each do |event, config|
            from = Array(config[:from]).map(&:to_s)
            to = config.fetch(:to).to_s
            name = stateable_method_name(event)
            define_method("may_#{name}?") { from.empty? || from.include?(self[field].to_s) }
            define_method("#{name}!") { stateable_perform_transition!(field, to, from, event, name) }
          end
        end

        def stateable_apply_default
          unless stateable_default
            stateable_reset_default if stateable_default_applied
            return
          end

          # Attribute-level default: applied when a new object is built, with no
          # callback overhead — the previous after_initialize ran (and checked
          # new_record?) for every row materialized from the database. Loaded
          # records keep their stored value; `Model.new(field => nil)` keeps the
          # explicit nil (assign the state or rely on the default, not both).
          attribute stateable_field, stateable_cast_type, default: stateable_default.to_s
          self.stateable_default_applied = true
        end

        # The field's type as it stood BEFORE Stateable first redeclared it —
        # the schema's (a PG enum or citext column keeps its OID type) or the
        # host's own `attribute` — so neither the default nor its reset forces
        # a plain :string onto the column. Captured once per field PER
        # DECLARING CLASS: the class attribute is inherited, and an STI
        # subclass that declares its own `attribute :status, CustomType`
        # before its stateable_by must not get the parent's type put back (a
        # subclass that declares none reads the parent's, the same type).
        # Without a reachable schema: the inherited capture, else :string.
        def stateable_cast_type
          field = stateable_field.to_s
          owner, captured = stateable_cast_types[field]
          return captured if captured && owner.equal?(self)
          return captured || :string unless schema_reachable?

          type = type_for_attribute(field)
          self.stateable_cast_types = stateable_cast_types.merge(field => [self, type].freeze).freeze
          type
        end

        # A re-declaration that drops the default (explicit `default: nil`, or
        # an omitted one no longer among the states) must not keep the earlier
        # attribute default. Omitting `default:` from
        # `attribute` keeps the previous one, so hand back the column's own
        # database default, read lazily (per new record) so it needs no schema
        # at class-load time.
        def stateable_reset_default
          column = stateable_field.to_s
          attribute stateable_field, stateable_cast_type, default: -> { columns_hash[column]&.default }
          self.stateable_default_applied = false
        end
      end

      private

      # Instance-level guarded transition body, shared by every `<event>!`.
      # With `lock: true` the guard is re-checked under a row lock against the
      # row's committed state — closing the check-then-write race between two
      # concurrent transitions. Support::Locking.with_locked_column: a record
      # without unsaved changes is reloaded under the lock (with_lock, as
      # always); one WITH unsaved changes — which with_lock refused ("Locking
      # a record with unpersisted changes is not supported") — has only its
      # state column read and adopted, and its changes save with the state.
      def stateable_perform_transition!(field, to, from, event, name)
        return stateable_execute_transition!(field, to, from, event, name) unless self.class.stateable_lock && persisted?

        ConcernsOnRails::Support::Locking.with_locked_column(self, field) do
          stateable_execute_transition!(field, to, from, event, name)
        end
      end

      # Hooks and the state write share ONE transaction, so a raising
      # after_transition (or after_<event>) rolls the state change back instead
      # of leaving it committed with the side effect half-done (SoftDeletable's
      # pattern). Order: before_transition → before_<event> → write →
      # after_<event> → after_transition.
      def stateable_execute_transition!(field, to, from, event, name)
        current = self[field].to_s
        raise InvalidTransition, "#{self.class.name}: cannot #{event} from '#{self[field]}'" unless from.empty? || from.include?(current)

        # Support::HookedWrite (the helper every hooked concern write shares):
        # its own savepoint, because a bare `transaction` JOINS an enclosing
        # one and Rails then swallowed an ActiveRecord::Rollback from
        # after_transition with nothing rolled back; and a result that is true
        # only once the block has run to the end, because taking it from
        # update! reported a fake success for a transition the hook had just
        # aborted (`raise unless ticket.archive!` never fired, and
        # transition_all counted a row it had rolled back). The hooks take
        # arguments, so they run inside the block rather than as before:/after:.
        # An abort puts the state (and its <state>_at stamp, and anything
        # else the write changed in memory) back — otherwise memory kept the
        # vetoed state while the row kept the old one, and a retry's guard
        # raised InvalidTransition.
        attributes = stateable_write_attributes(to)
        ConcernsOnRails::Support::HookedWrite.run(self) do
          before_transition(event, current, to)
          stateable_event_hook(:"before_#{name}")
          update!(attributes)
          stateable_event_hook(:"after_#{name}")
          after_transition(event, current, to)
          true
        end
      end

      def stateable_event_hook(method_name)
        send(method_name) if respond_to?(method_name, true)
      end

      # The state column plus, when the state is stamped, its `<state>_at`.
      def stateable_write_attributes(state)
        attributes = { self.class.stateable_field => state }
        attributes[:"#{state}_at"] = Time.current if self.class.stateable_timestamps.include?(state.to_sym)
        attributes
      end
    end
  end
end
