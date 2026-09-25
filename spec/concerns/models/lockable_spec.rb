# frozen_string_literal: true

require "spec_helper"

describe ConcernsOnRails::Lockable do
  before(:each) do
    ActiveRecord::Schema.define do
      create_table :lock_users, force: true do |t|
        t.string :email
        t.integer :failed_attempts, default: 0
        t.datetime :locked_at
        t.datetime :deleted_at
        t.timestamps
      end

      # No default on the counter — exercises the NULL-coalescing increment.
      create_table :bare_lock_users, force: true do |t|
        t.integer :failed_attempts
        t.datetime :locked_at
      end
    end

    class LockUser < TestModel
      include ConcernsOnRails::Lockable

      lockable_by max_attempts: 3

      attr_accessor :events

      def record_event(name)
        (self.events ||= []) << name
      end

      def before_lock = record_event(:before_lock)
      def after_lock = record_event(:after_lock)
      def before_unlock = record_event(:before_unlock)
      def after_unlock = record_event(:after_unlock)
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
    Object.send(:remove_const, :LockUser) if defined?(LockUser)
  end

  def expiring_class(unlock_in: 15.minutes, max_attempts: 3)
    Class.new(TestModel) do
      self.table_name = "lock_users"
      include ConcernsOnRails::Lockable

      lockable_by max_attempts: max_attempts, unlock_in: unlock_in
    end
  end

  describe ".lockable_by" do
    it "raises if the attempts column does not exist" do
      expect do
        Class.new(TestModel) do
          self.table_name = "lock_users"
          include ConcernsOnRails::Lockable

          lockable_by attempts: :nope
        end
      end.to raise_error(ArgumentError, /'nope' does not exist/)
    end

    it "raises if the locked_at column does not exist" do
      expect do
        Class.new(TestModel) do
          self.table_name = "lock_users"
          include ConcernsOnRails::Lockable

          lockable_by locked_at: :nope
        end
      end.to raise_error(ArgumentError, /'nope' does not exist/)
    end

    it "raises when attempts and locked_at name the same column" do
      expect do
        Class.new(TestModel) do
          self.table_name = "lock_users"
          include ConcernsOnRails::Lockable

          lockable_by attempts: :failed_attempts, locked_at: :failed_attempts
        end
      end.to raise_error(ArgumentError, /must be different columns/)
    end

    it "raises when the attempts column is not an integer column" do
      expect do
        Class.new(TestModel) do
          self.table_name = "lock_users"
          include ConcernsOnRails::Lockable

          lockable_by attempts: :email
        end
      end.to raise_error(ArgumentError, /'email' must be an integer column/)
    end

    it "raises when max_attempts is not a positive Integer or nil" do
      [0, -1, "5", 2.5].each do |bad|
        expect do
          Class.new(TestModel) do
            self.table_name = "lock_users"
            include ConcernsOnRails::Lockable

            lockable_by max_attempts: bad
          end
        end.to raise_error(ArgumentError, /max_attempts must be a positive Integer or nil/), "expected rejection for #{bad.inspect}"
      end
    end

    it "raises when unlock_in is not a positive duration or nil" do
      [0, -5.minutes, "15"].each do |bad|
        expect do
          Class.new(TestModel) do
            self.table_name = "lock_users"
            include ConcernsOnRails::Lockable

            lockable_by unlock_in: bad
          end
        end.to raise_error(ArgumentError, /unlock_in must be a positive duration/), "expected rejection for #{bad.inspect}"
      end
    end

    it "uses the default column names with no arguments" do
      klass = Class.new(TestModel) do
        self.table_name = "lock_users"
        include ConcernsOnRails::Lockable

        lockable_by
      end

      expect(klass.lockable_attempts_field).to eq(:failed_attempts)
      expect(klass.lockable_locked_at_field).to eq(:locked_at)
      expect(klass.lockable_max_attempts).to eq(5)
      expect(klass.lockable_unlock_in).to be_nil
    end

    it "reconfigures on a second call (last wins)" do
      klass = Class.new(TestModel) do
        self.table_name = "lock_users"
        include ConcernsOnRails::Lockable

        lockable_by max_attempts: 5
        lockable_by max_attempts: 1
      end

      user = klass.create!(email: "a@b.c")
      user.register_failed_attempt!
      expect(user.access_locked?).to be(true)
    end
  end

  describe "#register_failed_attempt!" do
    it "increments the counter, persists it, and returns the fresh count" do
      user = LockUser.create!(email: "a@b.c")

      expect(user.register_failed_attempt!).to eq(1)
      expect(user.register_failed_attempt!).to eq(2)
      expect(user.reload.failed_attempts).to eq(2)
    end

    it "coalesces a NULL counter to 0 before incrementing" do
      klass = Class.new(TestModel) do
        self.table_name = "bare_lock_users"
        include ConcernsOnRails::Lockable

        lockable_by
      end
      user = klass.create!

      expect(user.failed_attempts).to be_nil
      expect(user.register_failed_attempt!).to eq(1)
      expect(user.reload.failed_attempts).to eq(1)
    end

    it "leaves the synced attempts attribute clean (not dirty)" do
      user = LockUser.create!(email: "a@b.c")
      user.register_failed_attempt!

      expect(user.failed_attempts).to eq(1)
      expect(user.changed?).to be(false)
    end

    it "does not lock below the threshold" do
      user = LockUser.create!(email: "a@b.c")
      user.register_failed_attempt!
      user.register_failed_attempt!

      expect(user.access_locked?).to be(false)
    end

    it "locks when the count reaches max_attempts exactly" do
      user = LockUser.create!(email: "a@b.c")
      3.times { user.register_failed_attempt! }

      expect(user.access_locked?).to be(true)
      expect(user.reload.locked_at).to be_present
    end

    it "fires the lock hooks when the threshold is crossed" do
      user = LockUser.create!(email: "a@b.c")
      3.times { user.register_failed_attempt! }

      expect(user.events).to eq(%i[before_lock after_lock])
    end

    it "locks on the first failure with max_attempts: 1" do
      klass = Class.new(TestModel) do
        self.table_name = "lock_users"
        include ConcernsOnRails::Lockable

        lockable_by max_attempts: 1
      end
      user = klass.create!(email: "a@b.c")

      user.register_failed_attempt!
      expect(user.access_locked?).to be(true)
    end

    it "counts but never auto-locks with max_attempts: nil" do
      klass = Class.new(TestModel) do
        self.table_name = "lock_users"
        include ConcernsOnRails::Lockable

        lockable_by max_attempts: nil
      end
      user = klass.create!(email: "a@b.c")

      10.times { user.register_failed_attempt! }
      expect(user.reload.failed_attempts).to eq(10)
      expect(user.access_locked?).to be(false)
    end

    it "does not increment a locked account and returns the current count" do
      user = LockUser.create!(email: "a@b.c")
      3.times { user.register_failed_attempt! }

      expect(user.register_failed_attempt!).to eq(3)
      expect(user.reload.failed_attempts).to eq(3)
    end

    it "quietly resets an expired lock and counts the failure as attempt 1" do
      user = expiring_class.create!(email: "a@b.c")
      3.times { user.register_failed_attempt! }
      expect(user.access_locked?).to be(true)

      travel_to(16.minutes.from_now) do
        expect(user.register_failed_attempt!).to eq(1)
        expect(user.access_locked?).to be(false)
        expect(user.reload.locked_at).to be_nil
      end
    end

    it "does not fire unlock hooks when clearing an expired lock" do
      klass = expiring_class
      unlocks = []
      klass.define_method(:after_unlock) { unlocks << :after_unlock }
      user = klass.create!(email: "a@b.c")
      3.times { user.register_failed_attempt! }

      travel_to(16.minutes.from_now) { user.register_failed_attempt! }
      expect(unlocks).to be_empty
    end

    it "does not lose updates across two instances of the same row" do
      user_a = LockUser.create!(email: "a@b.c")
      user_b = LockUser.find(user_a.id)

      expect(user_a.register_failed_attempt!).to eq(1)
      expect(user_b.register_failed_attempt!).to eq(2)
      expect(user_a.reload.failed_attempts).to eq(2)
    end

    it "raises a labeled ArgumentError on a new record" do
      expect { LockUser.new.register_failed_attempt! }
        .to raise_error(ArgumentError, /Lockable: register_failed_attempt! cannot be called on a new record/)
    end
  end

  describe "#access_locked? / #lock_expired?" do
    it "is false for a never-locked record" do
      user = LockUser.create!(email: "a@b.c")

      expect(user.access_locked?).to be(false)
      expect(user.lock_expired?).to be(false)
    end

    it "is true after lock_access!" do
      user = LockUser.create!(email: "a@b.c")
      user.lock_access!

      expect(user.access_locked?).to be(true)
    end

    it "expires at exactly locked_at + unlock_in (boundary excluded)" do
      user = expiring_class.create!(email: "a@b.c")
      start = Time.zone.now
      travel_to(start) { user.lock_access! }

      travel_to(start + 15.minutes - 1.second) do
        expect(user.access_locked?).to be(true)
        expect(user.lock_expired?).to be(false)
      end
      travel_to(start + 15.minutes) do
        expect(user.access_locked?).to be(false)
        expect(user.lock_expired?).to be(true)
      end
    end

    it "stays locked arbitrarily far in the future with unlock_in nil" do
      user = LockUser.create!(email: "a@b.c")
      user.lock_access!

      travel_to(10.years.from_now) do
        expect(user.access_locked?).to be(true)
        expect(user.lock_expired?).to be(false)
      end
    end

    it "does not modify the column when reading an expired lock" do
      user = expiring_class.create!(email: "a@b.c")
      user.lock_access!

      travel_to(16.minutes.from_now) do
        expect(user.access_locked?).to be(false)
        expect(user.reload.locked_at).to be_present
      end
    end
  end

  describe "#lock_access!" do
    it "on a stale instance adopts the lock already in the row: no second write, no hooks" do
      user = LockUser.create!(email: "a@b.c")
      stale = LockUser.find(user.id)
      user.lock_access!
      locked_at = LockUser.find(user.id).locked_at

      expect(stale.lock_access!).to be(true)
      expect(stale.events).to be_nil
      expect(stale.locked_at).to eq(locked_at)
      expect(stale.access_locked?).to be(true)
      expect(stale.changed?).to be(false)
      expect(LockUser.find(user.id).locked_at).to eq(locked_at)
    end

    it "locks a record that fails validations (update_columns bypass)" do
      klass = Class.new(TestModel) do
        self.table_name = "lock_users"
        include ConcernsOnRails::Lockable

        lockable_by
        validates :email, presence: true
      end
      user = klass.create!(email: "a@b.c")
      user.email = nil

      expect(user.lock_access!).to be(true)
      expect(user.reload.locked_at).to be_present
    end

    it "locks even when a before_update callback throws :abort" do
      klass = Class.new(TestModel) do
        self.table_name = "lock_users"
        include ConcernsOnRails::Lockable

        lockable_by
        before_update { throw :abort }
      end
      user = klass.create!(email: "a@b.c")

      expect(user.lock_access!).to be(true)
      expect(user.reload.locked_at).to be_present
    end

    it "is idempotent while locked (hooks not re-fired)" do
      user = LockUser.create!(email: "a@b.c")
      user.lock_access!
      first_locked_at = user.reload.locked_at

      expect(user.lock_access!).to be(true)
      expect(user.reload.locked_at).to eq(first_locked_at)
      expect(user.events).to eq(%i[before_lock after_lock])
    end

    it "re-locks an expired lock with a fresh timestamp" do
      user = expiring_class.create!(email: "a@b.c")
      start = Time.zone.now
      travel_to(start) { user.lock_access! }

      travel_to(start + 16.minutes) do
        user.lock_access!
        expect(user.reload.locked_at).to be_within(1.second).of(Time.zone.now)
        expect(user.access_locked?).to be(true)
      end
    end

    it "rolls the lock back when after_lock raises" do
      klass = Class.new(TestModel) do
        self.table_name = "lock_users"
        include ConcernsOnRails::Lockable

        lockable_by

        def after_lock
          raise "boom"
        end
      end
      user = klass.create!(email: "a@b.c")

      expect { user.lock_access! }.to raise_error("boom")
      expect(user.reload.locked_at).to be_nil
    end

    it "returns false (not a fake success) when a hook aborts via ActiveRecord::Rollback" do
      klass = Class.new(TestModel) do
        self.table_name = "lock_users"
        include ConcernsOnRails::Lockable

        lockable_by

        def before_lock
          raise ActiveRecord::Rollback
        end
      end
      user = klass.create!(email: "a@b.c")

      expect(user.lock_access!).to be(false)
      expect(user.access_locked?).to be(false)
      expect(user.reload.locked_at).to be_nil
    end

    it "restores in-memory state after a raising hook, so a retry can still lock" do
      raise_once = true
      klass = Class.new(TestModel) do
        self.table_name = "lock_users"
        include ConcernsOnRails::Lockable

        lockable_by
      end
      klass.define_method(:after_lock) do
        return unless raise_once

        raise_once = false
        raise "boom"
      end
      user = klass.create!(email: "a@b.c")

      expect { user.lock_access! }.to raise_error("boom")
      expect(user.access_locked?).to be(false) # in-memory agrees with the rolled-back row

      expect(user.lock_access!).to be(true)    # retry is not silently no-oped
      expect(user.reload.locked_at).to be_present
    end

    it "raises a labeled ArgumentError on a new record" do
      expect { LockUser.new.lock_access! }
        .to raise_error(ArgumentError, /lock_access! cannot be called on a new record/)
    end
  end

  describe "#unlock_access!" do
    it "clears the lock and zeroes the counter" do
      user = LockUser.create!(email: "a@b.c")
      3.times { user.register_failed_attempt! }

      expect(user.unlock_access!).to be(true)
      user.reload
      expect(user.locked_at).to be_nil
      expect(user.failed_attempts).to eq(0)
      expect(user.access_locked?).to be(false)
    end

    it "fires the unlock hooks" do
      user = LockUser.create!(email: "a@b.c")
      user.lock_access!
      user.events.clear

      user.unlock_access!
      expect(user.events).to eq(%i[before_unlock after_unlock])
    end

    it "is a hook-free no-op when not locked" do
      user = LockUser.create!(email: "a@b.c")

      expect(user.unlock_access!).to be(true)
      expect(user.events).to be_nil
    end

    it "rolls back when after_unlock raises" do
      klass = Class.new(TestModel) do
        self.table_name = "lock_users"
        include ConcernsOnRails::Lockable

        lockable_by

        def after_unlock
          raise "boom"
        end
      end
      user = klass.create!(email: "a@b.c")
      user.lock_access!

      expect { user.unlock_access! }.to raise_error("boom")
      expect(user.reload.locked_at).to be_present
    end

    it "restores in-memory state after a raising hook, so a retry can still unlock" do
      raise_once = true
      klass = Class.new(TestModel) do
        self.table_name = "lock_users"
        include ConcernsOnRails::Lockable

        lockable_by
      end
      klass.define_method(:after_unlock) do
        return unless raise_once

        raise_once = false
        raise "boom"
      end
      user = klass.create!(email: "a@b.c")
      user.lock_access!

      expect { user.unlock_access! }.to raise_error("boom")
      expect(user.access_locked?).to be(true)  # in-memory agrees with the rolled-back row

      expect(user.unlock_access!).to be(true)  # retry is not silently no-oped
      expect(user.reload.locked_at).to be_nil
    end

    it "raises a labeled ArgumentError on a new record" do
      expect { LockUser.new.unlock_access! }
        .to raise_error(ArgumentError, /unlock_access! cannot be called on a new record/)
    end
  end

  describe "#reset_failed_attempts!" do
    it "zeroes the counter without touching the lock" do
      user = LockUser.create!(email: "a@b.c")
      3.times { user.register_failed_attempt! }

      expect(user.reset_failed_attempts!).to be(true)
      user.reload
      expect(user.failed_attempts).to eq(0)
      expect(user.locked_at).to be_present
    end

    it "no-ops when the counter is already zero" do
      user = LockUser.create!(email: "a@b.c")

      expect(user.reset_failed_attempts!).to be(true)
      expect(user.events).to be_nil
    end

    it "raises a labeled ArgumentError on a new record" do
      expect { LockUser.new.reset_failed_attempts! }
        .to raise_error(ArgumentError, /reset_failed_attempts! cannot be called on a new record/)
    end
  end

  describe "helpers" do
    it "attempts_remaining counts down and floors at zero" do
      user = LockUser.create!(email: "a@b.c")

      expect(user.attempts_remaining).to eq(3)
      user.register_failed_attempt!
      expect(user.attempts_remaining).to eq(2)
      3.times { user.register_failed_attempt! }
      expect(user.attempts_remaining).to eq(0)
    end

    it "attempts_remaining treats a NULL counter as zero failures" do
      klass = Class.new(TestModel) do
        self.table_name = "bare_lock_users"
        include ConcernsOnRails::Lockable

        lockable_by max_attempts: 4
      end

      expect(klass.create!.attempts_remaining).to eq(4)
    end

    it "attempts_remaining is nil with max_attempts: nil" do
      klass = Class.new(TestModel) do
        self.table_name = "lock_users"
        include ConcernsOnRails::Lockable

        lockable_by max_attempts: nil
      end

      expect(klass.create!(email: "a@b.c").attempts_remaining).to be_nil
    end

    it "lock_expires_at returns locked_at + unlock_in when locked" do
      user = expiring_class.create!(email: "a@b.c")
      user.lock_access!

      expect(user.lock_expires_at).to be_within(1.second).of(15.minutes.from_now)
    end

    it "lock_expires_at is nil when unlocked or when unlock_in is nil" do
      expect(expiring_class.create!(email: "a@b.c").lock_expires_at).to be_nil

      manual = LockUser.create!(email: "a@b.c")
      manual.lock_access!
      expect(manual.lock_expires_at).to be_nil
    end
  end

  describe "scopes" do
    it "partitions by locked_at presence when unlock_in is nil" do
      locked = LockUser.create!(email: "locked@b.c")
      locked.lock_access!
      free = LockUser.create!(email: "free@b.c")

      expect(LockUser.locked).to contain_exactly(locked)
      expect(LockUser.unlocked).to contain_exactly(free)
    end

    it "moves an expired row from .locked to .unlocked" do
      klass = expiring_class
      user = klass.create!(email: "a@b.c")
      user.lock_access!

      expect(klass.locked).to contain_exactly(user)
      travel_to(16.minutes.from_now) do
        expect(klass.locked).to be_empty
        expect(klass.unlocked).to contain_exactly(user)
      end
    end

    it "agrees with access_locked? at the exact expiry boundary" do
      klass = expiring_class
      user = klass.create!(email: "a@b.c")
      start = Time.zone.now
      travel_to(start) { user.lock_access! }

      travel_to(start + 15.minutes) do
        expect(user.access_locked?).to be(false)
        expect(klass.locked).to be_empty
        expect(klass.unlocked).to contain_exactly(user)
      end
    end

    it "affixes the scope names via prefix:" do
      klass = Class.new(TestModel) do
        self.table_name = "lock_users"
        include ConcernsOnRails::Lockable

        lockable_by prefix: :account
      end

      expect(klass).to respond_to(:account_locked)
      expect(klass).to respond_to(:account_unlocked)
      expect(klass).not_to respond_to(:locked)
    end
  end

  describe "coexistence with SoftDeletable" do
    it "still counts attempts for a soft-deleted record (default_scope bypass)" do
      klass = Class.new(TestModel) do
        self.table_name = "lock_users"
        include ConcernsOnRails::SoftDeletable
        include ConcernsOnRails::Lockable

        soft_deletable_by :deleted_at
        lockable_by
      end
      user = klass.create!(email: "a@b.c")
      user.soft_delete!

      expect(user.register_failed_attempt!).to eq(1)
      expect(klass.unscoped.find(user.id).failed_attempts).to eq(1)
    end
  end

  describe "#unlock_expired" do
    before do
      ActiveRecord::Schema.define do
        create_table :batch_accounts, force: true do |t|
          t.integer :failed_attempts, default: 0
          t.datetime :locked_at
        end
      end
    end

    def lockable_class(**options)
      Class.new(TestModel) do
        self.table_name = "batch_accounts"
        include ConcernsOnRails::Lockable

        lockable_by(attempts: :failed_attempts, locked_at: :locked_at, **options)
      end
    end

    it "unlocks only the rows whose window has elapsed, and returns the count" do
      klass = lockable_class(unlock_in: 15.minutes)
      stale = klass.create!(failed_attempts: 5, locked_at: 1.hour.ago)
      fresh = klass.create!(failed_attempts: 5, locked_at: 1.minute.ago)
      never = klass.create!(failed_attempts: 2, locked_at: nil)

      expect(klass.unlock_expired).to eq(1)

      expect(stale.reload.locked_at).to be_nil
      expect(stale.failed_attempts).to eq(0)
      expect(fresh.reload.locked_at).not_to be_nil
      expect(fresh.failed_attempts).to eq(5)
      expect(never.reload.failed_attempts).to eq(2)
    end

    it "returns 0 when unlock_in is nil" do
      klass = lockable_class(unlock_in: nil)
      klass.create!(failed_attempts: 5, locked_at: 1.year.ago)

      expect(klass.unlock_expired).to eq(0)
      expect(klass.first.locked_at).not_to be_nil
    end

    it "is idempotent" do
      klass = lockable_class(unlock_in: 15.minutes)
      klass.create!(failed_attempts: 5, locked_at: 1.hour.ago)
      klass.unlock_expired

      expect(klass.unlock_expired).to eq(0)
    end

    it "fires the unlock hooks once per record when they are overridden" do
      klass = Class.new(TestModel) do
        self.table_name = "batch_accounts"
        include ConcernsOnRails::Lockable

        lockable_by attempts: :failed_attempts, locked_at: :locked_at, unlock_in: 15.minutes

        cattr_accessor :unlocked_ids
        self.unlocked_ids = []

        def after_unlock
          self.class.unlocked_ids << id
        end
      end
      stub_const("HookedAccount", klass)
      a = HookedAccount.create!(failed_attempts: 5, locked_at: 1.hour.ago)

      expect(HookedAccount.unlock_expired).to eq(1)
      expect(HookedAccount.unlocked_ids).to eq([a.id])
    end
  end

  describe "ActiveRecord::Rollback from after_lock" do
    before do
      class RollbackAccount < TestModel
        include ConcernsOnRails::Lockable

        self.table_name = "lock_users"

        lockable_by max_attempts: 3

        def after_lock
          raise ActiveRecord::Rollback
        end
      end
    end

    after { Object.send(:remove_const, :RollbackAccount) if defined?(RollbackAccount) }

    it "rolls the lock back when called standalone" do
      u = RollbackAccount.create!(email: "a@b.com")

      expect(u.lock_access!).to be(false)
      expect(u.reload.locked_at).to be_nil
    end

    # A bare `transaction` JOINS the caller's, so Rails swallowed the Rollback
    # and committed the lock — while the ensure restored locked_at = nil in
    # memory and lock_access! returned false. The DB said locked, the model
    # said unlocked, and the idempotency guard made every retry a no-op.
    it "rolls the lock back inside an enclosing transaction" do
      u = RollbackAccount.create!(email: "a@b.com")

      ActiveRecord::Base.transaction { u.lock_access! }

      expect(u.reload.locked_at).to be_nil
      expect(u.access_locked?).to be(false)
    end

    it "leaves the caller's own writes in the enclosing transaction intact" do
      u = RollbackAccount.create!(email: "a@b.com")
      other = RollbackAccount.create!(email: "c@d.com")

      ActiveRecord::Base.transaction do
        other.update!(email: "renamed@b.com")
        u.lock_access!
      end

      expect(other.reload.email).to eq("renamed@b.com")
      expect(u.reload.locked_at).to be_nil
    end
  end

  describe "unlock_token: (self-service unlock)" do
    before do
      ActiveRecord::Schema.define do
        create_table :token_lock_users, force: true do |t|
          t.string :email
          t.integer :failed_attempts, default: 0
          t.datetime :locked_at
          t.string :unlock_token
        end

        create_table :naked_lock_users, force: true do |t|
          t.string :email
        end
      end
    end

    let(:klass) do
      Class.new(TestModel) do
        self.table_name = "token_lock_users"
        include ConcernsOnRails::Lockable

        lockable_by max_attempts: 2, unlock_in: 15.minutes, unlock_token: :unlock_token

        attr_accessor :events

        def after_unlock
          (self.events ||= []) << :after_unlock
        end
      end
    end

    let(:user) { klass.create!(email: "a@x.com") }

    it "mints a URL-safe token in the same write as the lock and clears it on unlock" do
      expect(user.unlock_token).to be_nil
      user.lock_access!
      expect(user.unlock_token).to match(/\A[A-Za-z0-9_-]{43}\z/)
      expect(user.reload.unlock_token).to be_present
      expect(user.access_locked?).to be(true)

      user.unlock_access!
      expect(user.reload.unlock_token).to be_nil
      expect(user.access_locked?).to be(false)
    end

    it "mints the token when register_failed_attempt! trips the lock, and keeps it while locked" do
      user.register_failed_attempt!
      expect(user.unlock_token).to be_nil
      user.register_failed_attempt!
      token = user.reload.unlock_token
      expect(token).to be_present
      user.register_failed_attempt! # locked: no counting, no re-mint
      expect(user.reload.unlock_token).to eq(token)
    end

    it "unlock_by_token unlocks exactly once (hooks fire, record returned) and refuses wrong or blank tokens" do
      user.lock_access!
      token = user.unlock_token
      expect(klass.unlock_by_token("wrong")).to be_nil
      expect(klass.unlock_by_token(nil)).to be_nil
      expect(klass.unlock_by_token("")).to be_nil
      expect(user.reload.access_locked?).to be(true)

      unlocked = klass.unlock_by_token(token)
      expect(unlocked).to eq(user)
      expect(unlocked.access_locked?).to be(false)
      expect(unlocked.unlock_token).to be_nil
      expect(unlocked.failed_attempts).to eq(0)
      expect(unlocked.events).to eq([:after_unlock])
      expect(klass.unlock_by_token(token)).to be_nil # single use
    end

    it "lets only one of two concurrent clicks on the same link win" do
      user.lock_access!
      token = user.unlock_token

      # The loser is the request that read the row BEFORE the winner wrote it:
      # it still holds the token in memory, so only the conditional UPDATE can
      # stop it. Replaying the claim with that stale row is what a second
      # in-flight request does, and it must neither unlock nor fire a second
      # after_unlock. (Two plain unlock_by_token calls would not reach here —
      # the second one's find_by returns nothing at all.)
      stale = klass.find(user.id)
      expect(stale.unlock_token).to eq(token)

      expect(klass.unlock_by_token(token)).to eq(user)
      expect(klass.send(:unlock_by_claimed_token, stale, :unlock_token, token)).to be_nil
      expect(stale.events).to be_nil
      expect(user.reload.access_locked?).to be(false)
      expect(user.reload.unlock_token).to be_nil
    end

    # Two requests loaded the row before either failed. The first crosses the
    # threshold and locks (the token is mailed from after_lock); the second,
    # still holding the unlocked row, crosses it too. Its lock_access! used to
    # write a fresh token over the mailed one — killing the link — and fire
    # after_lock again. The lock is now one conditional UPDATE, so the loser
    # only adopts the lock that is already there.
    it "a stale instance crossing the threshold concurrently keeps the mailed token and fires no hooks" do
      locker = Class.new(TestModel) do
        self.table_name = "token_lock_users"
        include ConcernsOnRails::Lockable

        lockable_by max_attempts: 2, unlock_in: 1.hour, unlock_token: :unlock_token

        attr_accessor :events

        def before_lock = (self.events ||= []) << :before_lock
        def after_lock = (self.events ||= []) << :after_lock
      end
      id = locker.create!(email: "race@x.com", failed_attempts: 1).id
      first = locker.find(id)
      second = locker.find(id)

      first.register_failed_attempt!
      mailed = locker.find(id).unlock_token
      locked_at = locker.find(id).locked_at
      expect(mailed).to be_present
      expect(first.events).to eq(%i[before_lock after_lock])

      expect(second.register_failed_attempt!).to eq(3)
      expect(second.events).to be_nil
      expect(second.access_locked?).to be(true)
      expect(second.unlock_token).to eq(mailed) # adopted the winner's lock, in memory too
      expect(second.changed?).to be(false)

      row = locker.find(id)
      expect(row.unlock_token).to eq(mailed)
      expect(row.locked_at).to eq(locked_at)
      expect(locker.unlock_by_token(mailed)).to eq(row)
    end

    it "lock_access! on a stale instance adopts the existing lock instead of re-minting" do
      stale = klass.find(user.id)
      user.lock_access!
      token = user.unlock_token

      expect(stale.lock_access!).to be(true)
      expect(stale.unlock_token).to eq(token)
      expect(klass.find(user.id).unlock_token).to eq(token)
    end

    it "lock_access! still re-locks (fresh token) over a lapsed lock a stale instance saw as live" do
      user.lock_access!
      old_token = user.unlock_token
      travel_to(2.hours.from_now) do
        expect(user.lock_access!).to be(true)
        expect(user.unlock_token).not_to eq(old_token)
        expect(klass.find(user.id).locked_at).to be_within(1.second).of(Time.zone.now)
      end
    end

    it "puts the token back when a hook vetoes the unlock, so the link is not burned" do
      vetoing = Class.new(TestModel) do
        self.table_name = "token_lock_users"
        include ConcernsOnRails::Lockable

        lockable_by max_attempts: 2, unlock_token: :unlock_token

        cattr_accessor :veto
        self.veto = true

        def before_unlock
          raise ActiveRecord::Rollback if self.class.veto
        end
      end
      record = vetoing.create!(email: "veto@x.com")
      record.lock_access!
      token = record.unlock_token

      expect(vetoing.unlock_by_token(token)).to be_nil
      expect(record.reload.unlock_token).to eq(token) # still mailable
      expect(record.access_locked?).to be(true)

      vetoing.veto = false
      expect(vetoing.unlock_by_token(token)).to eq(record)
      expect(record.reload.access_locked?).to be(false)
    end

    it "refuses (and retires) a token once the lock has lapsed on its own" do
      user.lock_access!
      token = user.unlock_token
      travel_to(20.minutes.from_now) do
        expect(user.reload.access_locked?).to be(false)
        # The account is already usable: the link is not a live credential any
        # more, and the dangling token must not sit in the row forever.
        expect(klass.unlock_by_token(token)).to be_nil
      end
      expect(user.reload.unlock_token).to be_nil
      expect(user.events).to be_nil # no unlock hooks for a refused link
    end

    it "does not reach a row the model's default scope hides" do
      scoped = Class.new(TestModel) do
        self.table_name = "token_lock_users"
        include ConcernsOnRails::Lockable

        lockable_by max_attempts: 2, unlock_token: :unlock_token
        default_scope { where(email: "visible@x.com") }
      end
      hidden = scoped.unscoped.create!(email: "hidden@x.com")
      hidden.lock_access!

      expect(scoped.unlock_by_token(hidden.unlock_token)).to be_nil
      expect(hidden.reload.access_locked?).to be(true)
    end

    it "registers the token column with the filter-parameter registry" do
      klass # the macro runs at class-definition time
      expect(ConcernsOnRails.filter_parameter_registry.include?("user[unlock_token]")).to be(true)
    end

    it "unlock_expired clears tokens along with the lock" do
      user.lock_access!
      travel_to(20.minutes.from_now) { expect(klass.unlock_expired).to eq(1) }
      expect(user.reload.unlock_token).to be_nil
    end

    it "a failed attempt after the lock lapsed drops the stale token quietly" do
      user.lock_access!
      travel_to(20.minutes.from_now) do
        user.register_failed_attempt!
        expect(user.reload.unlock_token).to be_nil
        expect(user.events).to be_nil # no unlock hooks from a failed login
      end
    end

    it "exposes the configured column and raises a clear error when unlock_by_token is used without it" do
      expect(klass.lockable_unlock_token_field).to eq(:unlock_token)
      expect(LockUser.lockable_unlock_token_field).to be_nil
      expect { LockUser.unlock_by_token("x") }.to raise_error(ArgumentError, /unlock_token: is not configured/)
    end

    it "requires the column (typed hint) and a column distinct from the other two" do
      expect do
        Class.new(TestModel) do
          self.table_name = "lock_users"
          include ConcernsOnRails::Lockable

          lockable_by unlock_token: :unlock_token
        end
      end.to raise_error(ArgumentError, /unlock_token.*does not exist.*unlock_token:string:uniq/)

      expect do
        Class.new(TestModel) do
          self.table_name = "token_lock_users"
          include ConcernsOnRails::Lockable

          lockable_by unlock_token: :locked_at
        end
      end.to raise_error(ArgumentError, /unlock_token must be a different column/)
    end

    it "reports all three missing columns in ONE migration command" do
      expect do
        Class.new(TestModel) do
          self.table_name = "naked_lock_users"
          include ConcernsOnRails::Lockable

          lockable_by unlock_token: :unlock_token
        end
      end.to raise_error(
        ArgumentError,
        /AddLockableColumnsToNakedLockUsers failed_attempts:integer locked_at:datetime unlock_token:string:uniq/
      )
    end
  end

  describe "unreachable schema (1.29 audit)" do
    # db:create / a fresh db:migrate / assets:precompile: the table is not
    # there yet, and the model must still load.
    it "loads on a table that has not been migrated yet" do
      expect do
        Class.new(TestModel) do
          self.table_name = "lockable_not_migrated_yet"
          include ConcernsOnRails::Models::Lockable

          lockable_by max_attempts: 3
        end
      end.not_to raise_error
    end

    it "loads when the connection itself is unavailable" do
      klass = Class.new(TestModel) do
        self.table_name = "users"
        include ConcernsOnRails::Models::Lockable
      end
      allow(klass).to receive(:table_exists?).and_raise(ActiveRecord::ConnectionNotEstablished)
      allow(klass).to receive(:columns_hash).and_raise(ActiveRecord::ConnectionNotEstablished)

      expect { klass.lockable_by(max_attempts: 3) }.not_to raise_error
    end
  end
end
