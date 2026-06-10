require "active_support/concern"

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
    # Options for stateable_by: default:, transitions:, prefix:, suffix:
    # (prefix:/suffix: take `true` to use the field name, or a literal string/symbol).
    #
    # Notes:
    #   * String columns only (store the state name) — not integer-backed like Rails enum.
    #   * A state named like an AR method (`new`, `valid`) or a concern scope
    #     (`active`, `expired`) will clash — use prefix:/suffix: to disambiguate.
    module Stateable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Models::Stateable".freeze

      # Raised when a guarded transition is attempted from a disallowed state.
      class InvalidTransition < StandardError; end

      included do
        class_attribute :stateable_field, instance_accessor: false
        class_attribute :stateable_states, instance_accessor: false, default: []
        class_attribute :stateable_default, instance_accessor: false
        class_attribute :stateable_transitions, instance_accessor: false, default: {}
        class_attribute :stateable_prefix, instance_accessor: false
        class_attribute :stateable_suffix, instance_accessor: false
      end

      # Move to any declared state by name, bypassing transition guards.
      def transition_to!(state)
        state = state.to_sym
        raise InvalidTransition, "#{LABEL}: '#{state}' is not a declared state" unless self.class.stateable_states.include?(state)

        update!(self.class.stateable_field => state.to_s)
      end

      # Transition lifecycle hooks — override in the model. Fired by guarded
      # <event>! transitions (not by direct <state>! setters or transition_to!).
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

        private

        def stateable_configure!(field, states, options)
          self.stateable_field = field.to_sym
          self.stateable_states = Array(states).map(&:to_sym)
          self.stateable_default = options[:default]&.to_sym
          self.stateable_transitions = options[:transitions] || {}
          self.stateable_prefix = stateable_affix(options[:prefix])
          self.stateable_suffix = stateable_affix(options[:suffix])
          ensure_columns!(LABEL, stateable_field)
        end

        # `true` => use the field name; a string/symbol => use it literally; else none.
        def stateable_affix(option)
          return nil unless option

          option == true ? stateable_field.to_s : option.to_s
        end

        def stateable_method_name(base)
          [stateable_prefix, base, stateable_suffix].compact.join("_")
        end

        def stateable_validate!
          raise ArgumentError, "#{LABEL}: states: cannot be empty" if stateable_states.empty?

          if stateable_default && !stateable_states.include?(stateable_default)
            raise ArgumentError, "#{LABEL}: default '#{stateable_default}' is not a declared state"
          end

          stateable_transitions.each { |event, config| stateable_validate_transition!(event, config) }
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
            define_method("#{name}!") { update!(field => value) }
          end
        end

        def stateable_define_transitions
          field = stateable_field
          stateable_transitions.each do |event, config|
            from = Array(config[:from]).map(&:to_s)
            to = config.fetch(:to).to_s
            name = stateable_method_name(event)
            define_method("may_#{name}?") { from.empty? || from.include?(self[field].to_s) }
            define_method("#{name}!") { stateable_perform_transition!(field, to, from, event) }
          end
        end

        def stateable_apply_default
          return unless stateable_default

          field = stateable_field
          default = stateable_default.to_s
          after_initialize { self[field] = default if new_record? && self[field].blank? }
        end
      end

      private

      # Instance-level guarded transition body, shared by every `<event>!`.
      def stateable_perform_transition!(field, to, from, event)
        current = self[field].to_s
        raise InvalidTransition, "#{self.class.name}: cannot #{event} from '#{self[field]}'" unless from.empty? || from.include?(current)

        before_transition(event, current, to)
        result = update!(field => to)
        after_transition(event, current, to)
        result
      end
    end
  end
end
