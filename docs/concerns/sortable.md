Provides declarative list ordering for ActiveRecord models by combining a `default_scope` ORDER BY clause with the full [`acts_as_list`](https://github.com/brendon/acts_as_list) API. Including this concern eliminates hand-written `order` calls scattered across controllers and queries, and adds automatic position management (sequence assignment on insert, sequence compaction on destroy, and one-liner position manipulation) backed by a proven library. The concern is also available under its fully-qualified name `ConcernsOnRails::Models::Sortable`.

## When to use it

- A drag-and-drop interface where rows must maintain an explicit, user-controlled order (to-do lists, kanban cards, playlist tracks).
- A CMS where editors rank content manually and the ordered result must be the default query result everywhere.
- Scoped lists where ordering is independent per parent — e.g., each project has its own ordered task list.
- A simple read-only sort (by a non-position integer column like `priority` or `rank`) where position management via `acts_as_list` is not needed.
- Any situation where the sort direction should be descending by default (newest-first queues, priority tiers where `3 > 2 > 1`).

## Installation

Add the include and configuration macro to any ActiveRecord model:

```ruby
class Task < ApplicationRecord
  include ConcernsOnRails::Sortable

  sortable_by :position
end
```

A more complete example with scoped ordering:

```ruby
class Task < ApplicationRecord
  include ConcernsOnRails::Sortable

  belongs_to :project

  # Independent position sequence per project; new tasks go to bottom (default)
  sortable_by :position, scope: :project_id
end
```

## Database columns

The column named in `sortable_by` must exist in the schema before the macro is called. The default column name is `position`.

| Column | Type | Required | Notes |
|--------|------|----------|-------|
| `position` (or custom) | `integer` | Yes | Holds the sort value; name is set by the first argument to `sortable_by` |

```ruby
class AddPositionToTasks < ActiveRecord::Migration[7.1]
  def change
    add_column :tasks, :position, :integer
    add_index  :tasks, :position
  end
end
```

For scoped lists, also add the scope column and a composite index:

```ruby
class AddPositionAndProjectIdToTasks < ActiveRecord::Migration[7.1]
  def change
    add_column :tasks, :position,   :integer
    add_column :tasks, :project_id, :integer
    add_index  :tasks, [:project_id, :position]
  end
end
```

## Configuration

`sortable_by` accepts the sort column as a symbol or a one-key hash with direction, plus keyword options:

```ruby
sortable_by :position                            # symbol form — ascending
sortable_by position: :desc                      # hash form — explicit direction
sortable_by :position, use_acts_as_list: false   # ordering only, no acts_as_list
sortable_by :position, scope: :project_id        # per-scope position sequence
sortable_by :position, add_new_at: :top          # new records land at position 1
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `field_config` (positional) | `Symbol` or `Hash` | `:position` | The column to sort by. Pass a symbol (`:priority`) for ascending, or a one-key hash (`priority: :desc`) to set the direction. When omitted entirely and no `field_options` hash is given, defaults to `position: :asc`. |
| `use_acts_as_list` | `Boolean` | `true` | When `true`, calls `acts_as_list(column: <field>)` on the model so automatic position management is enabled. Set to `false` to use only the `default_scope` ORDER BY without any `acts_as_list` behaviour. |
| `scope` | `Symbol` or `String` | `nil` | Passed directly to `acts_as_list` as its `scope:` option. Restricts position numbering to a subset of rows sharing the same value in the named column. Ignored when `use_acts_as_list: false`. |
| `add_new_at` | `Symbol` | `nil` | Passed directly to `acts_as_list` as its `add_new_at:` option. Accepts `:top` or `:bottom`. When `:top`, newly inserted records receive position `1` and existing records are shifted down. Ignored when `use_acts_as_list: false`. |

**Direction values.** Only `:asc` and `:desc` are accepted. Any other value silently falls back to `:asc`.

**Calling `sortable_by` more than once.** The macro overwrites `sortable_field` and `sortable_direction` each time it is called. The last call wins. Note that `default_scope` is registered once at include time and reads the class attributes at query execution time, so re-calling the macro dynamically is supported.

## Scopes

This concern adds no named ActiveRecord scopes. Ordering is applied through a `default_scope`, so it is active on every query that does not call `.unscoped`.

## Methods

### Instance methods

The following methods are available when `use_acts_as_list: true` (the default). They are provided by the `acts_as_list` gem and are wired to the configured column automatically.

| Method | Description |
|--------|-------------|
| `move_higher` | Decrements this record's position by one, swapping it with the record above. |
| `move_lower` | Increments this record's position by one, swapping it with the record below. |
| `move_to_top` | Sets this record's position to `1`, shifting all others down. |
| `move_to_bottom` | Sets this record's position to the highest value, shifting all others up. |

Position values are automatically assigned on `create` and compacted on `destroy` — no manual renumbering is needed.

### Class methods

| Method | Signature | Description |
|--------|-----------|-------------|
| `sortable_by` | `sortable_by(field_config = nil, use_acts_as_list: true, scope: nil, add_new_at: nil, **field_options)` | Configures the sort column and direction, validates the column exists, and optionally sets up `acts_as_list`. |

## Examples

**Basic list with automatic position management:**

```ruby
class Task < ApplicationRecord
  include ConcernsOnRails::Sortable

  sortable_by :position
end

task1 = Task.create!(name: "First")   # position: 1
task2 = Task.create!(name: "Second")  # position: 2
task3 = Task.create!(name: "Third")   # position: 3

task3.move_to_top

Task.pluck(:name)
# => ["Third", "First", "Second"]

task2.destroy
Task.pluck(:position)
# => [1, 2]  — compacted automatically
```

**Priority field sorted descending, without `acts_as_list`:**

```ruby
class Ticket < ApplicationRecord
  include ConcernsOnRails::Sortable

  # No acts_as_list — priority is managed by the application, not the gem
  sortable_by priority: :desc, use_acts_as_list: false
end

Ticket.create!(subject: "Low bug",    priority: 1)
Ticket.create!(subject: "High crash", priority: 3)
Ticket.create!(subject: "Medium UX",  priority: 2)

Ticket.pluck(:subject)
# => ["High crash", "Medium UX", "Low bug"]
```

**Scoped list — independent position sequence per project:**

```ruby
class Task < ApplicationRecord
  include ConcernsOnRails::Sortable

  belongs_to :project

  sortable_by :position, scope: :project_id, add_new_at: :top
end

project_a = Project.create!(name: "Alpha")
project_b = Project.create!(name: "Beta")

t1 = Task.create!(name: "A1", project_id: project_a.id)  # position: 1 in Alpha
t2 = Task.create!(name: "A2", project_id: project_a.id)  # position: 1 in Alpha (add_new_at: :top pushed t1 to 2)
t3 = Task.create!(name: "B1", project_id: project_b.id)  # position: 1 in Beta

t1.reload.position  # => 2
t2.position         # => 1
t3.position         # => 1  (own sequence inside Beta)
```

## Notes & gotchas

- **Column must exist at macro call time.** `sortable_by` calls `ensure_columns!` immediately and raises `ArgumentError` with a message of the form `ConcernsOnRails::Models::Sortable: '<field>' does not exist in the database (table: <table>)` if the column is absent. The same check is also repeated inside the `default_scope` block, so including the concern without calling `sortable_by` will raise during the first query if the default `position` column is missing.
- **`default_scope` is always active.** Ordering is applied via `default_scope`, not a named scope. This means `Task.all`, associations, and any chained relation will include the ORDER BY unless `.unscoped` is called explicitly. This can cause unexpected behavior in contexts such as `GROUP BY` queries, `SELECT DISTINCT`, or subqueries — the standard `default_scope` footguns apply.
- **Default field is `:position` with direction `:asc`.** These defaults are set in the `included` block via `class_attribute`, so they apply even if `sortable_by` is never called. A model that includes the concern but omits the macro will still apply `ORDER BY position ASC` and still raise if `position` does not exist.
- **Invalid direction silently falls back to `:asc`.** Any direction value that is not exactly `:asc` or `:desc` (e.g., a typo like `:ascending`) is replaced with `:asc` without raising or logging a warning.
- **`acts_as_list` dependency.** When `use_acts_as_list: true` (the default), the gem calls `acts_as_list` on the model at the time `sortable_by` is evaluated. The `acts_as_list` gem must be present in the bundle. If `use_acts_as_list: false` is passed, the gem is not invoked and only the `default_scope` ORDER BY is added.
- **`scope:` and `add_new_at:` are `acts_as_list` pass-throughs.** These options are forwarded verbatim to `acts_as_list(column:, scope:, add_new_at:)`. They have no effect when `use_acts_as_list: false`. Refer to the `acts_as_list` documentation for the full set of values each accepts.
- **Calling `sortable_by` multiple times.** Each call overwrites `sortable_field` and `sortable_direction`. The `default_scope` reads these class attributes at query time, so the last call determines the actual ordering. However, each call also invokes `acts_as_list` again, which may result in duplicate callbacks being registered — prefer a single `sortable_by` call per model class.
- **Thread safety.** `sortable_field` and `sortable_direction` are `class_attribute` values shared across threads. Mutating them at runtime (e.g., calling `sortable_by` after boot) is not thread-safe and is not supported in production.
