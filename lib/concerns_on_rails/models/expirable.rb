require "active_support/concern"
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/affix"
require "concerns_on_rails/support/batch_ops"

module ConcernsOnRails
  module Models
    module Expirable
      extend ActiveSupport::Concern

      DEFAULT_FIELD = :expires_at

      included do
        class_attribute :expirable_field, instance_accessor: false, default: DEFAULT_FIELD
        class_attribute :expirable_scope_names, instance_accessor: false,
                                                default: { active: :active, expired: :expired,
                                                           expiring_within: :expiring_within }.freeze
      end

      class_methods do # rubocop:disable Metrics/BlockLength
        include ConcernsOnRails::Support::ColumnGuard

        # Configure the expiry column.
        # Example:
        #   expirable_by                  # uses :expires_at
        #   expirable_by :valid_until
        def expirable_by(field = DEFAULT_FIELD, prefix: nil, suffix: nil)
          self.expirable_field = field.to_sym
          ensure_columns!("ConcernsOnRails::Models::Expirable", expirable_field, types: :datetime)
          define_expirable_scopes(prefix, suffix)
        end

        # Expire every currently-active record in the relation. Returns the
        # Integer count. Expirable defines no lifecycle hooks, so this is a
        # single UPDATE unless the model overrode `expire!` or declares
        # validations (see Support::BatchOps.fast_path?).
        def expire_all(time = Time.zone.now)
          active = all.public_send(expirable_scope_names.fetch(:active))
          if expirable_batch_fast_path?
            return active.update_all(
              ConcernsOnRails::Support::BatchOps.with_timestamps(self, expirable_field => time)
            )
          end

          ConcernsOnRails::Support::BatchOps.run(
            active,
            label: "ConcernsOnRails::Models::Expirable",
            message: "failed to expire record"
          ) { |record| record.expire!(time) }
        end

        private

        # Whether the single-UPDATE fast path is safe — the whole decision
        # (bang method unoverridden AND the model declares no validations,
        # plus why) lives in Support::BatchOps.fast_path?. Expirable defines
        # no lifecycle hooks, so `expire!` is the only method to check.
        def expirable_batch_fast_path?
          ConcernsOnRails::Support::BatchOps.fast_path?(self, ConcernsOnRails::Models::Expirable, :expire!)
        end

        # Scopes live here (not in `included do`) so their names can be affixed —
        # letting Expirable's `.active`/`.expired` coexist with the same-named
        # scopes from SoftDeletable / Activatable on a single model.
        def define_expirable_scopes(prefix, suffix)
          prefix = ConcernsOnRails::Support::Affix.normalize(prefix, default: expirable_field)
          suffix = ConcernsOnRails::Support::Affix.normalize(suffix, default: expirable_field)
          self.expirable_scope_names = %i[active expired expiring_within].to_h do |base|
            [base, ConcernsOnRails::Support::Affix.name(base, prefix: prefix, suffix: suffix)]
          end.freeze

          scope expirable_scope_names[:active], lambda {
            column = arel_table[expirable_field]
            where(column.eq(nil).or(column.gt(Time.zone.now)))
          }
          scope expirable_scope_names[:expired], lambda {
            where(arel_table[expirable_field].lteq(Time.zone.now))
          }
          scope expirable_scope_names[:expiring_within], lambda { |duration|
            column = arel_table[expirable_field]
            now = Time.zone.now
            where(column.gt(now)).where(column.lteq(now + duration))
          }
        end
      end

      def active?
        !expired?
      end

      # nil means never expires; equal-to-now is treated as expired (exclusive boundary).
      def expired?
        value = self[self.class.expirable_field]
        return false if value.nil?

        value <= Time.zone.now
      end

      def expire!(time = Time.zone.now)
        update(self.class.expirable_field => time)
      end

      # Push expiry forward by `by:`. If the record has no expiry yet, or has
      # already expired, the new expiry is `now + by`. Otherwise it's added to
      # the existing expiry.
      def extend_expiry!(by:)
        update(self.class.expirable_field => expiry_extension_base + by)
      end

      # Returns an ActiveSupport::Duration of how long until expiry, or nil
      # when there's no expiry set, or 0.seconds when already expired.
      def time_until_expiry
        value = self[self.class.expirable_field]
        return nil if value.nil?

        now = Time.zone.now
        return 0.seconds if value <= now

        (value - now).seconds
      end

      # Internal helper for extend_expiry! — not part of the public API
      # (postfix private: the keyword form trips RuboCop's scope analysis
      # against the `private` inside the class_methods block).
      def expiry_extension_base
        value = self[self.class.expirable_field]
        now = Time.zone.now
        value.nil? || value <= now ? now : value
      end
      private :expiry_extension_base
    end
  end
end
