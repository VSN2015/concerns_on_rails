`Stateable` provides a lightweight, string-backed state machine for ActiveRecord models — the most common 80% of state-machine behavior without the overhead of a dedicated gem like AASM. It generates per-state predicates, scopes, and direct setters, plus optional guarded transition events with guard-check methods, all driven by a single `stateable_by` configuration macro. The fully-qualified module path is `ConcernsOnRails::Models::Stateable`; the shorter alias `ConcernsOnRails::Stateable` resolves to the same module.

## When to use it

- A `tickets` table needs `status` to move through `open → in_progress → resolved → closed`, and certain moves (e.g. reopening) should be blocked unless the current state permits it.
- An `articles` table already includes `Publishable` for timestamp tracking but also needs `draft / review / approved` workflow enforcement enforced at the model layer.
- A `shipments` model has a `state` column that must be constrained to a fixed set of values, and business logic depends on querying records in each state with a named scope.
- A column is named `state` or `status`, and the generated method names would clash with scopes from another concern (e.g. `Activatable` or `Expirable`) — `prefix:` or `suffix:` can disambiguate.
- A model needs a generic escape hatch (`transition_to!`) for admin tooling that bypasses normal guards, while everyday application code uses guarded event methods.

## Installation

```ruby
# app/models/article.rb
class Article < ApplicationRecord
  include ConcernsOnRails::Stateable

  stateable_by :status,
               states:      %i[draft pending published archived],
               default:     :draft,
               transitions: {
                 publish: { from: %i[draft pending], to: :published },
                 archive: { to: :archived }   # no :from => allowed from any state
               }
end
```

## Database columns

`Stateable` requires one `string` column on the model's table. The column name is whatever symbol you pass as the first argument to `stateable_by`.

| Column | Type | Required | Notes |
|---|---|---|---|
| _(configured field)_ | `string` | Yes | Stores the current state name as a plain string. |

```ruby
# db/migrate/YYYYMMDDHHMMSS_add_status_to_articles.rb
class AddStatusToArticles < ActiveRecord::Migration[7.1]
  def change
    add_column :articles, :status, :string
    # Optionally constrain and index at the database level:
    # add_index :articles, :status
  end
end
```

> `Stateable` does **not** use integer-backed storage (unlike Rails `enum`). Values are stored as plain strings matching the state name.

## Configuration

The macro signature is:

```ruby
stateable_by(field, states:, **options)
```

| Option | Type | Default | Description |
|---|---|---|---|
| `states:` | `Array<Symbol>` | — (required) | Ordered list of all valid state names. Cannot be empty. |
| `default:` | `Symbol` | `nil` | State applied to new, unsaved records whose column is blank. Must be a member of `states:`. Set via an `after_initialize` callback; does not override a non-blank value. |
| `transitions:` | `Hash` | `{}` | Named events. Each key is the event name (Symbol); each value is a hash with `:to` (required, Symbol) and optional `:from` (Symbol or Array of Symbols). Omitting `:from` means the transition is allowed from any state. |
| `prefix:` | `true`, `String`, or `Symbol` | `nil` | Prepended to all generated method/scope names separated by `_`. Pass `true` to use the field name; pass a string/symbol to use a literal prefix. |
| `suffix:` | `true`, `String`, or `Symbol` | `nil` | Appended to all generated method/scope names separated by `_`. Same coercion rules as `prefix:`. |

**Transition config keys** (values inside the `transitions:` hash):

| Key | Type | Required | Description |
|---|---|---|---|
| `:to` | `Symbol` | Yes | Target state for the transition. Must be a declared state. |
| `:from` | `Symbol` or `Array<Symbol>` | No | Allowed source state(s). Omit entirely to allow the transition from any state. |

## Scopes

One scope is added per declared state. The scope name respects any configured `prefix:` / `suffix:`.

| Scope | Description |
|---|---|
| `.<state>` (e.g. `.draft`, `.published`) | Returns records whose state column equals the state name. |

```ruby
Article.draft        # => WHERE status = 'draft'
Article.published    # => WHERE status = 'published'

# With prefix: true on a :state field:
Shipment.state_open  # => WHERE state = 'open'
```

## Methods

### Instance methods

| Method | Description |
|---|---|
| `<state>?` (e.g. `draft?`, `published?`) | Predicate — returns `true` if the state column equals this state's string value. |
| `<state>!` (e.g. `draft!`, `published!`) | Direct setter — calls `update!` with the target state, bypassing all transition guards. |
| `<event>!` (e.g. `publish!`, `archive!`) | Guarded transition — raises `InvalidTransition` if the current state is not in the transition's `:from` list. Calls `update!` on success. |
| `may_<event>?` (e.g. `may_publish?`, `may_archive?`) | Guard predicate — returns `true` if the guarded transition is currently allowed, without mutating state. |
| `transition_to!(state)` | Moves to any declared state by name (Symbol or String), bypassing transition guards. Raises `InvalidTransition` for undeclared states. |

All method names honor `prefix:` / `suffix:` configuration. For example, with `prefix: true` on field `:state`, the setter becomes `state_open!` and the predicate becomes `state_open?`.

### Class methods

The `stateable_by` macro is the only public class method added by the concern; all builder helpers are private.

## Examples

**Basic workflow with guarded transitions:**

```ruby
class Ticket < ApplicationRecord
  include ConcernsOnRails::Stateable

  stateable_by :status,
               states:  %i[open in_progress resolved closed],
               default: :open,
               transitions: {
                 start:   { from: :open,        to: :in_progress },
                 resolve: { from: :in_progress, to: :resolved },
                 close:   { to: :closed }   # allowed from any state
               }
end

ticket = Ticket.create!(title: "Login broken")
ticket.status          # => "open"
ticket.open?           # => true
ticket.may_start?      # => true
ticket.start!          # => UPDATE tickets SET status = 'in_progress' ...
ticket.may_start?      # => false (already in_progress)
ticket.resolve!        # => UPDATE tickets SET status = 'resolved' ...
ticket.close!          # => UPDATE tickets SET status = 'closed'

Ticket.resolved        # => [ticket] (after reload)
```

**Prefix to avoid scope clashes:**

```ruby
class Shipment < ApplicationRecord
  include ConcernsOnRails::Stateable
  include ConcernsOnRails::Activatable  # also adds `.active` scope

  # Without prefix, :active state would clash with Activatable's .active scope.
  stateable_by :state,
               states:  %i[open active closed],
               default: :open,
               prefix:  true
end

shipment = Shipment.create!
shipment.state_open?          # => true
Shipment.state_active         # => WHERE state = 'active'
shipment.state_active!        # unguarded setter
```

**Generic escape hatch via `transition_to!`:**

```ruby
# Admin tooling that needs to force a state regardless of normal guards:
ticket.transition_to!(:resolved)

# Undeclared state raises immediately:
ticket.transition_to!(:nope)
# => ConcernsOnRails::Stateable::InvalidTransition:
#      ConcernsOnRails::Models::Stateable: 'nope' is not a declared state
```

## Notes & gotchas

- **`ArgumentError` at class load time** — `stateable_by` validates eagerly. Errors are raised when the class is loaded, not at runtime. The following all raise `ArgumentError`:
  - The configured column does not exist in the schema (message: `does not exist in the database`).
  - `states:` is empty.
  - `default:` is not a member of `states:`.
  - A transition omits `:to`.
  - A transition references a state name not declared in `states:`.
  - A transition event name matches an existing state setter name — use `prefix:` or `suffix:` to resolve the clash.

- **Transition name / state name collision** — if you declare a state `:published` and also a transition named `published:`, `stateable_by` raises `ArgumentError` with a message indicating the clash. This is caught at class load time.

- **Direct setters are unguarded** — `published!` (the state setter) always calls `update!` regardless of the current state. Only the event methods generated from `transitions:` enforce guards. Do not confuse `published!` (setter) with `publish!` (guarded event).

- **`default:` uses `after_initialize`** — the default is applied only when `new_record?` is `true` and the column value is `blank?`. Because `blank?` is true for both `nil` and an empty string, an explicitly-assigned empty string is still overwritten by the default; only a non-blank explicit value (e.g. `"published"`) is preserved.

- **String storage** — state values are stored as plain strings, not integers. `status == "draft"` not `status == 0`. There is no automatic database constraint; add a `CHECK` constraint or database-level validation separately if needed.

- **No transition history** — `Stateable` does not record when or from where a transition occurred. Combine with `Publishable` or `Schedulable` for time-stamped state tracking.

- **`transition_to!` bypasses guards** — it only validates that the target state is declared; it does not consult `transitions:` `:from` rules. Use it for administrative or migration tooling, not for business-rule enforcement.

- **Method name conflicts with ActiveRecord** — state names like `new`, `valid`, or `save` will generate methods and scopes that shadow core ActiveRecord/Ruby methods. Use `prefix:` or `suffix:` for any state name that could collide.

- **`update!` is used throughout** — setters, event methods, and `transition_to!` all call `update!`. This means ActiveRecord validations run on every state change, and a `RecordInvalid` error can be raised if other validations on the model fail.

- **`InvalidTransition` error class** — it is namespaced as `ConcernsOnRails::Stateable::InvalidTransition` (accessible via the shorter alias). Rescue this specific class rather than `StandardError` for state-transition failures.
