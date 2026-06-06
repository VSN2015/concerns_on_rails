`SoftDeletable` adds non-destructive deletion to ActiveRecord models by writing a timestamp to a configurable column instead of issuing a SQL `DELETE`. Records are hidden from standard queries via an optional `default_scope`, and can be individually or bulk-restored at any time. All state transitions run inside database transactions, so a raising lifecycle hook rolls the change back atomically.

## When to use it

- **User accounts or content that may need recovery** — soft-deleting a `User` or `Post` lets an admin restore it without relying on backups.
- **Audit trails and compliance** — the timestamp records exactly when something was "deleted" and the row stays in the database for reporting.
- **Referential integrity** — records referenced by foreign keys in other tables cannot be hard-deleted without cascades; a soft delete sidesteps that constraint while keeping the data available.
- **Deferred cleanup pipelines** — mark records deleted immediately, then run a background job that hard-deletes rows older than a retention window using `deleted_within`.
- **Multi-tenant SaaS** — a tenant's records can be soft-deleted when they churn, kept for a grace period, then permanently purged with `really_destroy_all`.

## Installation

```ruby
class Article < ApplicationRecord
  include ConcernsOnRails::SoftDeletable

  soft_deletable_by :deleted_at
end
```

The fully-qualified form `ConcernsOnRails::Models::SoftDeletable` is equivalent and can be used when you need an explicit namespace.

## Database columns

| Column | Type | Required | Notes |
|---|---|---|---|
| `deleted_at` (or custom name) | `datetime` | Yes | `NULL` means active; a timestamp means soft-deleted |

Migration to add the default column to an existing table:

```ruby
class AddDeletedAtToArticles < ActiveRecord::Migration[7.1]
  def change
    add_column :articles, :deleted_at, :datetime
    add_index  :articles, :deleted_at
  end
end
```

If you use a custom field name (e.g. `removed_on`), substitute that name for `deleted_at` above.

## Configuration

```ruby
soft_deletable_by(field = nil, touch: true, default_scope: true)
```

| Option | Type | Default | Description |
|---|---|---|---|
| `field` | Symbol (positional) | `nil` (falls back to `:deleted_at`) | The database column that stores the deletion timestamp. When omitted/`nil`, defaults to `:deleted_at`. Must already exist in the schema; raises `ArgumentError` if not. |
| `touch:` | Boolean | `true` | When `true`, uses `update` so `updated_at` is bumped on soft-delete and restore. When `false`, uses `update_column`, bypassing callbacks and skipping the `updated_at` update. |
| `default_scope:` | Boolean | `true` | When `true`, a `default_scope` hides soft-deleted rows from `.all`. When `false`, deleted rows appear in all queries and you opt in to filtering with `.without_deleted`. New models are encouraged to use `false` to avoid the join and uniqueness-validation footguns that come with `default_scope`. |

### Validation on configuration

`soft_deletable_by` calls `ensure_columns!` (from `ConcernsOnRails::Support::ColumnGuard`) and raises `ArgumentError` if the specified column does not exist in the table at the time the class is loaded.

## Scopes

All scopes use `unscope(where: soft_delete_field)` before applying their own condition, so they work correctly whether `default_scope` is enabled or not.

| Scope | Description | Example |
|---|---|---|
| `.active` | Records where the soft-delete column is `NULL` (alias of `.without_deleted`). | `Article.active` |
| `.without_deleted` | Records where the soft-delete column is `NULL`. | `Article.without_deleted` |
| `.soft_deleted` | Records where the soft-delete column is not `NULL`. | `Article.soft_deleted` |
| `.only_deleted` | Alias for `.soft_deleted`. | `Article.only_deleted` |
| `.with_deleted` | All records regardless of deletion state; peels off the default scope. | `Article.with_deleted` |
| `.deleted_within(duration)` | Soft-deleted records whose timestamp falls within the given duration from now. | `Article.deleted_within(7.days)` |

```ruby
Article.active                     # => non-deleted records
Article.soft_deleted               # => deleted records
Article.with_deleted               # => all records
Article.deleted_within(30.days)    # => deleted in the last 30 days
```

## Methods

### Instance methods

| Signature | Description |
|---|---|
| `soft_delete!` | Sets the soft-delete column to `Time.zone.now`. Returns `true` on success, `false` if the update fails. Idempotent — returns `true` immediately if the record is already deleted. Runs `before_soft_delete` / `after_soft_delete` hooks inside a transaction. |
| `restore!` | Clears the soft-delete column (sets it to `nil`). Returns `true` on success, `false` if the update fails. Idempotent — returns `true` immediately if the record is not deleted. Runs `before_restore` / `after_restore` hooks inside a transaction. |
| `really_delete!` | Hard-deletes the record via `self.class.unscoped.where(primary_key => id).delete_all` (deletes only this row, bypassing the default scope and all ActiveRecord callbacks/validations), then calls `freeze` on the instance. |
| `deleted?` | Returns `true` if the soft-delete column is present (non-nil). |
| `soft_deleted?` | Alias for `deleted?`. |
| `is_soft_deleted?` | Alias for `deleted?`. |
| `is_really_deleted?` | Returns `true` if the record no longer exists in the database at all (uses `unscoped.exists?`). |
| `before_soft_delete` | Hook method called before the soft-delete timestamp is written. Override in the model; default is a no-op. |
| `after_soft_delete` | Hook method called after a successful soft-delete. Override in the model; default is a no-op. |
| `before_restore` | Hook method called before the soft-delete timestamp is cleared. Override in the model; default is a no-op. |
| `after_restore` | Hook method called after a successful restore. Override in the model; default is a no-op. |

### Class methods

| Signature | Description |
|---|---|
| `soft_deletable_by(field = nil, touch: true, default_scope: true)` | Configuration macro. Sets the soft-delete column (defaulting to `:deleted_at` when `field` is `nil`) and options; validates the column exists. |
| `soft_delete_all` | Soft-deletes every record in the current scope, atomically (single transaction). Preferred over `destroy_all`. |
| `destroy_all` | Overrides ActiveRecord's `destroy_all` to call `soft_delete_all` instead of issuing `DELETE`. Kept for backwards compatibility. |
| `really_destroy_all` | Hard-deletes every record using `unscoped.delete_all` — bypasses soft-delete, default scope, and all callbacks. |
| `restore_all` | Restores every soft-deleted record in the current scope, atomically (single transaction). |

## Examples

**Basic soft-delete and restore cycle:**

```ruby
class Article < ApplicationRecord
  include ConcernsOnRails::SoftDeletable

  soft_deletable_by :deleted_at
end

article = Article.create!(title: "Hello World")

article.soft_delete!
article.deleted?         # => true
article.deleted_at       # => 2026-06-06 10:00:00 UTC (approximate)

Article.all              # => [] (hidden by default_scope)
Article.with_deleted     # => [article]
Article.soft_deleted     # => [article]

article.restore!
article.deleted?         # => false
Article.all              # => [article]
```

**Opting out of `default_scope` (recommended for new models):**

```ruby
class Invoice < ApplicationRecord
  include ConcernsOnRails::SoftDeletable

  soft_deletable_by :deleted_at, default_scope: false
end

Invoice.all                    # => all records, including soft-deleted
Invoice.without_deleted        # => only active records
Invoice.soft_deleted           # => only deleted records
```

**Lifecycle hooks and transactional rollback:**

```ruby
class Order < ApplicationRecord
  include ConcernsOnRails::SoftDeletable

  soft_deletable_by :deleted_at

  def after_soft_delete
    # If this raises, the deleted_at timestamp is rolled back
    AuditLog.create!(event: "order_deleted", order_id: id)
  end

  def before_restore
    raise "Cannot restore a fulfilled order" if fulfilled?
  end
end

order = Order.create!(...)
order.soft_delete!   # writes deleted_at AND creates AuditLog in one transaction
order.restore!       # raises if fulfilled?, deleted_at stays set
```

## Notes & gotchas

- **`default_scope` is sticky.** When `default_scope: true` (the default), every query — including joins, `includes`, and uniqueness validations — silently excludes soft-deleted rows. Uniqueness validators on other columns will not see deleted records, potentially allowing duplicates. For new models, prefer `default_scope: false` and chain `.without_deleted` explicitly.

- **`destroy_all` is silently overridden.** Calling `Article.destroy_all` soft-deletes records instead of hard-deleting them. This can surprise code that expects standard ActiveRecord behavior. Prefer the explicit `.soft_delete_all` to make the intent clear.

- **Hook callback order is guaranteed.** `before_soft_delete` fires before the write; `after_soft_delete` fires only if the update succeeds. The same applies to `before_restore` / `after_restore`. The spec asserts the exact order `[:before_soft_delete, :after_soft_delete]` and `[:before_restore, :after_restore]`.

- **A raising hook rolls back the timestamp.** Both `soft_delete!` and `restore!` wrap their work — hook calls and the `update`/`update_column` call — in a `transaction` block. If `after_soft_delete` raises, `deleted_at` is never committed.

- **`after_soft_delete` is not called on a failed update.** If `update` returns `false` (e.g. because a validation fails), `after_soft_delete` is skipped and `soft_delete!` returns `false`.

- **`soft_delete!` and `restore!` are idempotent.** Calling `soft_delete!` on an already-deleted record returns `true` immediately without writing to the database or running hooks. Calling `restore!` on a non-deleted record does the same.

- **`touch: false` uses `update_column`.** This bypasses ActiveRecord validations and callbacks (including `before_save`), and does not update `updated_at`. Use with care on models that have validations involving the soft-delete column.

- **`really_delete!` freezes the instance.** After calling `really_delete!`, the Ruby object is frozen and cannot be modified. `is_really_deleted?` will return `true`.

- **`really_destroy_all` uses `unscoped`.** It ignores any current scope and deletes every row in the table. Call it on a scoped relation (e.g. `Article.where(user_id: 42).really_destroy_all`) — but note that the underlying implementation calls `unscoped.delete_all`, so the scope may not be respected as expected. Prefer explicit `where` + `delete_all` for scoped hard-deletes.

- **Custom field names are fully supported.** Any `datetime` column works: `soft_deletable_by :removed_on`. All scopes and methods adapt to the configured field. Multiple models can use different field names independently — `class_attribute` ensures isolation between classes.

- **STI (Single Table Inheritance) works.** Subclasses inherit the configuration and all scopes from the parent class without additional setup.

- **Column must exist at class-load time.** `soft_deletable_by` validates the column via `ConcernsOnRails::Support::ColumnGuard#ensure_columns!` and raises `ArgumentError` with the message `"does not exist in the database"` if the column is missing. This means running the model before running migrations will fail fast rather than silently.

- **`.active` scope conflict.** If `Activatable` and `SoftDeletable` are both included in the same model, both define an `.active` scope. The last `include` statement wins. Stick to one concern or rely on `.without_deleted` to avoid ambiguity.
