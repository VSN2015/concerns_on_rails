require "active_support/concern"
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/affix"
require "concerns_on_rails/support/batch_ops"
require "concerns_on_rails/support/hooked_write"

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
    #     time; use prefix:/suffix: to disambiguate.
    #   * Re-declaring (same class or an STI subclass) replaces the config. An
    #     omitted default: keeps the earlier one while it is still a declared
    #     state (else, or with `default: nil`, the column's DB default applies).
    #   * Guarded transitions check the in-memory state: two processes firing the
    #     same <event>! concurrently can both pass the guard (check-then-write).
    #     `lock: true` closes that race — each <event>! takes a row lock
    #     (SELECT ... FOR UPDATE) and re-checks the guard against the fresh row
    #     first. Requires a clean record (with_lock reloads; AR refuses to
    #     reload unsaved changes) and costs a SELECT per transition.
    module Stateable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Models::Stateable".freeze

      # Raised when a guarded transition is attempted from a disallowed state.
      class InvalidTransition < StandardError; end

      # Valid stateable_by keyword options (everything besides field/states:).
      OPTIONS = %i[default transitions prefix suffix lock timestamps].freeze

      # Columns Rails owns. A state named `created` or `updated` derives one of
      # them as its `<state>_at`, and ColumnGuard cannot catch it — the column
      # exists — so every write into that state would quietly rewrite the row's
      # creation time (or fight the automatic touch).
      RESERVED_STAMP_COLUMNS = %w[created_at created_on updated_at updated_on].freeze

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
        # Every method name an earlier stateable_by generated (on this class
        # or an ancestor): { instance: [...], scope: [...] }. The collision
        # guard lets a re-declaration overwrite exactly these.
        class_attribute :stateable_owned_methods, instance_accessor: false,
                                                  default: { instance: [].freeze, scope: [].freeze }.freeze
        # Whether stateable_by installed an attribute default for the field,
        # so a re-declaration without default: knows to take it back out.
        class_attribute :stateable_default_applied, instance_accessor: false, default: false
        # field name => the attribute type captured before Stateable first
        # redeclared the field (see stateable_cast_type).
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
          stateable_guard_collisions!
          stateable_define_states
          stateable_define_transitions
          stateable_apply_default
        end

        # Run one declared transition across the relation. Returns the Integer
        # count of records transitioned; records whose current state the
        # event's guard rejects are skipped, not errors.
        #
        # There is deliberately NO single-UPDATE fast path here: the
        # per-record path goes through `update!`, which runs validations,
        # while every fast path in this gem uses `update_all`, which does not.
        # Collapsing would silently skip validations that `<event>!` runs.
        # Guard membership is still filtered DB-side, so the scan is cheap.
        def transition_all(event)
          name = event.to_sym
          config = stateable_transitions[name] || stateable_transitions[event.to_s]
          raise ArgumentError, "#{LABEL}: unknown transition '#{event}'" unless config

          from = Array(config[:from]).map(&:to_s)
          to = config.fetch(:to).to_s
          field = stateable_field
          method_base = stateable_method_name(name)

          eligible = from.empty? ? all : all.where(field => from)
          # NULL-safe: `where.not(field => to)` compiles to `NOT (state = 'x')`,
          # which SQL three-valued logic evaluates to NULL — never TRUE — for a
          # NULL state, so those rows were silently dropped from the batch and
          # from the returned count. They ARE eligible: a transition with no
          # `from:` is documented as allowed from any state, `may_<event>?`
          # returns true for them, and `record.<event>!` on the same row
          # succeeds. A NULL state is reachable through an imported row,
          # insert_all, or the documented `create!(status: nil)`.
          eligible = eligible.where(arel_table[field].not_eq(to).or(arel_table[field].eq(nil)))

          ConcernsOnRails::Support::BatchOps.run(
            eligible,
            label: LABEL,
            message: "failed to transition record"
          ) do |record|
            record.public_send(:"may_#{method_base}?") ? record.public_send(:"#{method_base}!") : :skip
          end
        end

        private

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
        # with_lock, and with it this concern's own `lock: true`), and
        # `restore` beside SoftDeletable replaced its restore!. Names an
        # earlier stateable_by generated are ours to redefine, so re-declaring
        # on the same class or a subclass still works. Checked before anything
        # is defined, so a refused declaration leaves the class untouched.
        # (Lazily generated column accessors are not considered: whether they
        # exist yet depends on load order.)
        def stateable_guard_collisions!
          instance_names, scope_names = stateable_generated_method_names
          owned = stateable_owned_methods

          instance_names.each do |name|
            next if owned[:instance].include?(name)
            raise stateable_collision_error(name) if stateable_instance_method_taken?(name)
          end
          scope_names.each do |name|
            next if owned[:scope].include?(name)
            raise stateable_collision_error(name, scope: true) if singleton_class.method_defined?(name)
          end

          self.stateable_owned_methods = {
            instance: (owned[:instance] | instance_names).freeze,
            scope: (owned[:scope] | scope_names).freeze
          }.freeze
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
        # load order.
        def stateable_instance_method_taken?(name)
          return false unless method_defined?(name) || private_method_defined?(name)

          !instance_method(name).owner.is_a?(ActiveRecord::AttributeMethods::GeneratedAttributeMethods)
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
            scope name, -> { where(field => value) }
            define_method("#{name}?") { self[field].to_s == value }
            define_method("#{name}!") { update!(stateable_write_attributes(value)) }
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
        # host's own `attribute` — captured once per field and inherited, so
        # neither the default nor its reset forces a plain :string onto the
        # column. Without a reachable schema, :string (the old behavior).
        def stateable_cast_type
          field = stateable_field.to_s
          captured = stateable_cast_types[field]
          return captured if captured
          return :string unless schema_reachable?

          type = type_for_attribute(field)
          self.stateable_cast_types = stateable_cast_types.merge(field => type).freeze
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
      # With `lock: true` the guard is re-checked under a row lock (with_lock
      # reloads, so the state read is the committed one) — closing the
      # check-then-write race between two concurrent transitions.
      def stateable_perform_transition!(field, to, from, event, name)
        if self.class.stateable_lock && persisted?
          with_lock { stateable_execute_transition!(field, to, from, event, name) }
        else
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
        # `restore:` puts the state (and its <state>_at stamp) back in memory
        # on an abort — otherwise memory kept the vetoed state while the row
        # kept the old one, and a retry's guard raised InvalidTransition.
        attributes = stateable_write_attributes(to)
        ConcernsOnRails::Support::HookedWrite.run(self, restore: attributes.keys) do
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
