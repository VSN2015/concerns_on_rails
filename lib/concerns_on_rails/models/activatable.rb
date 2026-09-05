require "active_support/concern"
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/affix"
require "concerns_on_rails/support/batch_ops"

module ConcernsOnRails
  module Models
    # Boolean active/inactive toggle backed by a single column.
    #
    #   class Subscription < ApplicationRecord
    #     include ConcernsOnRails::Activatable
    #
    #     activatable_by             # defaults to :active
    #     # activatable_by :enabled  # custom column name
    #   end
    #
    #   Subscription.active     # WHERE active = TRUE
    #   Subscription.inactive   # WHERE active = FALSE OR active IS NULL
    #
    # NULL is treated as inactive, mirroring how unset booleans behave in most apps.
    #
    # Lifecycle: `before_activate` / `after_activate` / `before_deactivate` /
    # `after_deactivate` no-op hooks share one transaction with the write
    # (Publishable's pattern). `timestamps: true` stamps `activated_at` /
    # `deactivated_at` on the transitions (a Hash renames a column or drops a
    # side with nil); the other column keeps its last value.
    #
    # Note: SoftDeletable also defines a `.active` scope (alias of `.without_deleted`).
    # If both concerns are included on the same model, the later one wins.
    module Activatable
      extend ActiveSupport::Concern

      DEFAULT_FIELD = :active
      LABEL = "ConcernsOnRails::Models::Activatable".freeze
      TIMESTAMP_KEYS = %i[activated_at deactivated_at].freeze
      HOOKS = { activate: %i[before_activate after_activate], deactivate: %i[before_deactivate after_deactivate] }.freeze

      included do
        class_attribute :activatable_field, instance_accessor: false, default: DEFAULT_FIELD
        class_attribute :activatable_scope_names, instance_accessor: false,
                                                  default: { active: :active, inactive: :inactive }.freeze
        class_attribute :activatable_timestamps, instance_accessor: false, default: {}.freeze
      end

      class_methods do # rubocop:disable Metrics/BlockLength
        include ConcernsOnRails::Support::ColumnGuard

        def activatable_by(field = DEFAULT_FIELD, prefix: nil, suffix: nil, timestamps: false)
          self.activatable_field = field.to_sym
          ensure_columns!(LABEL, activatable_field, types: :boolean)
          self.activatable_timestamps = activatable_normalize_timestamps!(timestamps)

          prefix = ConcernsOnRails::Support::Affix.normalize(prefix, default: activatable_field)
          suffix = ConcernsOnRails::Support::Affix.normalize(suffix, default: activatable_field)
          self.activatable_scope_names = {
            active: ConcernsOnRails::Support::Affix.name(:active, prefix: prefix, suffix: suffix),
            inactive: ConcernsOnRails::Support::Affix.name(:inactive, prefix: prefix, suffix: suffix)
          }.freeze

          # Affix the scope names so two concerns that each define `.active`
          # (e.g. SoftDeletable / Expirable) can coexist on one model.
          scope activatable_scope_names[:active],   -> { where(activatable_field => true) }
          scope activatable_scope_names[:inactive], -> { where(activatable_field => [false, nil]) }
        end

        # Activate every inactive record in the relation; returns the count.
        def activate_all
          inactive = all.public_send(activatable_scope_names.fetch(:inactive))
          if activatable_batch_fast_path?(:activate)
            return inactive.update_all(
              ConcernsOnRails::Support::BatchOps.with_timestamps(self, activatable_attributes(true, :activate))
            )
          end

          ConcernsOnRails::Support::BatchOps.run(
            inactive,
            label: "ConcernsOnRails::Models::Activatable",
            message: "failed to activate record",
            &:activate!
          )
        end

        # Deactivate every active record in the relation; returns the count.
        def deactivate_all
          active = all.public_send(activatable_scope_names.fetch(:active))
          if activatable_batch_fast_path?(:deactivate)
            return active.update_all(
              ConcernsOnRails::Support::BatchOps.with_timestamps(self, activatable_attributes(false, :deactivate))
            )
          end

          ConcernsOnRails::Support::BatchOps.run(
            active,
            label: "ConcernsOnRails::Models::Activatable",
            message: "failed to deactivate record",
            &:deactivate!
          )
        end

        # The column writes for a transition: the flag plus the configured
        # stamp (activated_at / deactivated_at) for that direction. Shared by
        # the per-record path and the batch fast path so both agree.
        def activatable_attributes(value, kind, time = Time.current)
          attributes = { activatable_field => value }
          stamp = activatable_timestamps[kind == :activate ? :activated_at : :deactivated_at]
          attributes[stamp] = time if stamp
          attributes
        end

        private

        # Whether the single-UPDATE fast path is safe — the whole decision
        # (bang method AND its two hooks unoverridden, AND the model declares
        # no validations, plus why) lives in Support::BatchOps.fast_path?.
        def activatable_batch_fast_path?(kind)
          ConcernsOnRails::Support::BatchOps.fast_path?(self, ConcernsOnRails::Models::Activatable,
                                                        :"#{kind}!", *HOOKS.fetch(kind))
        end

        # true -> both default columns; a Hash renames a side or drops it with
        # nil; false/nil -> no stamps. Columns are validated as datetimes.
        def activatable_normalize_timestamps!(option)
          mapping = activatable_timestamps_mapping(option)
          unknown = mapping.keys.map(&:to_sym) - TIMESTAMP_KEYS
          raise ArgumentError, "#{LABEL}: unknown timestamps: key(s): #{unknown.join(', ')}" if unknown.any?

          stamps = mapping.to_h { |key, column| [key.to_sym, column&.to_sym] }.compact
          ensure_columns!(LABEL, *stamps.values, types: :datetime) if stamps.any?
          stamps.freeze
        end

        def activatable_timestamps_mapping(option)
          case option
          when false, nil then {}
          when true then TIMESTAMP_KEYS.to_h { |key| [key, key] }
          when Hash then option
          else raise ArgumentError, "#{LABEL}: timestamps: must be true, false or a Hash (got #{option.inspect})"
          end
        end
      end

      def active?
        self[self.class.activatable_field] == true
      end

      def inactive?
        !active?
      end

      # Lifecycle hooks — no-ops to override. They run around activate! /
      # deactivate! (and so toggle_active! and the batch verbs' per-record
      # path); overriding one moves the batch verbs off the single-UPDATE path.
      def before_activate; end
      def after_activate; end
      def before_deactivate; end
      def after_deactivate; end

      def activate!
        activatable_transition(true, :activate)
      end

      def deactivate!
        activatable_transition(false, :deactivate)
      end

      def toggle_active!
        # Lock the row for the read-modify-write so concurrent toggles don't lose
        # an update (with_lock wraps a transaction + SELECT ... FOR UPDATE).
        with_lock { active? ? deactivate! : activate! }
      end

      # Hooks and the write share one transaction: a raising after-hook rolls
      # the flip back; a failed write (validation) returns false and skips the
      # after-hook (Publishable / Expirable's contract).
      def activatable_transition(value, kind)
        before_hook, after_hook = HOOKS.fetch(kind)
        result = false
        transaction do
          public_send(before_hook)
          result = update(self.class.activatable_attributes(value, kind))
          public_send(after_hook) if result
        end
        result
      end
      private :activatable_transition
    end
  end
end
