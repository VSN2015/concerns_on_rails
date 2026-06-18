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

### `recount_counter_caches!(association = nil)`

Class method. Recomputes every counter (or only those for one association) from scratch and returns `{ count_column => parents_with_a_nonzero_count }`. Portable across adapters: unconditional counters use `group(fk).count`, conditional counters tally in Ruby.

## How updates are handled

Counters are adjusted with `update_counters` — a single atomic SQL `COALESCE(col, 0) ± 1` — in `after_create` / `after_update` / `after_destroy`, inside the record's own save transaction. On update, the full matrix is resolved:

- **Foreign-key reparent** (`post_id` changed): the old parent is decremented, the new parent incremented.
- **Condition flip** (`if:` result changed): incremented or decremented in place.
- **Both at once**: composed (old parent loses it if it counted, new parent gains it if it counts now).
- **No-op save**: nothing is written.

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
```

## Notes & gotchas

- **Declare `belongs_to` first.** The reflection is validated when the macro runs; a missing association raises with a hint. Polymorphic associations are **not supported** in this version.
- **Don't combine with native `counter_cache: true`** on the same column — both would fire and the counter would double.
- **Counters track the persisted record.** Writes that skip callbacks — `update_column(s)`, `update_all`, `delete`, raw SQL — leave the cache stale; run `recount_counter_caches!` to reconcile.
- **Transaction-consistent.** Because the adjustment runs inside the save transaction, a rolled-back save rolls back the counter too.
- **`if:` should read the record's own columns.** The previous-state reconstruction restores the changed attributes, not the associations.
- **`recount_counter_caches!` rewrites every parent** (zeroes the column, then applies the tally) and scans children in Ruby for conditional counters — portable, but O(n). Treat it as a maintenance task, not a request-path call.
- **Standard primary keys assumed.** Custom-`primary_key` parents and `has_many :through` rollups are out of scope — reach for [`counter_culture`](https://github.com/magnusvk/counter_culture) when you need multi-level rollups, delta columns, or after-commit execution.
