The `Auditable` concern adds a lightweight change history ("paper_trail-lite") to any ActiveRecord model by appending JSON entries to a single text column on the same table. There are no extra tables and no versioning engine — changes to the tracked fields are captured in a `before_save` callback and written in the same `INSERT`/`UPDATE` statement, so it works on every database Rails supports, including SQLite. Use it when you need a per-record answer to "who changed this and when" without the operational weight of `paper_trail` or `audited`.

## When to use it

- An admin panel where staff need to see the recent price/status history of a product inline on the record page.
- A compliance-lite requirement: "keep the last N changes to these sensitive fields, with the actor's email".
- Debugging data mysteries ("who flipped this flag?") on a handful of high-value columns.
- An order/invoice model where status transitions should be traceable without joining an audit table.
- Any model where a bounded, per-record changelog is enough — and a global, queryable audit store would be overkill.

## Installation

Add the concern to your model and call the configuration macro once. The fully-qualified alias `ConcernsOnRails::Models::Auditable` also works and resolves to the same module.

```ruby
class Product < ApplicationRecord
  include ConcernsOnRails::Auditable

  # Minimal — tracks :price and :status into the default :audit_log column
  auditable_by :price, :status

  # Extended — custom column, actor stamping, tighter cap
  # auditable_by :price, into: :history,
  #              actor: -> { Current.user&.email },
  #              max_entries: 50
end
```

## Database columns

A single text column is required (the tracked fields are your existing columns).

| Column | Type | Required | Notes |
|--------|------|----------|-------|
| `audit_log` (or your chosen `into:` column) | `text` | Yes | Stores the JSON array of entries; stays `NULL` until a tracked field first changes |

```ruby
class AddAuditLogToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :audit_log, :text
  end
end
```

## Configuration

### `auditable_by(*fields, into: :audit_log, actor: nil, max_entries: 200, max_value_length: nil)`

Configures the tracked fields and the audit column. Every column (tracked fields and `into:`) must exist or the macro raises `ArgumentError` at class-load time. Calling the macro a second time reconfigures the concern (last call wins).

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `*fields` | one or more `Symbol`s | — (required) | The attributes to track. Tracking the audit column itself raises `ArgumentError`. |
| `into:` | `Symbol` | `:audit_log` | The text column the JSON history is written to. |
| `actor:` | callable or `nil` | `nil` | Evaluated with `instance_exec` on the record at save time; its return value is stamped as `"by"` on each entry. Must respond to `#call`. |
| `max_entries:` | positive `Integer` or `nil` | `200` | Keeps only the newest N entries (oldest are trimmed). `nil` disables trimming. |
| `max_value_length:` | positive `Integer` or `nil` | `nil` | When set, `from`/`to` **String** values longer than the limit are stored as their first N characters plus a trailing `…` marker. Non-string values are never truncated. |

## Entry format

One entry is recorded **per changed tracked field per save**; all entries of one save share the same timestamp. On create, entries are recorded with `"from" => nil`.

```json
{ "field": "price", "from": 100, "to": 200, "at": "2026-06-10T12:34:56Z", "by": "admin@shop.com" }
```

- Keys are strings; `audit_trail` returns exactly what `JSON.parse` produces.
- `"at"` is ISO8601 UTC, second precision.
- `"by"` is **omitted entirely** when no actor is configured or the actor returns `nil`.
- Values are JSON-coerced: `Time`/`DateTime`/`TimeWithZone` → ISO8601 UTC strings, `Date` → ISO8601, `BigDecimal` → plain numeric string (`"19.99"`, precision-safe), `Symbol` → `String`; everything else passes through `as_json`.
- There is **no built-in length cap** on `from`/`to` — by default a change to a large text field stores both full values. Set `max_value_length:` to bound entry size explicitly (e.g. `max_value_length: 120` stores `"first 120 chars…"`); truncation runs after coercion and applies only to `String` values.

## Methods

### Instance methods

| Signature | Description |
|-----------|-------------|
| `audit_trail → Array<Hash>` | Decoded entries, oldest first. Returns `[]` for a `NULL`, blank, corrupt, or non-array column — it never raises. |
| `last_change_for(field) → Hash \| nil` | The most recent entry for `field` (symbol or string), or `nil` when the field never changed. |
| `audited_changes_since(time) → Array<Hash>` | Entries recorded at or after `time`, oldest first. Entries with a missing/unparseable `"at"` are excluded. |
| `clear_audit_trail! → true` | Wipes the column with a single `update_column` — deliberately skips validations and callbacks so clearing can never itself be captured. Raises on unpersisted records. |

### Class-level configuration readers

`auditable_fields`, `auditable_into`, `auditable_actor`, `auditable_max_entries`.

## Examples

**Basic lifecycle:**

```ruby
product = Product.create!(name: "Widget", price: 100)
product.audit_trail
# => [{"field"=>"price", "from"=>nil, "to"=>100, "at"=>"2026-06-10T12:00:00Z"}]

product.update!(price: 200, status: "live")
product.audit_trail.size        # => 3 (price create, price update, status update)
product.last_change_for(:price) # => {"field"=>"price", "from"=>100, "to"=>200, ...}
```

**Actor stamping with `CurrentAttributes`:**

```ruby
class Order < ApplicationRecord
  include ConcernsOnRails::Auditable

  auditable_by :status, :total_cents, actor: -> { Current.user&.email }
end

# In a controller: Current.user = current_user
order.update!(status: "shipped")
order.audit_trail.last["by"]    # => "ops@example.com"
```

**Recent-changes report:**

```ruby
order.audited_changes_since(1.day.ago).map { |e| "#{e['field']}: #{e['from']} → #{e['to']}" }
# => ["status: pending → shipped"]
```

## Notes & gotchas

- **Callback-skipping writes are not audited.** `update_column`/`update_columns`, `touch`, `increment!`, and `delete` bypass `before_save`, so they leave no entries. `save(validate: false)` *is* audited (callbacks still run).
- **Bounded by design.** The default `max_entries: 200` keeps the row from growing without limit; the oldest entries are silently trimmed. Pass `nil` only when you have an external cleanup story. For large tracked text fields, add `max_value_length:` so individual entries stay small too — otherwise each change stores the full old *and* new values.
- **Corrupt JSON is tolerated, then replaced.** A hand-edited or truncated column decodes as `[]` and is overwritten by a fresh trail on the next tracked save.
- **Values come back as primitives.** `from`/`to` are JSON values, not typed Ruby objects — a `Time` round-trips as an ISO8601 string, a `BigDecimal` as a numeric string.
- **Not concurrency-safe.** The read-modify-write of the JSON column means two simultaneous saves of the same row are last-writer-wins for the entries added in that race.
- **Entries build on the persisted trail.** New entries are appended to the column's *database* value, so a save aborted by a later callback can't duplicate entries when retried. The flip side: assigning the audit column by hand in the same save as a tracked change is ignored — use `clear_audit_trail!` to reset the trail.
- **Non-finite floats are stored as strings.** `NaN`/`Infinity` in a tracked float column serialize as `"NaN"`/`"Infinity"` instead of raising inside `before_save`.
- **The actor proc runs on the record.** It is `instance_exec`'d, so both globals (`Current.user`) and the record's own attributes are in scope. Exceptions raised inside the proc propagate (fail-fast).
- **Non-goals**: no reify/undo, no who-dunnit queries across models, no association tracking — reach for [`paper_trail`](https://github.com/paper-trail-gem/paper_trail) or [`audited`](https://github.com/collectiveidea/audited) when you need a real audit store.
