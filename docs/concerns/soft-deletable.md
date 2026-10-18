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
| `cascade:` | `Symbol` or `Array<Symbol>` | `nil` | `has_many` / `has_one` associations soft-deleted with the record — inside its transaction, with its exact timestamp, through each dependent's own `soft_delete!` (hooks and nested cascades run) — and restored with it. Only dependents carrying the parent's timestamp are restored, so one deleted independently earlier stays deleted. Dependents are loaded with only the gem's own hiding predicates removed — those on the child's own table's SoftDeletable column and, under Publishable's `default_scope: true`, its Publishable column — so a child hiding its drafts is cascaded too; the association's own conditions and every other default-scope predicate still apply, as for Rails' `dependent:` — a tenant, a discriminator on a shared table, a joined table's same-named column (`joins(:author).where(authors: { deleted_at: nil })`). A `has_one` cascades to the child its reader returns (a hidden one only when the reader returns none). Targets must include SoftDeletable; `belongs_to`, HABTM and `:through` raise `ArgumentError`. Disables the single-`UPDATE` batch fast paths. |

### Validation on configuration

`soft_deletable_by` calls `ensure_columns!` (from `ConcernsOnRails::Support::ColumnGuard`) and raises `ArgumentError` if the specified column does not exist in the table at the time the class is loaded.

## Scopes

All scopes peel the soft-delete column on the model's **own table** (`unscope(where: arel_table[soft_delete_field])`) before applying their own condition, so they work correctly whether `default_scope` is enabled or not, and an association scope such as `has_many :all_comments, -> { with_deleted }` reaches the deleted children. Because the peel is table-qualified, a scope merged into another model's relation (`Comment.joins(:post).merge(Post.with_deleted)`) leaves that model's own `deleted_at` predicates alone. Rails 6.0 can unscope by column name only, so there the scopes still unscope by name, and such a merge also strips the outer model's `deleted_at` predicates.

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
| `soft_delete!(at: Time.zone.now)` | Sets the soft-delete column to `at` (default now — pass a time to backdate). `nil` or a blank value (`""`, `"  "`) also means now, as for `expire!` (it used to write `NULL`, delete nothing and return `true`). Any other `at:` is cast through the column's type, and a value that is not a time raises `ArgumentError` before any hook runs, with nothing (no dependent either) written: a String must name a year (ISO 8601, RFC 2822, `"Oct 1 2026"` and `"2026-10-01 10:30"` all do; `"junk"`, `"Monday"` and `"10:30"` do not, although `Time.zone.parse` reads them as June 1st and today), and `42` or `1.hour` never cast. Returns `true` on success, `false` if the update fails. Idempotent — returns `true` immediately if the record is already deleted. Runs `before_soft_delete`, the write, the `cascade:` dependents' own `soft_delete!(at:)`, then `after_soft_delete`, all inside one transaction. A dependent that fails to save raises `ActiveRecord::RecordNotSaved` and rolls the transaction back. |
| `restore!` | Clears the soft-delete column (sets it to `nil`). Returns `true` on success, `false` if the update fails. Idempotent — returns `true` immediately if the record is not deleted. Runs `before_restore`, the write, `restore!` on the `cascade:` dependents whose timestamp equals this record's, then `after_restore`, inside one transaction. A dependent that fails to save raises `ActiveRecord::RecordNotSaved` and rolls the transaction back. |
| `really_delete!` | Hard-deletes the record via `self.class.unscoped.where(primary_key => id).delete_all` (deletes only this row, bypassing the default scope and all ActiveRecord callbacks/validations), then marks the instance destroyed (`destroyed?` true, `persisted?` false) and freezes it, as ActiveRecord's `delete` does. |
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
| `soft_deletable_by(field = nil, touch: true, default_scope: true, prefix: nil, suffix: nil, cascade: nil, relation_destroy_all: :soft)` | Configuration macro. Sets the soft-delete column (defaulting to `:deleted_at` when `field` is `nil`) and options; validates the column exists. `relation_destroy_all:` (`:soft` default, or `:hard`) decides what a relation's / association's `destroy_all` does (see `destroy_all`); anything else raises `ArgumentError`. Set by every call, inherited by subclasses that do not call the macro. |
| `soft_delete_all` | Soft-deletes every record in the current scope and returns the Integer count. A failing record raises `ActiveRecord::RecordNotSaved` and rolls the whole batch back. With `touch: false` and no overridden hooks it collapses to a single `UPDATE`. Preferred over `destroy_all`. |
| `destroy_all` | Overrides ActiveRecord's `destroy_all`; **contextual**. On the class (`Article.destroy_all`) it calls `soft_delete_all` and returns the Integer count. On a relation (`Article.where(...).destroy_all`, `destroy_by`, `in_batches.destroy_all`) and on a non-`:through` association (`post.comments.destroy_all`) it soft-deletes each **live** record through `soft_delete!` (hooks, cascade; `RecordNotSaved` + rollback on failure), returning the records acted on, as ActiveRecord's own `destroy_all` does (`nil` when a `before_remove` aborts). A record that is **already soft-deleted** is destroyed for real (Rails' own destroy) only when the relation was built by one of **that model's own** trash scopes (`only_deleted`, `soft_deleted`, `deleted_within`, `with_deleted`, affixed or not; another model's trash scope merged in does not count), so `only_deleted.destroy_all` / `deleted_within(30.days).destroy_all` purge the trash and a mixed `with_deleted.destroy_all` soft-deletes its live rows and purges the trashed ones; any other relation (including every relation of a `default_scope: false` model) leaves the trash untouched. The association form runs `before_remove` / `after_remove`. Rails' own association maintenance stays hard (see the gotchas below). `relation_destroy_all: :hard` restores ActiveRecord's own hard delete for the relation and association forms. Kept for backwards compatibility; prefer `soft_delete_all`. |
| `really_destroy_all` | Hard-deletes the records matching the **current relation**, soft-deleted included — only the default scope's own `deleted_at IS NULL` is peeled off, so `only_deleted.really_destroy_all` purges the trash and nothing else and `deleted_within(30.days).really_destroy_all` purges recent trash. Bypasses callbacks via `delete_all`. |
| `restore_all` | Restores every soft-deleted record **in the current relation** and returns the Integer count (mirror of `soft_delete_all`: `RecordNotSaved` + rollback on failure, single-`UPDATE` fast path). A caller predicate on the column composes: `deleted_within(1.hour).restore_all` undoes only the last hour's deletions. |

## Examples

**Undo a bulk delete without emptying the whole trash can:**

```ruby
User.deleted_within(1.hour).restore_all          # => 42 — only rows soft-deleted in the last hour
User.where(deleted_at: from..to).restore_all     # any predicate on the column composes the same way
User.only_deleted.really_destroy_all             # purge everything in the trash, nothing live
```

`restore_all` and `really_destroy_all` peel off only the default scope's own `deleted_at IS NULL`; predicates *you* add on the column survive — even one identical to the default scope's, so `without_deleted.really_destroy_all` purges only the live rows and `without_deleted.restore_all` restores nothing — and so does any other `default_scope` the model declares (a tenant scope, say) — the `cascade:` honours a dependent's the same way. The *scopes* themselves still `unscope` the column, so put them first in a chain — `soft_deleted.where(...)` rather than `where(...).soft_deleted`.

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

- **Cascade restore matches on the exact timestamp.** The cascade hands the parent's timestamp down (`soft_delete!(at:)`), so `restore!` can tell "deleted with the post" from "deleted on its own last week" without extra columns. Give the columns sub-second precision (`t.datetime :deleted_at, precision: 6`, the Rails 7 default) if two parents may be deleted within the same second. `travel_to` in tests truncates to whole seconds — pass `at:` explicitly when asserting sub-second values.
- **Declare the `cascade:` associations before the macro.** `soft_deletable_by` resolves each name with `reflect_on_association` at class load, so a `has_many` written *below* the macro does not exist yet and you get `cascade: 'comments' is not an association of Post`. Same rule as CounterCacheable's `belongs_to`.
- **A dependent that fails to save aborts the whole cascade.** With the default `touch: true` a dependent's write runs validations; if one fails, the cascade raises `ActiveRecord::RecordNotSaved` and the transaction rolls back the parent too, rather than leaving the parent deleted and the dependent live.
- **Cascade targets resolve lazily when they must.** The association shape is validated at class load; the target model's SoftDeletable check runs at class load when the class already resolves and otherwise on the first cascade (a not-yet-loaded model cannot be resolved from inside a class body).
- **Merging keeps the outer model's soft-delete filter.** The default scope records no `unscope`, so `Comment.joins(:post).merge(Post.where(title: "x"))` keeps hiding deleted comments, on every Rails version. It used to bring them back: ActiveRecord replays a merged relation's `unscope(where: :deleted_at)` on the receiving relation, where a column name matches every table. The named scopes unscope by table (Rails 6.1+; see Scopes).
- **`default_scope` is sticky.** When `default_scope: true` (the default), every query — including joins, `includes`, and uniqueness validations — silently excludes soft-deleted rows. Uniqueness validators on other columns will not see deleted records, potentially allowing duplicates. For new models, prefer `default_scope: false` and chain `.without_deleted` explicitly.

- **`destroy_all` is silently overridden, contextually.** `Article.destroy_all` soft-deletes, and so do the relation and association forms (`Article.where(user_id: 42).destroy_all`, `Article.destroy_by(...)`, `post.comments.destroy_all`); until this fix those scoped forms reached ActiveRecord's own `Relation#destroy_all` and hard-deleted. A record that is already soft-deleted is destroyed for real only through one of that model's own trash scopes (`only_deleted`, `soft_deleted`, `deleted_within`, `with_deleted`, affixed or renamed alike, chained, merged or in an association scope): `only_deleted.destroy_all` purges the trash, while `Post.joins(:comments).merge(Comment.only_deleted).destroy_all` purges no post (the tag is per model). Every other relation, **including every relation of a `default_scope: false` model**, soft-deletes its live rows and leaves the trash untouched. The trashed set is fixed when the call starts, so a row the call itself soft-deletes (a self-referential `cascade:`, an `after_soft_delete` hook) is never purged by a later batch (as with `soft_delete_all`, a stale copy of a row a self-referential `cascade:` already trashed can be re-stamped, so its parent's `restore!` may not bring it back), and a row restored before its turn is not purged (the re-check is not a row lock: a restore committed concurrently between it and the `DELETE` is still lost). Purging a trashed parent first purges its trashed `cascade:` children, whatever their timestamp, which `dependent: :destroy` cannot see through their default scope; a cascade cycle purges each row once. A vetoed destroy (the record's own or any trashed child's, which rolls that record's purge back) is skipped on a relation and raises `RecordNotDestroyed` on an association, as Rails' `destroy!` does. Instance `destroy` is unchanged (Rails' hard delete). Prefer the explicit `.soft_delete_all`, and `really_destroy_all` to hard-delete. To keep the old hard delete for the scoped forms, declare `relation_destroy_all: :hard`.

- **Upgrading: callbacks, validations and rollback.** For live rows a scoped `destroy_all` no longer runs `before_destroy` / `after_destroy` or `after_commit on: :destroy` / `after_destroy_commit`; it runs `before_soft_delete` / `after_soft_delete` instead, and with the default `touch: true` also validations and update callbacks (`after_update_commit`). A row that fails validation (or a `before_soft_delete` veto) raises `ActiveRecord::RecordNotSaved` and rolls the batch back, where ActiveRecord's own `destroy_all` skipped the vetoed rows. On Rails 7.2+ `in_batches.destroy_all` returns `sum { |relation| relation.destroy_all.count(&:destroyed?) }`, so soft-deleted rows count as `0`.

- **Rails' own association maintenance stays hard.** `has_many :groups, through: :memberships, dependent: :destroy` on a destroyed owner, `user.groups.destroy(group)` and `user.groups.destroy_all` remove the join rows for good, even when the join model is soft-deletable, so the owner row can go. Only the single `destroy_all` Rails issues on the join model is hard: a join-model destroy callback that calls `destroy_all` on its own class soft-deletes. These forms are Rails' own and hard-delete too: `has_many ..., dependent: :destroy` (each child is destroyed), `post.comments.destroy(comment)`, `post.comments.delete(comment)` on a `dependent: :destroy` association, assigning a collection that drops records (`post.comments = [...]`) on a `dependent: :destroy` association and nested attributes with `_destroy`. Use `cascade:` or `soft_delete!` to soft-delete through an association.

- **A soft-deleted parent does not trigger `dependent: :destroy`.** Soft-deleting runs no destroy callbacks, so the children stay live. Use `soft_deletable_by ..., cascade:` to send them to the trash with their parent.

- **Upgrading: unique indexes and the trash.** Rows that used to be hard-deleted by a scoped `destroy_all` now stay in the table, so a unique index that includes soft-deleted rows blocks re-creating the record (`users.email`, a join-table pair). Use a partial index that ignores the trash: `add_index :users, :email, unique: true, where: "deleted_at IS NULL"`. To keep the old hard delete instead, use `relation_destroy_all: :hard` (or `really_destroy_all`).

- **Hook callback order is guaranteed.** `before_soft_delete` fires before the write; `after_soft_delete` fires only if the update succeeds. The same applies to `before_restore` / `after_restore`. The spec asserts the exact order `[:before_soft_delete, :after_soft_delete]` and `[:before_restore, :after_restore]`.

- **A raising or vetoing hook rolls back the timestamp.** `soft_delete!` and `restore!` run the hooks, the `update`/`update_column` call and any cascade in their own savepoint (`Support::HookedWrite`). If a hook raises, or calls `raise ActiveRecord::Rollback`, `deleted_at` is never committed. For a Rollback veto the method returns `false`. This holds inside a caller's transaction too, and `soft_delete_all` / `restore_all` then raise `ActiveRecord::RecordNotSaved` and roll back the batch. The in-memory `deleted_at` is restored, so a retry is not skipped by the `deleted?` idempotency guard.

- **`after_soft_delete` is not called on a failed update.** If `update` returns `false` (e.g. because a validation fails), `after_soft_delete` is skipped and `soft_delete!` returns `false`. Any side effects of `before_soft_delete` are rolled back too.

- **`soft_delete!` and `restore!` are idempotent.** Calling `soft_delete!` on an already-deleted record returns `true` immediately without writing to the database or running hooks. Calling `restore!` on a non-deleted record does the same.

- **`touch: false` uses `update_column`.** This bypasses ActiveRecord validations and callbacks (including `before_save`), and does not update `updated_at`. Use with care on models that have validations involving the soft-delete column.

- **`really_delete!` marks the instance destroyed and freezes it.** After calling `really_delete!`, the Ruby object reports `destroyed?` true and `persisted?` false, as after ActiveRecord's `delete`, and it is frozen, so it cannot be modified. `is_really_deleted?` returns `true`. (Before this fix the instance was only frozen and still read as `persisted?`.)

- **`really_destroy_all` peels off only the default scope's soft-delete predicate.** It honors the calling relation (`Article.where(user_id: 42).really_destroy_all` deletes only that user's rows, soft-deleted included), and a condition you put on the soft-delete column survives: `only_deleted.really_destroy_all` purges the trash and nothing else, `without_deleted.really_destroy_all` the live rows and nothing else.

- **Custom field names are fully supported.** Any `datetime` column works: `soft_deletable_by :removed_on`. All scopes and methods adapt to the configured field. Multiple models can use different field names independently — `class_attribute` ensures isolation between classes.

- **STI (Single Table Inheritance) works.** Subclasses inherit the configuration and all scopes from the parent class without additional setup.

- **Column must exist at class-load time.** `soft_deletable_by` validates the column via `ConcernsOnRails::Support::ColumnGuard#ensure_columns!` and raises `ArgumentError` with the message `"does not exist in the database"` if the column is missing. This means running the model before running migrations will fail fast rather than silently.

- **`.active` scope conflict.** `Activatable`, `Expirable` and `SoftDeletable` all define an `.active` scope. On a model that combines them, pass `prefix:`/`suffix:` to rename the scopes, or rely on `.without_deleted`.

## Changed in 1.22.0

- `really_destroy_all` now honors the calling relation (previously it hard-deleted the entire table regardless of scope).
- `soft_delete_all` / `restore_all` / `destroy_all` return Integer counts and raise `ActiveRecord::RecordNotSaved` (rolling the batch back) on failure — previously the rollback was silent and returned nil.
- With `touch: false` and no overridden hooks, the batch methods collapse to a single `UPDATE` statement. On an STI table they never do: a base-class `soft_delete_all` also writes the subclasses' rows, which may override hooks or re-declare `soft_deletable_by` (`touch:`, `cascade:`, another column), so STI tables always use the per-record path (hooks and validations run per record; slower on large STI tables).
