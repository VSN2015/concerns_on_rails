The `Lockable` concern adds failed-attempt tracking and account lockout ("Devise lockable-lite") to any ActiveRecord model. It is built for apps that roll their own authentication — the Rails 8 auth generator and `has_secure_password` ship **no brute-force protection at all** — and needs only two columns on the model's own table: an integer counter and a lock timestamp. No tokens, no mailers, no extra tables.

## When to use it

- You generated authentication with Rails 8 (or hand-rolled `has_secure_password`) and need login throttling per account.
- An admin UI needs "this account is locked, N attempts remaining, unlocks at ..." surfaces.
- API key or PIN verification endpoints where repeated failures should freeze the credential.
- Any model with a guessable secret (login, OTP, access code) that should stop accepting guesses after N failures.
- You want lockout semantics without adopting all of Devise.

## Installation

Add the concern to your model and call the configuration macro. The fully-qualified alias `ConcernsOnRails::Models::Lockable` resolves to the same module.

```ruby
class User < ApplicationRecord
  include ConcernsOnRails::Lockable

  # Minimal — 5 failures lock the account until unlock_access! is called
  lockable_by

  # Typical — auto-unlock after a cool-down window
  # lockable_by max_attempts: 5, unlock_in: 15.minutes

  # Custom columns + affixed scope names
  # lockable_by attempts: :failed_logins, locked_at: :locked_until_at,
  #             prefix: :account            # => .account_locked / .account_unlocked
end
```

## Database columns

| Column | Type | Required | Notes |
|--------|------|----------|-------|
| `failed_attempts` (or your `attempts:` column) | `integer` | Yes | A `default: 0` is nice but **not required** — the increment NULL-coalesces. Must be an integer column (validated at class-load time). |
| `locked_at` (or your `locked_at:` column) | `datetime` | Yes | `NULL` = not locked. |

```ruby
class AddLockableToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :failed_attempts, :integer, default: 0, null: false
    add_column :users, :locked_at, :datetime
  end
end
```

## Configuration

### `lockable_by(attempts: :failed_attempts, locked_at: :locked_at, max_attempts: 5, unlock_in: nil, prefix: nil, suffix: nil)`

Both columns must exist (and `attempts:` must be an integer column) or the macro raises `ArgumentError` at class-load time. Calling the macro again reconfigures (last call wins).

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `attempts:` | `Symbol` | `:failed_attempts` | Integer counter column. |
| `locked_at:` | `Symbol` | `:locked_at` | Datetime lock column. Must differ from `attempts:`. |
| `max_attempts:` | positive `Integer` or `nil` | `5` | The failure count that triggers the lock (reached **exactly**: the 5th failure locks). `nil` = count failures but never auto-lock. |
| `unlock_in:` | positive duration or `nil` | `nil` | `nil` = locked until `unlock_access!`. With a duration (e.g. `15.minutes`) the lock lapses by itself; the expiry instant counts as unlocked. |
| `prefix:` / `suffix:` | `Symbol`/`String` | `nil` | Affix the `.locked` / `.unlocked` scope names to avoid collisions. |

## Methods

### Writers (all raise `ArgumentError` on unsaved records)

| Signature | Description |
|-----------|-------------|
| `register_failed_attempt! → Integer` | Records one failure with an **atomic SQL increment** (`COALESCE(attempts, 0) + 1` via `update_counters` — concurrent failures never lose updates) and auto-locks at the threshold. Returns the fresh count. A locked account stops counting; an expired lock is quietly cleared first and the failure counts as attempt 1. |
| `lock_access! → true` | Locks now via `update_columns` (validations/callbacks bypassed). Idempotent while locked; an expired lock is re-locked with a fresh timestamp. Runs `before_lock`/`after_lock` in a transaction. |
| `unlock_access! → true` | Clears the lock **and** zeroes the counter in one write. Runs `before_unlock`/`after_unlock` in a transaction. No-op when not locked. |
| `reset_failed_attempts! → true` | Zeroes the counter only — call on **successful login**. No hooks, lock untouched, skips the write when already zero. |

### Readers (side-effect free)

| Signature | Description |
|-----------|-------------|
| `access_locked? → Boolean` | Locked right now. Lazy expiry: a stale lock reads as unlocked but the column is never cleared by a reader. |
| `lock_expired? → Boolean` | Was locked and the `unlock_in` window has fully elapsed. Always `false` when `unlock_in` is `nil`. |
| `lock_expires_at → Time \| nil` | `locked_at + unlock_in`; `nil` when not locked or manual-unlock-only. |
| `attempts_remaining → Integer \| nil` | Failures left before auto-lock (never negative); `nil` when `max_attempts: nil`. |

### Scopes

`.locked` / `.unlocked` (names affixable via `prefix:`/`suffix:`) — expiry-aware: with `unlock_in:`, a lapsed lock automatically moves to `.unlocked`, agreeing with `access_locked?` at the exact boundary.

### Hooks

Override `before_lock` / `after_lock` / `before_unlock` / `after_unlock` as plain methods. They fire for manual `lock_access!`/`unlock_access!` **and** the auto-lock inside `register_failed_attempt!`; a raising hook rolls the write back. `after_lock` is the place for the "your account has been locked" email.

## Examples

**A `SessionsController` on Rails 8 native auth:**

```ruby
def create
  user = User.find_by(email: params[:email])

  if user.nil?
    render_invalid_credentials
  elsif user.access_locked?
    render json: { error: "Account locked. Try again at #{user.lock_expires_at&.iso8601 || 'a later time'}." },
           status: :locked   # 423
  elsif user.authenticate(params[:password])
    user.reset_failed_attempts!
    start_new_session_for(user)
  else
    user.register_failed_attempt!
    render_invalid_credentials(remaining: user.attempts_remaining)
  end
end
```

**Lockout email:**

```ruby
class User < ApplicationRecord
  include ConcernsOnRails::Lockable
  lockable_by max_attempts: 5, unlock_in: 30.minutes

  def after_lock
    SecurityMailer.account_locked(self).deliver_later
  end
end
```

**Admin dashboard:**

```ruby
User.locked.count                 # currently locked accounts
user.unlock_access!               # support-desk manual unlock (also resets the counter)
```

## Notes & gotchas

- **Don't reveal lock state to unauthenticated callers** unless that is an accepted trade-off — a "locked" response confirms the account exists. Many apps return the same generic 401 either way and only surface lock state in account-recovery flows.
- **`update_columns` semantics.** Locking/unlocking bypasses validations and AR callbacks on purpose (an otherwise-invalid record must still be lockable). That also skips `updated_at`, and a coexisting `Auditable` will not record the change.
- **Lazy expiry.** Readers and scopes never write. A lapsed lock's column is cleared by the next `unlock_access!` or `register_failed_attempt!` (quietly there — no unlock hooks fire from a failed login, so "account unlocked" notifications can't be triggered by an attacker's guess).
- **Race window at the threshold.** Two truly simultaneous threshold-crossing failures both count (the increment is SQL-side), but each may fire `after_lock` once — same property as Devise. Make the hook idempotent (e.g. `deliver_later` with a dedup key) if that matters.
- **`reset_failed_attempts!` doesn't unlock.** Successful authentication while locked shouldn't happen (check `access_locked?` first), and unlocking is a deliberate act — use `unlock_access!`.
- **Counting only:** `max_attempts: nil` turns the concern into a failure counter (`attempts_remaining` returns `nil`), with locking strictly manual.
- **Non-goals**: unlock tokens, unlock emails, IP-based throttling (pair with the `Throttleable` controller concern for that). Reach for [Devise's `lockable`](https://github.com/heartcombo/devise) when you need the full strategy surface.
