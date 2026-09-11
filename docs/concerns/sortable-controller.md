`ConcernsOnRails::Controllers::Sortable` adds URL-parameter-driven ordering to Rails controller index actions. It maintains a strict allow-list of permitted sort keys so that arbitrary user-supplied values — including SQL injection attempts — are silently rejected and fall back to a safe default, rather than being interpolated into a query. Keys can carry a per-column direction (`?sort=-created_at,title`), point at an association's column through a join, and pin `NULLS FIRST`/`NULLS LAST`.

## When to use it

- An index action exposes a sortable table or list and the front end sends `?sort=-created_at,title` (JSON:API style) or `?sort=title&direction=asc` query parameters.
- An API endpoint must support multiple sort orders without exposing every column name as a valid sort target.
- A list needs to sort by a column on an associated table ("by author name") without hand-writing the join in every action.
- Nullable columns (a `price`, a `published_at`) must sort with the blanks at the end regardless of direction.
- You want to protect against SQL injection via sort parameters without writing the guard logic by hand in every controller.
- You need to coexist with `ConcernsOnRails::Models::Sortable` (which manages persisted list position via `acts_as_list`) on a resource that also needs ad-hoc URL-driven ordering in its controller.

## Installation

Include the module in any controller and call `sortable_by` once to declare the allow-list and defaults. Then call `sorted` inside your action, passing the relation to order.

```ruby
class ArticlesController < ApplicationController
  include ConcernsOnRails::Controllers::Sortable

  sortable_by :created_at, :title, :published_at,
              author: { column: "authors.name", joins: :author },
              price:  { nulls: :last },
              default: :created_at, direction: :desc

  def index
    render json: sorted(Article.all)
  end
end
```

## Configuration

`sortable_by` is the sole configuration macro. It must be called at least once; omitting every field raises `ArgumentError`.

```
sortable_by(*allowed_fields, default: nil, direction: :asc, **rules)
```

| Option | Type | Default | Description |
|---|---|---|---|
| `*allowed_fields` | `Symbol` / `String` positional arguments | — | Plain sort keys: each sorts by the column of the same name on the relation's own table. |
| `**rules` | `key: { column:, joins:, join:, nulls: }` | — | Sort keys with a rule (see below). At least one plain field or rule must be supplied or `ArgumentError` is raised. |
| `default:` | `Symbol` or `String` | First declared key | The key used when `params[:sort]` is absent or contains no allow-listed key. Must be a declared key, or `ArgumentError` is raised. |
| `direction:` | `:asc` or `:desc` | `:asc` | The direction used for un-prefixed keys when `params[:direction]` is absent or invalid. Any other value is silently coerced to `:asc`. |

### Rule options

| Option | Type | Default | Description |
|---|---|---|---|
| `column:` | `Symbol` or `"table.column"` `String` | the key | A Symbol names a column on the relation's own table; a qualified String names a column on a joined table. The String must match `identifier.identifier` — anything else (spaces, punctuation, raw SQL) raises `ArgumentError` at class load. Both parts are quoted with the connection's identifier quoting. |
| `joins:` | anything `left_outer_joins` / `joins` accepts | `nil` | Association(s) to join **only when this key is requested**: `:author`, `[:author, :category]`, `{ author: :profile }`. |
| `join:` | `:left` or `:inner` | `:left` | `:left` uses `left_outer_joins` (rows without the association are kept and sort as `NULL`); `:inner` uses `joins` (those rows are dropped). |
| `nulls:` | `:first` or `:last` | `nil` | Appends `NULLS FIRST` / `NULLS LAST` to the `ORDER BY` term through Arel (Rails 6.1+) on PostgreSQL and SQLite. MySQL/MariaDB have no such syntax, so an equivalent leading `CASE WHEN col IS NULL` term is emitted there instead — the ordering is the same on every adapter. |

## Request parameters

- **`params[:sort]`** — comma-separated sort keys in priority order. Each key may be prefixed with `-` (descending) or `+` (ascending): `?sort=-created_at,title`. Un-prefixed keys take `params[:direction]`, then the configured default direction. Keys not in the allow-list are dropped; when nothing valid remains the `default:` key is used with the fallback direction.
- **`params[:direction]`** — `asc` / `desc`, case-insensitive. Applies to every un-prefixed key. Invalid values fall back to the declared default direction.

## Methods

### Class attributes

- `sortable_allowed_fields` — the declared keys, in declaration order (plain fields first, then rules).
- `sortable_rules` — `{ key => { column:, joins:, join:, nulls: } }` after normalisation (plain fields become `{ column: key, joins: nil, join: :left, nulls: nil }`).
- `sortable_default_field` / `sortable_default_direction`.

### Instance methods

**`sorted(relation)`**

Applies the requested joins and then `reorder`s the given `ActiveRecord::Relation` with one Arel ordering node per requested key. Because it uses `reorder` (not `order`), the requested columns **replace** any `ORDER BY` the relation already carried — including a model `default_scope` order. Returns the relation unchanged when nothing is requested and no default is configured (i.e. `sortable_by` was never called).

```ruby
def index
  @articles = sorted(Article.all)
end
```

Private helpers (not public API, but overridable in a subclass):

- `sort_requests` — `[[key, :asc | :desc], ...]` parsed from `params[:sort]`, allow-listed, with the per-key direction resolved.
- `sort_fields` — the keys from `sort_requests` (kept for subclasses that relied on it).
- `sort_direction` — the fallback direction from `params[:direction]` / the configured default.

## Examples

**Per-column directions (JSON:API style)**

```ruby
class PostsController < ApplicationController
  include ConcernsOnRails::Controllers::Sortable

  sortable_by :created_at, :title, :updated_at,
              default: :created_at, direction: :desc

  def index
    render json: sorted(Post.published)
  end
end

# GET /posts                          → ORDER BY created_at DESC (defaults)
# GET /posts?sort=-title,created_at   → ORDER BY title DESC, created_at DESC   (bare key → default direction)
# GET /posts?sort=title,created_at&direction=asc → ORDER BY title ASC, created_at ASC
# GET /posts?sort=+title&direction=desc → ORDER BY title ASC                  (prefix wins over params[:direction])
# GET /posts?sort=body                → ORDER BY created_at DESC (body not allow-listed)
```

**Sorting by an association column**

```ruby
class ArticlesController < ApplicationController
  include ConcernsOnRails::Controllers::Sortable

  sortable_by :created_at,
              author: { column: "authors.name", joins: :author },
              category: { column: "categories.name", joins: :category, join: :inner }

  def index
    render json: sorted(Article.all)
  end
end

# GET /articles?sort=author    → LEFT OUTER JOIN authors … ORDER BY "authors"."name" ASC
#                                (articles without an author are kept — they sort as NULL)
# GET /articles?sort=-category → INNER JOIN categories … ORDER BY "categories"."name" DESC
#                                (uncategorised articles are dropped)
# GET /articles?sort=created_at → no join at all
```

**Pinning NULLs**

```ruby
class ProductsController < ApplicationController
  include ConcernsOnRails::Controllers::Sortable

  sortable_by :name, price: { nulls: :last }, discontinued_at: { nulls: :first }

  def index
    render json: sorted(Product.all)
  end
end

# GET /products?sort=price   → ORDER BY "products"."price" ASC NULLS LAST
# GET /products?sort=-price  → ORDER BY "products"."price" DESC NULLS LAST
```

**Combining with pagination**

```ruby
class UsersController < ApplicationController
  include ConcernsOnRails::Controllers::Sortable
  include ConcernsOnRails::Controllers::Paginatable

  sortable_by :last_name, :email, :created_at, default: :last_name

  def index
    render json: paginated(sorted(User.active))
  end
end
```

## Notes & gotchas

- **`sortable_by` must be called.** If the macro is never invoked, `sortable_default_field` remains `nil`. In that case `sorted` returns the relation unmodified — no ordering is applied and no error is raised.
- **Declarations are validated at class load.** An unknown rule option, a `column:` String that is not `table.column`, a `nulls:` other than `:first`/`:last`, a `join:` other than `:left`/`:inner`, or a `default:` that is not a declared key all raise `ArgumentError` with a message naming the offending key.
- **`params[:direction]` is case-insensitive** and only affects un-prefixed keys; a `-`/`+` prefix always wins for its own key.
- **Non-whitelisted `params[:sort]` values fall back silently.** SQL injection payloads such as `"-title; DROP TABLE articles;--"` are dropped as a whole token (the key `title; DROP TABLE articles;--` is not allow-listed); the default key is used instead. No error or warning is raised.
- **Joins are lazy.** An association join is added to the relation only when its key appears in the request, so the common no-sort path stays a single-table query. A LEFT OUTER JOIN can duplicate rows when the association is `has_many`; use `belongs_to`/`has_one` targets or `distinct` the relation yourself.
- **`nulls:` needs Rails 6.1+.** The macro raises at class load on older Rails (Arel ordering nodes lack `nulls_first`/`nulls_last`). MySQL/MariaDB have no `NULLS FIRST`/`NULLS LAST` syntax, so the concern emits a leading `CASE WHEN col IS NULL THEN 1 ELSE 0 END` term there and the column ordering follows it — you get the same row order without writing adapter-specific SQL yourself.
- **The allow-list is stored as `class_attribute`.** Subclassing a controller and calling `sortable_by` again on the subclass creates an independent allow-list without affecting the parent.
- **`sorted` wraps `ActiveRecord::Relation#reorder`.** It replaces any `ORDER BY` already on the relation, including a model `default_scope` order. Append a tiebreaker (`sorted(scope).order(:id)`) after it if you need deterministic pagination.
- **No database columns or migrations are required.** The concern reads only `params`; column names in the allow-list must exist, but the concern does not check the schema at load time.
- **Not the same as `ConcernsOnRails::Models::Sortable`.** The model concern integrates `acts_as_list` for persistent positional ordering. Both can coexist.
