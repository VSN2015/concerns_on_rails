The `Storable` concern adds **typed, defaulted, optionally-validated accessors over a single JSON (or text) column** to any ActiveRecord model — "store_attribute-lite". Rails' native `store_accessor` is untyped on every supported version (a form-submitted `"true"` stays the String `"true"`), ships no defaults, and exposes no per-key dirty methods; that gap is why the `store_attribute` and `jsonb_accessor` gems exist. Storable closes it with zero extra dependencies, using `ActiveModel::Type` (which ships with Rails) for casting.

## When to use it

- A user-preferences endpoint (`PATCH /me/settings`): `theme`, `notifications_enabled`, `items_per_page` arrive as strings, get cast to their declared types, and persist into one `settings` column — no migration per toggle.
- Per-account plan flags and limits on an `accounts.flags` column: `beta_features` (boolean), `seat_limit` (integer), `trial_ends_at` (datetime round-tripped through JSON as ISO8601).
- Integration/connection config on a `webhooks.config` column: `retry_count` (integer, default 3), `verify_ssl` (boolean, default true) — defaults returned without being persisted.
- Anywhere you'd otherwise sprinkle `value.to_i` / `ActiveModel::Type::Boolean.new.cast(...)` over controller code to compensate for an untyped store.

## Installation

Add the concern to your model and call the configuration macro. The fully-qualified form `ConcernsOnRails::Models::Storable` resolves to the same module.

```ruby
class Account < ApplicationRecord
  include ConcernsOnRails::Storable

  storable_by :settings,
    theme:          { type: :string,  default: "light", in: %w[light dark] },
    notifications:  { type: :boolean, default: true },
    items_per_page: { type: :integer, default: 25 },
    trial_ends_at:  { type: :datetime }

  # Affixed accessors (collision escape hatch) on a second, independent column:
  storable_by :flags, { beta: { type: :boolean, default: false } }, prefix: :flag
end
```

## Database columns

One column per `storable_by` call — `t.text` works everywhere (JSON is encoded/decoded internally); a native `t.json` / `t.jsonb` column or a column the host app already `serialize`d is detected automatically and handed the Hash directly. The macro validates the column exists and raises `ArgumentError` otherwise.

```ruby
add_column :accounts, :settings, :text   # or :jsonb on PostgreSQL
```

## Configuration

### `storable_by(column, keys = {}, prefix: nil, suffix: nil, **kw_keys)`

Key specs may be passed as trailing keyword arguments or as the positional Hash (the escape hatch for keys literally named `prefix`/`suffix`). Per key:

| option | default | meaning |
|---|---|---|
| `type:` | `:string` | One of `:string`, `:integer`, `:float`, `:decimal`, `:boolean`, `:date`, `:datetime`, `:json` |
| `default:` | `nil` | Returned while the key is absent — never persisted. A Proc is `instance_exec`'d per read; Hash/Array defaults are deep-duped per read |
| `in:` | — | Adds a model validation: a present, non-nil value must cast into the set (errors land on the accessor name) |

The macro is **repeatable** — repeat calls for the same column merge keys, different columns are independent, and subclasses can add keys without affecting the parent. Every generated name is collision-checked against existing methods and columns at macro time (`ArgumentError`; use `prefix:`/`suffix:` to rename).

## Methods

Per declared key (names affixed as `<prefix>_<key>_<suffix>`):

- `account.theme` — decoded, cast, default-resolving reader
- `account.theme = value` — casting writer (marks the whole column dirty)
- `account.notifications?` — predicate, `:boolean` keys only
- `account.theme_changed?` / `account.theme_was` — per-key dirty, computed against the column's own previous value (cast)
- `account.reset_theme` — removes the key so the reader resolves the default again (in-memory; save to persist)

Class level: `Account.storable_keys` exposes the normalized registry (`{ settings: { theme: { type:, default:, in:, accessor: } } }`).

## Examples

```ruby
account = Account.new
account.theme                 # => "light"   (virtual default — nothing stored)
account.notifications = "0"  # a string param…
account.notifications        # => false     (…cast on the way in)
account.items_per_page = "50"
account.items_per_page        # => 50

account.theme = "neon"
account.valid?                # => false; errors[:theme] => ["is not included in the list"]

account.trial_ends_at = Time.utc(2026, 7, 1, 12, 30)
account.save!
account.reload.trial_ends_at  # => 2026-07-01 12:30:00 UTC (stored as ISO8601 text)

account.theme = nil           # explicit null: reads back nil, NOT the default
account.reset_theme           # key removed: reads back "light" again
```

## Notes & gotchas

- **Whole-column dirty**: writing one key reassigns (and saves) the entire column — two processes writing different keys of the same row are last-write-wins on the whole hash. There is no per-key merge on save.
- **nil vs unset**: a written `nil` is an explicit JSON null and does not fall back to the default; `reset_<key>` removes the key entirely. The two are deliberately different.
- **`:json` values**: passed through uncast, and the reader returns a dup — reassign (`acct.config = acct.config.merge("k" => 1)`), don't mutate in place, or the write is silently lost.
- **Precision**: `:decimal` is stored as a precision-safe String (`BigDecimal`); `:datetime` as UTC ISO8601 with microseconds; `:date` as `YYYY-MM-DD`.
- **Read-side safety**: corrupt column JSON decodes as `{}` (defaults apply); garbage values cast to `nil`. Readers never raise.
- **Undeclared keys** already in the column are preserved through typed writes.
- Reach for [`store_attribute`](https://github.com/palkan/store_attribute) / [`jsonb_accessor`](https://github.com/madeintandem/jsonb_accessor) when you need to **query** into the store (jsonb operators, store-backed scopes).
