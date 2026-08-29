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
    # Note: SoftDeletable also defines a `.active` scope (alias of `.without_deleted`).
    # If both concerns are included on the same model, the later one wins.
    module Activatable
      extend ActiveSupport::Concern

      DEFAULT_FIELD = :active

      included do
        class_attribute :activatable_field, instance_accessor: false, default: DEFAULT_FIELD
        class_attribute :activatable_scope_names, instance_accessor: false,
                                                  default: { active: :active, inactive: :inactive }.freeze
      end

      class_methods do # rubocop:disable Metrics/BlockLength
        include ConcernsOnRails::Support::ColumnGuard

        def activatable_by(field = DEFAULT_FIELD, prefix: nil, suffix: nil)
          self.activatable_field = field.to_sym
          ensure_columns!("ConcernsOnRails::Models::Activatable", activatable_field, types: :boolean)

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
          if activatable_batch_fast_path?(:activate!)
            return inactive.update_all(
              ConcernsOnRails::Support::BatchOps.with_timestamps(self, activatable_field => true)
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
          if activatable_batch_fast_path?(:deactivate!)
            return active.update_all(
              ConcernsOnRails::Support::BatchOps.with_timestamps(self, activatable_field => false)
            )
          end

          ConcernsOnRails::Support::BatchOps.run(
            active,
            label: "ConcernsOnRails::Models::Activatable",
            message: "failed to deactivate record",
            &:deactivate!
          )
        end

        private

        # Whether the single-UPDATE fast path is safe — the whole decision
        # (bang method unoverridden AND the model declares no validations,
        # plus why) lives in Support::BatchOps.fast_path?. Activatable defines
        # no lifecycle hooks, so the bang method is the only one to check.
        def activatable_batch_fast_path?(method)
          ConcernsOnRails::Support::BatchOps.fast_path?(self, ConcernsOnRails::Models::Activatable, method)
        end
      end

      def active?
        self[self.class.activatable_field] == true
      end

      def inactive?
        !active?
      end

      def activate!
        update(self.class.activatable_field => true)
      end

      def deactivate!
        update(self.class.activatable_field => false)
      end

      def toggle_active!
        # Lock the row for the read-modify-write so concurrent toggles don't lose
        # an update (with_lock wraps a transaction + SELECT ... FOR UPDATE).
        with_lock { active? ? deactivate! : activate! }
      end
    end
  end
end
