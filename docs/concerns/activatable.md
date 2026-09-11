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

## Configuration

### `activatable_by(field = :active, prefix: nil, suffix: nil, timestamps: false)`

Called once at the class level. Registers the backing column, validates its existence, and defines the `.active` and `.inactive` scopes.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `field` | Symbol | `:active` | The name of the boolean column that stores the active/inactive state. Must already exist in the database when the macro is evaluated; raises `ArgumentError` otherwise. |
| `prefix:` / `suffix:` | Symbol / `true` | `nil` | Affix the `.active` / `.inactive` scope names so they don't collide with a sibling concern's. |
| `timestamps:` | `true`, `false` or `Hash` | `false` | `true` stamps `activated_at` when a record is activated and `deactivated_at` when it is deactivated (`activate!`, `deactivate!`, `toggle_active!`, `activate_all`, `deactivate_all`). A Hash renames either column (`{ activated_at: :enabled_at }`) or drops a side (`deactivated_at: nil`); unknown keys raise. Columns must exist as `datetime` (validated at declaration). The other column keeps its previous value, so the last activation and the last deactivation are both visible. |

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
| `activate!` | Runs `before_activate`, persists `true` (and the `activated_at` stamp when configured) via `update`, then `after_activate` — all in one transaction. Returns the result of `update`; a `false` (validation failure) skips the after-hook, a raising after-hook rolls the write back. |
| `deactivate!` | The mirror image: `before_deactivate`, `false` (+ `deactivated_at`), `after_deactivate`. |
| `before_activate` / `after_activate` / `before_deactivate` / `after_deactivate` | No-op override points. Gating is per direction: overriding a direction's bang method or either of its two hooks moves **that** verb to the per-record path, so the hooks run for every record. Overriding `after_deactivate` leaves `activate_all` on the single-`UPDATE` fast path. |
| `toggle_active!` | Calls `deactivate!` if currently active, `activate!` otherwise. A `NULL` column is treated as inactive, so toggling it sets the column to `true`. |

### Class methods

| Signature | Description |
|-----------|-------------|
| `activatable_by(field = :active)` | Configuration macro. Validates the column, stores it in the `activatable_field` class attribute, and defines the `.active` / `.inactive` scopes. |

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
- **Scope conflict with `SoftDeletable`.** `SoftDeletable` also defines a `.active` scope (as an alias for `.without_deleted`). When both concerns are included on the same model, the later `include` wins. To get `Activatable`'s `.active` semantics, include `ConcernsOnRails::Activatable` after `ConcernsOnRails::SoftDeletable`, or avoid including both on the same model.
- **`activatable_field` is a `class_attribute`.** It is inheritable by subclasses and is not accessible from instances (`instance_accessor: false`). Subclasses can call `activatable_by` again to override the field independently.
