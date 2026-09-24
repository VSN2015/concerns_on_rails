`Activatable` adds a boolean active/inactive toggle to any ActiveRecord model backed by a single database column. It eliminates repetitive hand-written scopes and state-flip methods that almost every application reimplements, and enforces a consistent convention: `NULL` in the backing column is treated as inactive, matching the "unset means off" expectation of most production applications.

## When to use it

- A `Subscription` or `Plan` model needs to be suspended and reinstated without deletion.
- A `Feature` or `FeatureFlag` model powers a simple enable/disable toggle for functionality.
- An `ApiKey` or `Integration` model must be deactivated and reactivated independently of revocation or soft-deletion.
- A `User` or `Account` model requires an administrative activation gate separate from email verification or soft-deletion state.
- Any model whose "enabled" or "live" state is stored as a plain boolean column and queried frequently by scope.

## Installation

Include the concern and call the `activatable_by` macro once inside the model class. The alias `ConcernsOnRails::Models::Activatable` is also valid and resolves to the same module.

```ruby
class Subscription < ApplicationRecord
  include ConcernsOnRails::Activatable

  activatable_by          # uses the :active column by default
end
```

Custom column name:

```ruby
class Widget < ApplicationRecord
  include ConcernsOnRails::Activatable

  activatable_by :enabled
end
```

## Database columns

| Column | Type | Required | Notes |
|--------|------|----------|-------|
| `active` (or custom) | `boolean` | Yes | The default column name is `active`. Pass a different symbol to `activatable_by` to use any other boolean column. |
| `activated_at` (or custom) | `datetime` | Only with `timestamps:` | Stamped on every activation. Required when `timestamps: true`; `timestamps: { activated_at: :enabled_at }` renames it, `{ activated_at: nil }` drops that side. |
| `deactivated_at` (or custom) | `datetime` | Only with `timestamps:` | Stamped on every deactivation, under the same renaming/dropping rules. |

Migration for the default column:

```ruby
class AddActiveToSubscriptions < ActiveRecord::Migration[7.1]
  def change
    add_column :subscriptions, :active, :boolean
  end
end
```

Migration for a custom column name:

```ruby
class AddEnabledToWidgets < ActiveRecord::Migration[7.1]
  def change
    add_column :widgets, :enabled, :boolean
  end
end
```

Migration for the stamp columns (only needed when you pass `timestamps:`):

```ruby
class AddActivationTimestampsToSubscriptions < ActiveRecord::Migration[7.1]
  def change
    add_column :subscriptions, :activated_at, :datetime
    add_column :subscriptions, :deactivated_at, :datetime
  end
end
```

## Configuration

### `activatable_by(field = :active, prefix: nil, suffix: nil, timestamps: false)`

Called once at the class level. Registers the backing column, validates its existence, and defines the `.active` and `.inactive` scopes.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `field` | Symbol | `:active` | The name of the boolean column that stores the active/inactive state. Must already exist in the database when the macro is evaluated; raises `ArgumentError` otherwise. |
| `prefix:` / `suffix:` | Symbol / `true` | `nil` | Affix the `.active` / `.inactive` scope names so they don't collide with a sibling concern's. |
| `timestamps:` | `true`, `false` or `Hash` | `false` | `true` stamps `activated_at` when a record is activated and `deactivated_at` when it is deactivated (`activate!`, `deactivate!`, `toggle_active!`, `activate_all`, `deactivate_all`). A Hash renames either column (`{ activated_at: :enabled_at }`) or drops a side (`deactivated_at: nil`); unknown keys raise. The stamp columns must already exist: `activatable_by` checks that at declaration and raises `ArgumentError` otherwise; the declared `datetime` type is not enforced, it only types the `bin/rails generate migration` hint in that error. The other column keeps its previous value, so the last activation and the last deactivation are both visible. |

Besides the positional `field`, the macro takes the `prefix:`, `suffix:` and `timestamps:` keywords documented in the table above.

## Scopes

Both scopes are defined by `activatable_by` and are therefore only available after the macro is called.

| Scope | Description |
|-------|-------------|
| `.active` | Returns records where the configured column is `TRUE`. |
| `.inactive` | Returns records where the configured column is `FALSE` **or** `NULL`. |

```ruby
Subscription.active    # WHERE active = TRUE
Subscription.inactive  # WHERE active = FALSE OR active IS NULL
```

## Methods

### Instance methods

| Signature | Description |
|-----------|-------------|
| `active?` | Returns `true` if the backing column equals `true`; `false` for `false` or `nil`. |
| `inactive?` | Returns `!active?`. |
| `activate!` | Runs `before_activate`, persists `true` (and the `activated_at` stamp when configured) via `update`, then `after_activate`, all in their own savepoint. Returns `true` only once the after-hook has returned. A validation failure returns `false`, skips the after-hook and rolls back the before-hook's side effects. A raising after-hook rolls the write back, and so does one calling `raise ActiveRecord::Rollback`, which makes the verb return `false` (even inside a caller's transaction; `activate_all` then raises `ActiveRecord::RecordNotSaved`). |
| `deactivate!` | The mirror image: `before_deactivate`, `false` (+ `deactivated_at`), `after_deactivate`. |
| `before_activate` / `after_activate` / `before_deactivate` / `after_deactivate` | No-op override points. Gating is per direction: overriding a direction's bang method or either of its two hooks moves **that** verb to the per-record path, so the hooks run for every record. Overriding `after_deactivate` leaves `activate_all` on the single-`UPDATE` fast path. |
| `toggle_active!` | Calls `deactivate!` if the flag is currently on, `activate!` otherwise. A `NULL` column is treated as inactive, so toggling it sets the column to `true`. It reads the column itself, not `active?`, so it flips the right way even when another concern owns `active?`. |
| `<affix>active?` / `<affix>inactive?` | Defined when `prefix:`/`suffix:` is configured (`flag_active?`, `active_flag?`, …). They always give Activatable's answer, whichever concern owns the plain names. The macro raises `ArgumentError` if one would shadow a different column's query method. When the affixed name is the flag column itself (`activatable_by :account_active, prefix: :account`), the column's own `account_active?` is kept. |

### Class methods

| Signature | Description |
|-----------|-------------|
| `activatable_by(field = :active, prefix: nil, suffix: nil, timestamps: false)` | Configuration macro. Validates that the boolean column and any configured stamp columns exist, stores them in the `activatable_field` / `activatable_timestamps` class attributes, and defines the `.active` / `.inactive` scopes (affixed by `prefix:` / `suffix:`). |

## Examples

**Basic lifecycle on the default column:**

```ruby
class Subscription < ApplicationRecord
  include ConcernsOnRails::Activatable
  activatable_by
end

sub = Subscription.create!(name: "Pro", active: false)
sub.active?       # => false
sub.inactive?     # => true

sub.activate!
sub.reload.active # => true

sub.toggle_active!
sub.reload.active # => false

Subscription.active.count   # => 0
Subscription.inactive.count # => 1
```

**Custom column name:**

```ruby
class FeatureFlag < ApplicationRecord
  include ConcernsOnRails::Activatable
  activatable_by :enabled
end

flag = FeatureFlag.create!(name: "dark_mode", enabled: true)
flag.active?   # => true
flag.deactivate!
flag.inactive? # => true

FeatureFlag.active   # WHERE enabled = TRUE
FeatureFlag.inactive # WHERE enabled = FALSE OR enabled IS NULL
```

**NULL column toggled to active:**

```ruby
sub = Subscription.create!(name: "Trial")  # active column is NULL
sub.active?   # => false  (NULL treated as inactive)
sub.toggle_active!
sub.reload.active # => true
```

**Hooks and timestamps**

```ruby
class Subscription < ApplicationRecord
  include ConcernsOnRails::Activatable

  activatable_by timestamps: true

  def after_activate   = Billing.resume!(self)
  def after_deactivate = Billing.pause!(self)
end

sub = Subscription.create!(active: false)
sub.activate!          # before_activate → UPDATE active = true, activated_at = now → after_activate
sub.activated_at       # => 2026-09-05 10:00:00 UTC
sub.deactivate!        # deactivated_at = now; activated_at keeps 10:00 (last activation)
Subscription.inactive.activate_all   # hooks overridden → per record, so Billing.resume! runs for each
```

## Notes & gotchas

- **`NULL` is inactive.** The `.inactive` scope matches both `FALSE` and `NULL`. `active?` returns `false` for `nil`. This means a freshly created record with no value in the boolean column is considered inactive even though no explicit `false` was written.
- **`toggle_active!` on a `NULL` column activates.** Because `NULL` is treated as inactive, calling `toggle_active!` on a record whose column is `NULL` will set it to `true`, not `false`.
- **`activate!` and `deactivate!` call `update`.** They go through ActiveRecord validations and callbacks. If the record is invalid for an unrelated reason, the update will fail and return `false`.
- **Scopes are defined lazily by the macro.** Calling `Subscription.active` before `activatable_by` has been evaluated raises `NoMethodError`. Always call the macro at class load time, not inside a callback or method body.
- **Column must exist at macro evaluation time.** `activatable_by` calls `ensure_columns!` immediately. If the migration has not been run yet, loading the model will raise `ArgumentError: ConcernsOnRails::Models::Activatable: 'active' does not exist in the database (table: subscriptions). Add it with: bin/rails generate migration AddActiveToSubscriptions active:boolean` — the error carries the exact migration command to run.
- **Name conflicts with `SoftDeletable` and `Expirable`.** Both also define a `.active` scope, and `Expirable` also defines `active?`. Pass `prefix:`/`suffix:` (`activatable_by :active, prefix: :flag`). This renames the scopes to `.flag_active` / `.flag_inactive` and defines `flag_active?` / `flag_inactive?`. The plain `active?` / `inactive?` stay for compatibility and belong to the concern included last.
- **`activatable_field` is a `class_attribute`.** It is inheritable by subclasses and is not accessible from instances (`instance_accessor: false`). Subclasses can call `activatable_by` again to override the field independently.
