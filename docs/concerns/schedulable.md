`Schedulable` models time-windowed records by tracking an optional start timestamp and an optional end timestamp. It solves the common Rails problem of querying "what is active right now?" for records like promotions, events, or feature flags — without requiring custom scope logic in every model. The concern adds four scopes and seven instance methods that all derive from the same two configurable column names.

## When to use it

- A `Promotion` model has a `starts_at` and `ends_at` that define when the discount is visible to customers.
- An `Event` model uses `starts_on` / `ends_on` columns to track conference sessions or meetup windows.
- A `FeatureFlag` model needs a simple `starts_at` with no fixed end date (runs until manually disabled).
- A `Coupon` model needs only an expiry column (`expires_at`) and should be considered active until that moment arrives, with no start gate.
- A content-scheduling system needs to query records that were active at an arbitrary past time for auditing.

## Installation

```ruby
class Promotion < ApplicationRecord
  include ConcernsOnRails::Schedulable

  schedulable_by # uses :starts_at and :ends_at by default
end
```

The fully-qualified form `ConcernsOnRails::Models::Schedulable` is equivalent; the top-level alias `ConcernsOnRails::Schedulable` is the conventional short form.

## Database columns

| Column | Type | Required | Notes |
|---|---|---|---|
| `starts_at` | `datetime` | Conditional | Required unless `starts_at: nil` is passed to `schedulable_by` |
| `ends_at` | `datetime` | Conditional | Required unless `ends_at: nil` is passed to `schedulable_by` |

Column names are configurable. At least one of the two must be present. The migration below covers the default names:

```ruby
class AddSchedulableToPromotions < ActiveRecord::Migration[7.1]
  def change
    add_column :promotions, :starts_at, :datetime
    add_column :promotions, :ends_at,   :datetime
  end
end
```

For custom column names (e.g. `starts_on` / `ends_on`):

```ruby
class AddSchedulableToEvents < ActiveRecord::Migration[7.1]
  def change
    add_column :events, :starts_on, :datetime
    add_column :events, :ends_on,   :datetime
  end
end
```

## Configuration

Call `schedulable_by` inside the model class body after including the concern.

```ruby
schedulable_by                                          # defaults
schedulable_by starts_at: :starts_on, ends_at: :ends_on # custom names
schedulable_by starts_at: nil, ends_at: :expires_at    # no start gate
```

| Option | Type | Default | Description |
|---|---|---|---|
| `starts_at:` | `Symbol` or `nil` | `:starts_at` | The datetime column that marks the beginning of the active window. Pass `nil` to omit the start gate — records are considered started at all times. |
| `ends_at:` | `Symbol` or `nil` | `:ends_at` | The datetime column that marks the end of the active window. Pass `nil` for open-ended records that never expire. |

Passing `nil` for both options simultaneously raises `ArgumentError`. Passing a column name that does not exist in the table also raises `ArgumentError` (raised by `ConcernsOnRails::Support::ColumnGuard`).

`schedulable_by` can be called more than once on the same model to reconfigure it; the class attributes `schedulable_starts_at_field` and `schedulable_ends_at_field` are overwritten each time.

## Scopes

All scopes are added in the `included` block, so they are available without calling `schedulable_by` first. However, they read the class attributes set by `schedulable_by`; calling the scopes before `schedulable_by` uses the gem defaults (`:starts_at` / `:ends_at`).

| Scope | Description |
|---|---|
| `.active_at(time)` | Records whose start time is on or before `time` AND whose end time is either `nil` or strictly after `time`. |
| `.current` | Delegates to `.active_at(Time.zone.now)`. |
| `.upcoming` | Records whose start column is strictly after `Time.zone.now`. Returns `none` if `starts_at` is configured as `nil`. |
| `.expired` | Records whose end column is on or before `Time.zone.now`. Returns `none` if `ends_at` is configured as `nil`. |

```ruby
# Active right now
Promotion.current

# Active during a specific past window (for reporting)
Promotion.active_at(2.days.ago)

# Not yet started
Promotion.upcoming

# Ended
Promotion.expired
```

## Methods

### Instance methods

| Signature | Description |
|---|---|
| `active_at?(time) → Boolean` | Returns `true` when the record's start time is on or before `time` AND the end time is either `nil` or strictly after `time`. Boundary semantics: inclusive start, exclusive end. |
| `current? → Boolean` | Calls `active_at?(Time.zone.now)`. |
| `upcoming? → Boolean` | Returns `true` when the start column value is strictly after `Time.zone.now`. Returns `false` if the start field is not configured or the value is `nil`. |
| `expired? → Boolean` | Returns `true` when the end column value is on or before `Time.zone.now`. Returns `false` if the end field is not configured or the value is `nil`. |
| `start!(time = Time.zone.now)` | Writes `time` to the configured start column and persists with `update`. Raises a plain `RuntimeError` if no start field is configured. |
| `finish!(time = Time.zone.now)` | Writes `time` to the configured end column and persists with `update`. Raises a plain `RuntimeError` if no end field is configured. |
| `reschedule!(starts_at:, ends_at:)` | Updates both start and end columns atomically in a single `update` call. Silently skips whichever field is not configured. |

### Class methods

`schedulable_by` is the only public class method added. See [Configuration](#configuration) above.

## Examples

**Standard promotion with a fixed window:**

```ruby
class Promotion < ApplicationRecord
  include ConcernsOnRails::Schedulable

  schedulable_by # :starts_at, :ends_at
end

# Create a promotion active for one week
promo = Promotion.create!(
  name:       "Summer Sale",
  starts_at:  Time.zone.now,
  ends_at:    1.week.from_now
)

promo.current?   # => true
promo.upcoming?  # => false
promo.expired?   # => false

# End it early
promo.finish!
promo.expired?   # => true

# Reschedule to a future window
promo.reschedule!(starts_at: 2.days.from_now, ends_at: 9.days.from_now)
promo.current?   # => false
promo.upcoming?  # => true
```

**Event with custom column names:**

```ruby
class Event < ApplicationRecord
  include ConcernsOnRails::Schedulable

  schedulable_by starts_at: :starts_on, ends_at: :ends_on
end

Event.create!(title: "RailsConf", starts_on: 3.days.from_now, ends_on: 5.days.from_now)
Event.create!(title: "RubyKaigi", starts_on: 1.hour.ago,      ends_on: 1.day.from_now)

Event.current.pluck(:title)  # => ["RubyKaigi"]
Event.upcoming.pluck(:title) # => ["RailsConf"]
```

**Open-ended coupon (only an expiry column):**

```ruby
class Coupon < ApplicationRecord
  include ConcernsOnRails::Schedulable

  schedulable_by starts_at: nil, ends_at: :expires_at
end

Coupon.create!(code: "SAVE10", expires_at: 30.days.from_now)
Coupon.create!(code: "OLD20",  expires_at: 1.day.ago)

Coupon.current.pluck(:code) # => ["SAVE10"]

# .upcoming returns none because starts_at is not configured
Coupon.upcoming # => []
```

## Notes & gotchas

- **Boundary semantics are inclusive-start, exclusive-end.** A record is active at exactly `starts_at` but is not active at exactly `ends_at`. This matches the behavior of SQL half-open intervals and is verified by the spec's `freeze_time` boundary tests.
- **`nil` column values have defined semantics.** A `nil` start value means "not yet started" — the record is not `current?` or `upcoming?`. A `nil` end value means "never expires" — the record remains `current?` indefinitely once started. A record with both `nil` is not current, not upcoming, and not expired.
- **No `default_scope`.** Unlike `SoftDeletable`, `Schedulable` does not hide records automatically. All records are returned by plain `Model.all`; time-filtering must be applied explicitly via `.current`, `.upcoming`, `.expired`, or `.active_at`.
- **`schedulable_by` validates columns at load time.** If the configured column does not exist in the table, an `ArgumentError` is raised immediately when the class body is evaluated, not at query time. The error message matches `/does not exist/`.
- **Both fields cannot be `nil` simultaneously.** `schedulable_by(starts_at: nil, ends_at: nil)` raises `ArgumentError` with a message matching `/at least one/`.
- **`upcoming?` and `.upcoming` return false / `none` when `starts_at` is not configured.** There is no concept of "not yet started" when there is no start field. Similarly, `expired?` and `.expired` return false / `none` when `ends_at` is not configured.
- **`start!` and `finish!` raise a plain `RuntimeError` (not `ArgumentError`) when the respective field is not configured.** Guard against calling these methods on models where the field has been deliberately omitted.
- **`reschedule!` silently ignores unconfigured fields.** If `starts_at` is `nil`, only the end column is updated, and vice versa — no error is raised.
- **`schedulable_by` can be called multiple times.** The class attributes are reassigned on each call, which is useful in test setups or when a subclass needs a different column mapping than its parent.
- **Scopes use Arel rather than string interpolation**, making them safe against SQL injection and compatible with Rails' query interface for chaining (e.g. `Promotion.current.where(active: true)`).
- **`Time.zone.now` is used throughout.** All time comparisons respect the Rails timezone setting. Ensure `config.time_zone` is correctly set in your application to avoid off-by-one-hour bugs in time boundary checks.
