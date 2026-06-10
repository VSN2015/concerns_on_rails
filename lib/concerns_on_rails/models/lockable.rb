require "active_support/concern"

module ConcernsOnRails
  module Models
    # Failed-attempt tracking + account lockout ("Devise lockable-lite") for
    # apps rolling their own authentication (Rails 8 generator,
    # has_secure_password) — which ships no brute-force protection at all.
    # Two columns on the model's own table, no tokens, no mailers.
    #
    #   class User < ApplicationRecord
    #     include ConcernsOnRails::Lockable
    #
    #     lockable_by max_attempts: 5, unlock_in: 15.minutes
    #     # lockable_by attempts: :failed_logins, locked_at: :locked_until_at,
    #     #             prefix: :account     # => .account_locked / .account_unlocked
    #   end
    #
    #   user.register_failed_attempt!   # atomic SQL increment; locks at max_attempts
    #   user.access_locked?             # true while locked (expires after unlock_in)
    #   user.attempts_remaining         # for "3 attempts remaining" flash messages
    #   user.reset_failed_attempts!     # call on successful login
    #   user.lock_access! / user.unlock_access!
    #   User.locked / User.unlocked     # expiry-aware scopes
    #
    # Notes:
    #   * `unlock_in: nil` (the default) means locked until unlock_access! is
    #     called; with a duration, the lock lapses by itself. Expiry is lazy —
    #     readers and scopes treat a stale `locked_at` as unlocked but never
    #     write — so the column is cleared on the next unlock_access! or
    #     register_failed_attempt! (quietly there: no unlock hooks fire from a
    #     failed login). The expiry instant itself counts as unlocked.
    #   * register_failed_attempt! increments with update_counters — a single
    #     SQL-side `COALESCE(attempts, 0) + 1`, so concurrent failures never
    #     lose updates (in-Ruby increment! is read-modify-write before Rails
    #     5.2) and a NULL counter needs no column default. While the account is
    #     locked it stops counting and returns the current count unchanged.
    #     Two requests crossing the threshold at the same instant may each fire
    #     after_lock once (same property as Devise).
    #   * lock_access!/unlock_access! persist via update_columns: validations
    #     and AR callbacks are bypassed on purpose, so an otherwise-invalid
    #     record can still be locked. That also skips updated_at and means a
    #     coexisting Auditable will not record the change. Hooks (before/
    #     after_lock, before/after_unlock) run in a transaction — a raising
    #     hook rolls the write back. reset_failed_attempts! fires no hooks.
    #   * All bang methods raise ArgumentError on unsaved records.
    #   * Reach for Devise's lockable when you need unlock tokens, unlock
    #     emails, or per-strategy unlocks.
    module Lockable
      extend ActiveSupport::Concern

      LABEL = "ConcernsOnRails::Models::Lockable".freeze
      DEFAULT_ATTEMPTS_FIELD = :failed_attempts
      DEFAULT_LOCKED_AT_FIELD = :locked_at
      DEFAULT_MAX_ATTEMPTS = 5

      included do
        class_attribute :lockable_attempts_field, instance_accessor: false, default: DEFAULT_ATTEMPTS_FIELD
        class_attribute :lockable_locked_at_field, instance_accessor: false, default: DEFAULT_LOCKED_AT_FIELD
        class_attribute :lockable_max_attempts, instance_accessor: false, default: DEFAULT_MAX_ATTEMPTS
        class_attribute :lockable_unlock_in, instance_accessor: false, default: nil
      end

      module ClassMethods
        include ConcernsOnRails::Support::ColumnGuard

        # Configure the lockout columns and policy. See the module docs.
        def lockable_by(attempts: DEFAULT_ATTEMPTS_FIELD, locked_at: DEFAULT_LOCKED_AT_FIELD,
                        max_attempts: DEFAULT_MAX_ATTEMPTS, unlock_in: nil, prefix: nil, suffix: nil)
          attempts = attempts.to_sym
          locked_at = locked_at.to_sym
          validate_lockable!(attempts, locked_at, max_attempts: max_attempts, unlock_in: unlock_in)

          self.lockable_attempts_field = attempts
          self.lockable_locked_at_field = locked_at
          self.lockable_max_attempts = max_attempts
          self.lockable_unlock_in = unlock_in
          ensure_columns!(LABEL, attempts, locked_at)
          validate_lockable_attempts_column!(attempts)
          define_lockable_scopes(prefix, suffix)
        end

        private

        def validate_lockable!(attempts, locked_at, max_attempts:, unlock_in:)
          raise ArgumentError, "#{LABEL}: attempts and locked_at must be different columns" if attempts == locked_at
          unless positive_integer_or_nil?(max_attempts)
            raise ArgumentError, "#{LABEL}: max_attempts must be a positive Integer or nil (nil = never auto-lock)"
          end
          unless positive_duration_or_nil?(unlock_in)
            raise ArgumentError, "#{LABEL}: unlock_in must be a positive duration (e.g. 15.minutes) or nil"
          end
        end

        # The increment happens in SQL arithmetic, so the column must really be
        # an integer — a string column would "work" on SQLite and corrupt
        # silently elsewhere. (locked_at is not type-checked: the AR type
        # symbol for timestamp columns varies by adapter and Rails version.)
        def validate_lockable_attempts_column!(attempts)
          return if columns_hash[attempts.to_s]&.type == :integer

          raise ArgumentError, "#{LABEL}: '#{attempts}' must be an integer column"
        end

        # Scopes live here (not in `included do`) so their names can be affixed
        # via prefix:/suffix: — letting `.locked` coexist with a same-named
        # scope from another source on one model. Lambdas branch on the
        # configuration and compute the cutoff in Ruby at call time, so the
        # predicate stays portable (no adapter-specific SQL date math).
        def define_lockable_scopes(prefix, suffix)
          scope lockable_scope_name(:locked, prefix, suffix), lambda {
            field = lockable_locked_at_field
            if lockable_unlock_in
              where(arel_table[field].gt(Time.zone.now - lockable_unlock_in))
            else
              where.not(field => nil)
            end
          }
          scope lockable_scope_name(:unlocked, prefix, suffix), lambda {
            field = lockable_locked_at_field
            if lockable_unlock_in
              column = arel_table[field]
              where(column.eq(nil).or(column.lteq(Time.zone.now - lockable_unlock_in)))
            else
              where(field => nil)
            end
          }
        end

        def lockable_scope_name(base, prefix, suffix)
          [prefix, base, suffix].compact.join("_").to_sym
        end

        def positive_integer_or_nil?(value)
          value.nil? || (value.is_a?(Integer) && value.positive?)
        end

        def positive_duration_or_nil?(value)
          return true if value.nil?

          (value.is_a?(ActiveSupport::Duration) || value.is_a?(Numeric)) && value.to_f.positive?
        end
      end

      # ---- lifecycle hooks (override in the model) ----
      # after_lock is the place for "your account has been locked" emails.
      def before_lock; end
      def after_lock; end
      def before_unlock; end
      def after_unlock; end

      # ---- instance methods ----

      # Record one failed authentication attempt and auto-lock at the
      # threshold. Returns the fresh post-increment count (handy for
      # "N attempts remaining" messaging); check access_locked? for the
      # lock decision. While locked it neither counts nor re-locks — that
      # branch returns the current in-memory count unchanged.
      def register_failed_attempt!
        lockable_guard_persisted!("register_failed_attempt!")
        return lockable_current_attempts if access_locked?

        # A lapsed lock is cleared quietly — this is a *failed* login, so
        # firing unlock hooks ("account unlocked" notifications) would be
        # wrong. The failure below then counts as attempt 1 of the new window.
        lockable_clear_expired_lock! if lock_expired?

        self.class.update_counters(id, self.class.lockable_attempts_field => 1)
        fresh = lockable_fresh_attempts_count
        lockable_sync_attempts(fresh)

        max = self.class.lockable_max_attempts
        lock_access! if max && fresh >= max
        fresh
      end

      # Lock now (update_columns — no validations/callbacks). Idempotent while
      # locked; an expired lock is re-locked with a fresh timestamp. Returns
      # true, or false when a hook aborted the write via ActiveRecord::Rollback.
      def lock_access!
        lockable_guard_persisted!("lock_access!")
        return true if access_locked?

        field = self.class.lockable_locked_at_field
        lockable_write_with_hooks(field => self[field]) do
          before_lock
          update_columns(field => Time.zone.now)
          after_lock
        end
      end

      # Clear the lock and zero the counter in one write. Fires unlock hooks.
      # Returns true, or false when a hook aborted via ActiveRecord::Rollback.
      def unlock_access!
        lockable_guard_persisted!("unlock_access!")
        locked_field = self.class.lockable_locked_at_field
        return true if self[locked_field].nil?

        attempts_field = self.class.lockable_attempts_field
        lockable_write_with_hooks(locked_field => self[locked_field],
                                  attempts_field => self[attempts_field]) do
          before_unlock
          update_columns(locked_field => nil, attempts_field => 0)
          after_unlock
        end
      end

      # Successful-login path: zero the counter, leave any lock untouched,
      # fire no hooks. (Unlocking is a separate, deliberate act.) The
      # already-zero short-circuit saves a write per successful login.
      def reset_failed_attempts!
        lockable_guard_persisted!("reset_failed_attempts!")
        return true if lockable_current_attempts.zero?

        update_column(self.class.lockable_attempts_field, 0)
        true
      end

      # Locked right now? Lazy expiry: a stale locked_at reads as unlocked but
      # is never cleared here — readers stay side-effect free.
      def access_locked?
        self[self.class.lockable_locked_at_field].present? && !lock_expired?
      end

      # Was locked, and the unlock_in window has fully elapsed. Always false
      # when unlock_in is nil (manual unlock only). The boundary instant
      # counts as expired (= unlocked), matching the scopes.
      def lock_expired?
        unlock_in = self.class.lockable_unlock_in
        return false unless unlock_in

        locked_at = self[self.class.lockable_locked_at_field]
        return false if locked_at.nil?

        locked_at <= Time.zone.now - unlock_in
      end

      # When the current lock lapses, or nil (not locked, or manual-only).
      def lock_expires_at
        unlock_in = self.class.lockable_unlock_in
        locked_at = self[self.class.lockable_locked_at_field]
        return nil if unlock_in.nil? || locked_at.nil?

        locked_at + unlock_in
      end

      # Failures left before auto-lock (never negative); nil when
      # max_attempts is nil (counting without auto-lock).
      def attempts_remaining
        max = self.class.lockable_max_attempts
        return nil unless max

        [max - lockable_current_attempts, 0].max
      end

      private

      def lockable_guard_persisted!(operation)
        raise ArgumentError, "#{LABEL}: #{operation} cannot be called on a new record" if new_record?
      end

      # Run hooks + update_columns inside a transaction, restoring the
      # in-memory attributes when the block doesn't complete. update_columns
      # syncs the attribute cache immediately and a transaction ROLLBACK does
      # not undo that — without the restore, a raising after_lock would leave
      # access_locked? true in memory while the row stays unlocked, and every
      # retry would no-op on the idempotency guard. ensure (not rescue) so a
      # throwing hook is covered too. Returns the completion flag, not a
      # blanket true: a hook raising ActiveRecord::Rollback is swallowed by
      # `transaction`, and the caller must see false — not a fake success —
      # when nothing was written.
      def lockable_write_with_hooks(previous_values)
        completed = false
        begin
          transaction do
            yield
            completed = true
          end
        ensure
          unless completed
            previous_values.each { |field, value| self[field] = value }
            send(:clear_attribute_changes, previous_values.keys.map(&:to_s))
          end
        end
        completed
      end

      def lockable_current_attempts
        self[self.class.lockable_attempts_field] || 0
      end

      # No hooks on purpose — see register_failed_attempt!.
      def lockable_clear_expired_lock!
        update_columns(self.class.lockable_locked_at_field => nil,
                       self.class.lockable_attempts_field => 0)
      end

      # Read the post-increment count back. unscoped, so a coexisting
      # default_scope (e.g. SoftDeletable's) cannot hide the row. nil (row
      # deleted concurrently) collapses to 0.
      def lockable_fresh_attempts_count
        self.class.unscoped.where(self.class.primary_key => id)
            .pluck(self.class.lockable_attempts_field).first.to_i
      end

      # Mirror the SQL-side increment into the in-memory attribute without
      # leaving it dirty — otherwise a later save would write the counter
      # again (and a coexisting Auditable would record a phantom change).
      # clear_attribute_changes flips public/private across Rails versions,
      # hence send.
      def lockable_sync_attempts(fresh)
        field = self.class.lockable_attempts_field
        self[field] = fresh
        send(:clear_attribute_changes, [field.to_s])
      end
    end
  end
end
