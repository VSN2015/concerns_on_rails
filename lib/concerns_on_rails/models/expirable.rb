require "active_support/concern"
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/affix"
require "concerns_on_rails/support/batch_ops"
require "concerns_on_rails/support/hooked_write"

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
        # Integer count. A single UPDATE unless the model overrode `expire!`
        # or a lifecycle hook (before_expire / after_expire), or declares
        # validations (see Support::BatchOps.fast_path?) — then it streams
        # per record so the hooks run.
        def expire_all(time = Time.zone.now)
          time = expirable_cast_time(time)
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

        # The expiry time `expire!` / `expire_all` will write. nil or blank
        # (false, "", [] included) means now — the verbs' own default. Anything
        # else is cast through the column's attribute type, and a value that
        # casts to nothing raises BEFORE any hook runs: the write used to go
        # ahead, AR stored nil, and the record "expired" to never-expires.
        # (Internal: public only so the instance verbs can reach it.)
        def expirable_cast_time(time)
          return Time.zone.now if time.blank?

          cast = type_for_attribute(expirable_field.to_s).cast(time)
          return cast if cast.acts_like?(:time) || cast.acts_like?(:date)

          raise ArgumentError,
                "ConcernsOnRails::Models::Expirable: #{time.inspect} cannot be parsed as a time for " \
                "'#{expirable_field}' — pass a Time, a parseable String, or nil for now"
        end

        private

        # Whether the single-UPDATE fast path is safe — the whole decision
        # (bang method and hooks unoverridden AND the model declares no
        # validations, plus why) lives in Support::BatchOps.fast_path?.
        def expirable_batch_fast_path?
          ConcernsOnRails::Support::BatchOps.fast_path?(self, ConcernsOnRails::Models::Expirable,
                                                        :expire!, :before_expire, :after_expire)
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

          # The affix covers the predicates too: Activatable (`active?`) and
          # Schedulable (`expired?`) define the same plain names, and the
          # concern included last wins them.
          ConcernsOnRails::Support::Affix.define_predicates(
            self, { active: :expirable_live?, expired: :expirable_expired? }, prefix: prefix, suffix: suffix
          )
        end
      end

      # Plain names kept for compatibility. On a model that also includes
      # Activatable or Schedulable, the concern included LAST owns these;
      # configure `prefix:`/`suffix:` and use the affixed predicates
      # (`term_active?`, `term_expired?`) to keep Expirable's answer reachable.
      def active?
        expirable_live?
      end

      # nil means never expires; equal-to-now is treated as expired (exclusive boundary).
      def expired?
        expirable_expired?
      end

      # Lifecycle hooks — override in the model. Fired when a write actually
      # expires the record, i.e. `expire!` with a past-or-now time (and so by
      # `expire_all`). A FUTURE time only schedules expiry, so it fires
      # nothing — same as `extend_expiry!` (a renewal) or `clear_expiry!`.
      # Otherwise `after_expire { account.downgrade! }` paired with
      # `trial.expire_in!(14.days)` would downgrade the account immediately.
      # Overriding either hook moves `expire_all` to the per-record path.
      def before_expire; end
      def after_expire; end

      # Write the expiry (default: now, i.e. expire immediately; nil or blank
      # also means now, and an unparseable value raises ArgumentError before
      # any hook runs). The hooks and the write share one savepoint
      # (Support::HookedWrite): a raising after_expire — or one vetoing with
      # ActiveRecord::Rollback, even inside a caller's transaction or
      # expire_all — rolls the expiry back and returns false. A failed write
      # (validation) returns false, skips after_expire, and rolls back
      # before_expire's own side effects.
      def expire!(time = Time.zone.now)
        time = self.class.expirable_cast_time(time)
        hooks = time.to_time > Time.zone.now ? {} : { before: :before_expire, after: :after_expire }
        field = self.class.expirable_field
        ConcernsOnRails::Support::HookedWrite.run(self, restore: [field], **hooks) do
          update(field => time)
        end
      end

      # Set an absolute lifetime from now — `token.expire_in!(15.minutes)` —
      # whatever the current expiry. Sugar for `expire!(now + duration)`, so a
      # positive duration schedules expiry and fires no hooks.
      def expire_in!(duration)
        unless duration.respond_to?(:to_i) && !duration.is_a?(String)
          raise ArgumentError,
                "ConcernsOnRails::Models::Expirable: expire_in! takes a duration " \
                "(e.g. 15.minutes), got #{duration.class}"
        end

        expire!(Time.zone.now + duration)
      end

      # Make the record never expire (nil expiry). No hooks: nothing expired.
      def clear_expiry!
        update(self.class.expirable_field => nil)
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

      # The unaffixed checks behind the public predicates. Internal logic and
      # the affixed predicates call these, never `active?` / `expired?`,
      # which a sibling concern may own.
      def expirable_expired?
        value = self[self.class.expirable_field]
        return false if value.nil?

        value <= Time.zone.now
      end

      def expirable_live?
        !expirable_expired?
      end

      private :expiry_extension_base, :expirable_expired?, :expirable_live?
    end
  end
end
