The `CounterCacheable` concern adds **conditional, denormalized association counters** to any ActiveRecord model — "counter_culture-lite". Declared on the **child**, it keeps one or many columns on the parent in sync as children are created, destroyed, and updated. Unlike Rails' built-in `belongs_to ..., counter_cache: true` — which maintains exactly one column counting *every* child and has no repair path — each counter can carry an `if:` condition (so `approved_comments_count` can live beside `comments_count`), and `recount_counter_caches!` rebuilds any counter from scratch.

## When to use it

- A `posts.comments_count` you read on an index page and can't afford an N+1 `COUNT(*)` for.
- A conditional counter Rails can't express natively — `approved_comments_count`, `published_posts_count`, `paid_invoices_count` — kept next to the unconditional total.
- After a data backfill, a `counter_cache`-less import, or any `update_all`/raw-SQL write, you need to **reconcile** the cached counts.
- A "posts by this author" badge that should also bump the author's `updated_at` for cache invalidation (`touch: true`).

## Installation

Declare the `belongs_to` **first**, then the macro (the reflection is validated at declaration time). The fully-qualified alias `ConcernsOnRails::Models::CounterCacheable` resolves to the same module.

```ruby
class Comment < ApplicationRecord
  include ConcernsOnRails::CounterCacheable

  belongs_to :post
  belongs_to :author, class_name: "User"

  counter_cacheable_by :post                                          # posts.comments_count
  counter_cacheable_by :post, count: :approved_comments_count, if: -> { approved? }
  counter_cacheable_by :author, count: :posts_count, touch: true
end
```

## Database columns

Each counter is an integer column on the **parent** table (a default of `0` keeps reads clean; the SQL uses `COALESCE`, so `NULL` also works). The child's foreign key is your existing `belongs_to` column.

```ruby
class AddCommentCountersToPosts < ActiveRecord::Migration[7.1]
  def change
    add_column :posts, :comments_count,          :integer, default: 0, null: false
    add_column :posts, :approved_comments_count, :integer, default: 0, null: false
  end
end
```

## Configuration

### `counter_cacheable_by(association, count: nil, if: nil, touch: false)`

Repeatable — each call maintains another counter. Rules accumulate (reassigned, never mutated, so subclasses inherit). All errors raise `ArgumentError` at declaration time.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `association` | `Symbol` | — (required) | A non-polymorphic `belongs_to`, declared **before** this macro. |
| `count:` | `Symbol` | `"<table_name>_count"` | The integer column on the parent table (e.g. `comments` → `comments_count`). Validated to exist when the parent class is loadable. |
| `if:` | callable or `nil` | `nil` | Evaluated with `instance_exec` on the record; the record counts only when it returns truthy. For updates the **previous** state is reconstructed from the changed attributes. |
| `touch:` | `true` / `false` | `false` | Also bump the parent's `updated_at` when the counter changes. |

### `recount_counter_caches!(association = nil, parents: <every parent>)`

Class method. Recomputes every counter (or only those for one association) from scratch and returns `{ count_column => parents_with_a_nonzero_count }`. Portable across adapters: unconditional counters use `group(fk).count`, conditional counters tally in Ruby.

`parents:` limits the repair to specific parents — ids, records, or a relation of the parent class (`Post.where(...)`) — which are zeroed and re-tallied while every other row is left untouched. A listed parent with no matching children ends at `0`; an empty list/relation is a no-op returning `0` per column. Because the ids belong to one parent table, `parents:` needs the `association` argument when the child declares counters for more than one association (`ArgumentError` otherwise), and records or a relation of a different class are rejected with `ArgumentError` rather than zeroing whichever rows happen to share those ids. So is an `association` no counter was declared for, and an explicit `parents: nil` — omit the option to repair every parent, rather than have a typo or an empty `find_by` silently widen a scoped repair into a full-table rewrite.

The repair runs in one transaction, and a scoped one **locks the listed parent rows** (`SELECT … FOR UPDATE` where the adapter supports it) before tallying their children, so a child inserted concurrently is either counted or waits for the rewrite instead of being dropped between the tally and the zeroing. A bare call can't lock the whole table, which is why it stays an offline operation.

| Call | Cost | Use |
|---|---|---|
| `Comment.recount_counter_caches!` | O(all children) — rewrites every parent | offline backfill / drift audit |
| `Comment.recount_counter_caches!(:post)` | same, one association | offline |
| `Comment.recount_counter_caches!(:post, parents: post)` | O(that post's children) | after an import, a `delete_all`, a merge — safe in a job or request |

## How updates are handled

Counters are adjusted with `update_counters` — a single atomic SQL `COALESCE(col, 0) ± 1` — in `after_create` / `after_update` and, for a destroy, right after the `DELETE` (as Rails' native counter cache does), inside the record's own transaction. On update, the full matrix is resolved:

- **Foreign-key reparent** (`post_id` changed): the old parent is decremented, the new parent incremented.
- **Condition flip** (`if:` result changed): incremented or decremented in place.
- **Both at once**: composed (old parent loses it if it counted, new parent gains it if it counts now).
- **No-op save**: nothing is written.

On destroy:

- **Only a row that was actually deleted is decremented.** Destroying a stale second instance of an already-destroyed row (the `DELETE` matched 0 rows), or a never-saved record, writes nothing.
- **The persisted values decide.** The parent and the `if:` verdict come from the database values, so an unsaved reparent (`comment.post = other; comment.destroy`) or condition flip can't redirect the decrement.
- **The parent destroying its children is not decremented.** When the child is destroyed through the parent's own `has_many ..., dependent: :destroy` on the same foreign key, that parent row is about to be deleted — as with Rails' native counter cache the decrement is skipped (bumping it first would also bump `lock_version` and fail the parent's own DELETE with `StaleObjectError`). Counters on the child's other associations still decrement. A `has_one ..., dependent: :destroy` **replacement** (assigning a new record destroys the old one while the parent stays) does decrement.
- **Remaining `lock_version` caveats (pre-existing, not new).** With optimistic locking on the parent, two paths still bump the parent before its own DELETE and can raise `StaleObjectError`: destroying a parent whose counted child sits behind a `has_one ..., dependent: :destroy` (indistinguishable here from a replacement, which must decrement), and a `has_many :through ..., dependent: :destroy`, where Rails deletes the join rows without setting `destroyed_by_association`. Destroy those children first, then reload and destroy the parent.

## Examples

```ruby
post = Post.create!
Comment.create!(post: post, approved: false)
post.reload.comments_count          # => 1
post.approved_comments_count        # => 0

comment = Comment.create!(post: post, approved: true)
post.reload.approved_comments_count # => 1

comment.update!(approved: false)    # condition flip
post.reload.approved_comments_count # => 0

comment.update!(post: other_post)   # reparent
post.reload.comments_count          # => 1
other_post.reload.comments_count    # => 1

# Repair after a counter_cache-less write:
Comment.delete_all                  # skips callbacks
Comment.recount_counter_caches!     # => { comments_count: 0, approved_comments_count: 0 }

# Repair just the parents you touched — e.g. after importing comments for a few posts:
Comment.where(post_id: imported_ids).insert_all(rows)                 # bulk insert, no callbacks
Comment.recount_counter_caches!(:post, parents: imported_ids)         # => { comments_count: 3, approved_comments_count: 1 }
Comment.recount_counter_caches!(:post, parents: Post.where(author: me))
```

## Notes & gotchas

- **Declare `belongs_to` first.** The reflection is validated when the macro runs; a missing association raises with a hint. Polymorphic associations are **not supported** in this version.
- **Don't combine with native `counter_cache: true`** on the same column — both would fire and the counter would double.
- **Counters track the persisted record.** Writes that skip callbacks — `update_column(s)`, `update_all`, `delete`, raw SQL — leave the cache stale; run `recount_counter_caches!` to reconcile.
- **Transaction-consistent.** Because the adjustment runs inside the save transaction, a rolled-back save rolls back the counter too.
- **`if:` should read the record's own columns.** The previous-state reconstruction restores the changed attributes, not the associations.
- **Bare `recount_counter_caches!` rewrites every parent** (zeroes the column, then applies the tally) and scans children in Ruby for conditional counters — portable, but O(n). Treat it as a maintenance task, not a request-path call. **`parents:` scopes both the zeroing and the tally** to the listed ids and locks those rows first, so it is proportional to their children and fine to run inline after a bulk write.
- **`belongs_to ..., primary_key:` is honoured.** Parents are addressed by the association key (`primary_key: :code` → `WHERE code = ?`), never by `id` — by the live adjustments and by `recount_counter_caches!` alike. `parents:` still takes records, relations or primary-key ids. `has_many :through` rollups are out of scope — reach for [`counter_culture`](https://github.com/magnusvk/counter_culture) when you need multi-level rollups, delta columns, or after-commit execution.

## Changed in 1.22.0

- `recount_counter_caches!` runs in a transaction (a crash mid-repair can no longer leave every counter zeroed) and groups parents by tally value — O(distinct counts) UPDATE statements instead of one per parent row.
- `touch: true` raises at macro time on Rails < 6.0, where `update_counters` lacks the option.
