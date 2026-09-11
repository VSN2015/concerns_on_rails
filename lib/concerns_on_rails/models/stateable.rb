require "active_support/concern"
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/affix"
require "concerns_on_rails/support/batch_ops"

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
    # migration hint); the default state is not stamped on create.
    #
    # Options for stateable_by: default:, transitions:, prefix:, suffix:, lock:,
    # timestamps: (prefix:/suffix: take `true` to use the field name, or a
    # literal string/symbol).
    #
    # Notes:
    #   * String columns only (store the state name) — not integer-backed like Rails enum.
    #   * A state named like an AR method (`new`, `valid`) or a concern scope
    #     (`active`, `expired`) will clash — use prefix:/suffix: to disambiguate.
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
          eligible = eligible.where.not(field => to)

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
          self.stateable_default = options[:default]&.to_sym
          self.stateable_transitions = options[:transitions] || {}
          self.stateable_prefix = stateable_affix(options[:prefix])
          self.stateable_suffix = stateable_affix(options[:suffix])
          self.stateable_lock = options[:lock] ? true : false
          self.stateable_timestamps = stateable_timestamp_states(options[:timestamps])
          ensure_columns!(LABEL, stateable_field, types: :string)
        end

        # timestamps: true => every state; an Array => those states (validated
        # against states: in stateable_validate!); nil/false => none.
        def stateable_timestamp_states(option)
          case option
          when nil, false then []
          when true then stateable_states
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

        # Unknown states first (a config typo), then the `<state>_at` columns —
        # all missing ones in one typed migration hint.
        def stateable_validate_timestamps!
          unknown = stateable_timestamps - stateable_states
          raise ArgumentError, "#{LABEL}: timestamps: references unknown states: #{unknown.join(', ')}" if unknown.any?
          return if stateable_timestamps.empty?

          ensure_columns!(LABEL, stateable_timestamps.map { |state| :"#{state}_at" }, types: :datetime)
        end

        def stateable_validate_transition!(event, config)
          raise ArgumentError, "#{LABEL}: transition '#{event}' must declare :to" unless config[:to]

          unknown = (Array(config[:from]) + [config[:to]]).map(&:to_sym) - stateable_states
          raise ArgumentError, "#{LABEL}: transition '#{event}' references unknown states: #{unknown.join(', ')}" if unknown.any?

          return unless stateable_states.include?(event.to_sym)

          raise ArgumentError, "#{LABEL}: transition '#{event}' clashes with the same-named state setter; use prefix:/suffix:"
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
          return unless stateable_default

          # Attribute-level default: applied when a new object is built, with no
          # callback overhead — the previous after_initialize ran (and checked
          # new_record?) for every row materialized from the database. Loaded
          # records keep their stored value; `Model.new(field => nil)` keeps the
          # explicit nil (assign the state or rely on the default, not both).
          attribute stateable_field, :string, default: stateable_default.to_s
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

        result = false
        transaction do
          before_transition(event, current, to)
          stateable_event_hook(:"before_#{name}")
          result = update!(stateable_write_attributes(to))
          stateable_event_hook(:"after_#{name}")
          after_transition(event, current, to)
        end
        result
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
