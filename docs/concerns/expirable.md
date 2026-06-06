`Expirable` gives any ActiveRecord model a single-timestamp expiry lifecycle. Include it in models whose records have a natural end-of-life — API tokens, password-reset links, invitation codes, sessions — and get predicate methods, time-aware scopes, and mutators with no boilerplate. The concern reads and writes one `datetime` column whose name is configurable; a `nil` value is treated as "never expires."

## When to use it

- API tokens or OAuth access tokens that expire after a fixed TTL.
- Password-reset and email-verification links that must expire after a short window.
- Invitation codes that are valid for a limited period.
- Trial licences or feature flags that expire on a known date.
- Temporary session records or magic-link login tokens.

## Installation

```ruby
class ApiToken < ApplicationRecord
  include ConcernsOnRails::Expirable

  expirable_by   # uses :expires_at by default
end
```

The fully-qualified form `ConcernsOnRails::Models::Expirable` is equivalent and can be used when you need explicit namespacing.

To use a different column name, pass the field symbol to the macro:

```ruby
class License < ApplicationRecord
  include ConcernsOnRails::Expirable

  expirable_by :valid_until
end
```

## Database columns

| Column | Type | Required | Notes |
|---|---|---|---|
| `expires_at` | `datetime` | Yes (default name) | Stores the expiry timestamp. `nil` means the record never expires. A custom name is configured via `expirable_by`. |

Rails migration:

```ruby
class AddExpiresAtToApiTokens < ActiveRecord::Migration[7.1]
  def change
    add_column :api_tokens, :expires_at, :datetime
  end
end
```

For a custom field name, replace `:expires_at` with your chosen column name and pass that name to `expirable_by`.

## Configuration

The `expirable_by` macro configures the expiry column and validates that it exists in the schema at class-load time.

```ruby
expirable_by             # uses the default column :expires_at
expirable_by :valid_until
```

| Option | Type | Default | Description |
|---|---|---|---|
| `field` | `Symbol` | `:expires_at` | The `datetime` column that stores the expiry timestamp. Passed as a positional argument. Must already exist in the database schema or `ArgumentError` is raised. |

The macro can be called more than once on the same class. Each call overwrites `expirable_field` and re-validates the column, allowing subclasses or re-open class blocks to switch the active column.

## Scopes

All three scopes are defined at include time and delegate time comparison to `Time.zone.now`, so they respect the application's configured time zone.

| Scope | Description |
|---|---|
| `.active` | Records whose expiry column is `NULL` (never expires) **or** greater than the current time. |
| `.expired` | Records whose expiry column is less than or equal to the current time. Excludes `NULL` rows. |
| `.expiring_within(duration)` | Records whose expiry is in the future **and** falls within `now + duration`. Excludes already-expired and never-expiring records. |

```ruby
ApiToken.active                    # nil expiry OR expires_at > now
ApiToken.expired                   # expires_at <= now (excludes nil)
ApiToken.expiring_within(1.hour)   # expires_at in (now, now + 1.hour]
```

## Methods

### Instance methods

| Signature | Description |
|---|---|
| `expired?` | Returns `true` when the expiry column is set and its value is less than or equal to `Time.zone.now`. Returns `false` when the column is `nil`. |
| `active?` | Inverse of `expired?`. Returns `true` when not expired (including records with no expiry set). |
| `expire!(time = Time.zone.now)` | Persists an expiry timestamp via `update`. Defaults to the current time, making the record immediately expired. Accepts any `Time`-compatible value. |
| `extend_expiry!(by:)` | Pushes the expiry forward by a duration. The base for the calculation is smart: if the record is never-expiring or already expired, `now` is used as the base; if the record has a future expiry, the existing value is used as the base. |
| `time_until_expiry` | Returns an `ActiveSupport::Duration` representing seconds until expiry, `nil` if there is no expiry set, or `0.seconds` if the record is already expired. |

### Class methods

| Signature | Description |
|---|---|
| `expirable_by(field = :expires_at)` | Configuration macro. Sets `expirable_field` and validates column existence. Raises `ArgumentError` if the column is missing. |

## Examples

**Basic API token with default field**

```ruby
class ApiToken < ApplicationRecord
  include ConcernsOnRails::Expirable

  expirable_by
end

# Create a token valid for one hour
token = ApiToken.create!(value: SecureRandom.hex, expires_at: 1.hour.from_now)

token.active?           # => true
token.expired?          # => false
token.time_until_expiry # => ActiveSupport::Duration (~3600 seconds)

# Immediately expire the token
token.expire!
token.expired?          # => true

# Query
ApiToken.active                  # tokens that are nil or future-expiring
ApiToken.expired                 # tokens past their expiry
ApiToken.expiring_within(1.day)  # tokens expiring in the next 24 hours
```

**Custom field name for a licence model**

```ruby
class License < ApplicationRecord
  include ConcernsOnRails::Expirable

  expirable_by :valid_until
end

lic = License.create!(key: "PRO-123", valid_until: 30.days.from_now)
lic.active?   # => true

# Extend a trial by 14 more days (adds to the existing future expiry)
lic.extend_expiry!(by: 14.days)
```

**Extending an already-expired record**

```ruby
old_invite = Invitation.create!(token: "abc", expires_at: 1.day.ago)
old_invite.expired?  # => true

# Base resets to now because the record is already expired
old_invite.extend_expiry!(by: 7.days)
old_invite.expires_at  # => ~7 days from now
old_invite.active?     # => true
```

## Notes & gotchas

- **Boundary is exclusive for the expiring record.** A record whose `expires_at` equals `Time.zone.now` exactly is considered expired (`expired?` returns `true`, `active?` returns `false`). The same boundary applies to the `.expired` scope (`<= now`) and `.active` scope (`> now`).
- **`nil` means never-expires, not immediately-expired.** `expired?` returns `false` and `active?` returns `true` when the column is `nil`. The `.active` scope includes `NULL` rows; the `.expired` scope excludes them.
- **`expirable_by` must be called before the model is used.** The macro writes the `expirable_field` class attribute and validates the column. If you skip the call, the three scopes are still defined (they were added by `included do`) but they will read from the default `expirable_field` value of `:expires_at`, which may not match your actual column.
- **`ArgumentError` on missing column.** `expirable_by` calls `ensure_columns!` from `ConcernsOnRails::Support::ColumnGuard`. If the configured column does not exist in the schema at class-load time, it raises `ArgumentError` with a message matching `/does not exist/`. This fires at boot, not at query time, so misconfiguration is caught early.
- **`expiring_within` excludes already-expired and never-expiring records.** The scope uses `column.gt(now)` as its lower bound, so past records and `NULL` rows are always excluded regardless of the duration argument.
- **`extend_expiry!` base selection.** The private `expiry_extension_base` method selects `now` when the value is `nil` or `<= now`; otherwise it uses the stored future value. This means a never-expiring record re-anchors to `now + by` rather than to `nil + by`.
- **`time_until_expiry` return types.** The method returns three distinct types: `nil` (no expiry), `0.seconds` (`ActiveSupport::Duration`) when already expired, or a computed `ActiveSupport::Duration` when expiry is in the future. Callers should handle the `nil` case explicitly.
- **`expire!` and `extend_expiry!` call `update`.** Both methods persist immediately via `update` (not `update_column`), so Active Record callbacks, validations, and `updated_at` timestamping all fire normally.
- **Relationship to `Schedulable`.** `Schedulable` with `starts_at: nil, ends_at: :expires_at` produces similar query behavior. Prefer `Expirable` when your domain only needs an end time; use `Schedulable` when you also need a start time.
- **No `default_scope` is applied.** Unlike `SoftDeletable`, `Expirable` does not add a `default_scope`. Expired records appear in ordinary queries; callers must chain `.active` or `.expired` explicitly when filtering is required.
