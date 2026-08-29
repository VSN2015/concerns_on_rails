require "active_support/concern"
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/affix"

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

      class_methods do
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
