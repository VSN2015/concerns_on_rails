Adds cursor (keyset) pagination to any Rails controller — the constant-time complement to [Paginatable](paginatable.md)'s offset pagination. A single `cursor_paginated` helper applies a keyset `WHERE` + `LIMIT` to an ActiveRecord relation, writes standard `X-*` response headers, and hands clients an opaque cursor for the next page. **No COUNT query is ever issued**, and pages stay stable while rows are inserted or deleted concurrently.

## When to use it

- Infinite-scroll feeds and mobile timelines, where offset pagination skips or repeats rows whenever items are inserted between requests.
- Sync/export endpoints that walk an entire table — `OFFSET 1000000` scans a million rows; a keyset `WHERE` is O(page).
- Tables too large to COUNT on every request (Paginatable's `X-Total-Count` costs one COUNT per call; this concern deliberately computes no totals).
- Composing with `ConcernsOnRails::Controllers::Filterable` — `cursor_paginated` accepts any scoped relation.
- Reach for **Paginatable** instead when the UI needs page numbers, totals, or "jump to page N".

## Installation

Include the concern and, optionally, call `cursor_paginate_by` to set the ordering and page-size defaults. Without the macro, ordering defaults to the primary key ascending.

```ruby
class ArticlesController < ApplicationController
  include ConcernsOnRails::Controllers::CursorPaginatable

  cursor_paginate_by order: { created_at: :desc }, per_page: 25, max_per_page: 200

  def index
    render json: cursor_paginated(Article.all)
  end
end
```

## Configuration

### `cursor_paginate_by(order:, per_page: 25, max_per_page: 200)`

| Option | Type | Default | Description |
|---|---|---|---|
| `order` | Symbol / Array / Hash | — | Ordering columns: `:created_at`, `[:kind, :created_at]` (all ascending), or `{ created_at: :desc, kind: :asc }` for per-column directions. Columns are chosen **in code** — params can never pick them. The primary key is always appended as a tiebreaker (inheriting the last column's direction) unless you list it yourself. |
| `per_page` | Integer | `25` | Default page size when the caller supplies no `?per_page=` (or a value below 1). |
| `max_per_page` | Integer | `200` | Hard cap on `per_page` (`0`/negative disables the cap — same semantics as Paginatable). |

`order:` and `per_page:` can also be passed per call: `cursor_paginated(scope, order: { score: :desc }, per_page: 50)`.

**URL params read from `params`**

| Param | Default | Notes |
|---|---|---|
| `?cursor=` | — | The opaque token from `X-Next-Cursor`. Omit (or blank) for the first page. |
| `?per_page=` | value of `cursor_paginatable_per_page` | Values below 1 fall back to the default; values above `max_per_page` are capped. |

## Methods

### Instance methods

**`cursor_paginated(relation, order: nil, per_page: nil) → Array`**

Runs the keyset query (`LIMIT per_page + 1` to detect whether more rows exist), sets the response headers, and returns the page as a **loaded Array** (the one deliberate divergence from Paginatable — has-more detection requires materializing the rows). Accepts a relation or a bare model class. Raises `CursorPaginatable::InvalidCursor` on malformed or mismatched cursors — see below.

**`cursor_pagination_meta(relation = nil, order: nil, per_page: nil) → Hash`**

With no arguments: the meta Hash memoized by the last `cursor_paginated` call (no extra query; `nil` if that call failed or never ran). With a relation: runs the query and returns meta **without** setting headers or touching the memo — for body-based pagination composed with Respondable's `meta:`.

```ruby
{ per_page: 25, count: 25, has_more: true, next_cursor: "eyJ0IjoiYXJ0aWNsZXMiLCJvIjpb..." }
```

**`render_invalid_cursor(error)`** — public override point for the 400 body. Delegates to Respondable's `render_error` when included; otherwise renders the same `{ success: false, error: { message:, code: "invalid_cursor" } }` envelope inline.

### Response headers

| Header | Value |
|---|---|
| `X-Per-Page` | The resolved per-page value after defaults and the cap. |
| `X-Count` | Rows on **this** page — *not* Paginatable's `X-Total-Count`; totals are deliberately never computed. |
| `X-Has-More` | `"true"` / `"false"`. |
| `X-Next-Cursor` | Opaque token for the next page. Only set while more pages exist. |

### Invalid cursors → 400

Cursors are URL-safe Base64 of a JSON payload that pins the **table** and the **column:direction list** they were minted under. Decoding rejects, with `InvalidCursor`:

- malformed tokens (bad Base64, non-JSON, non-Hash payloads),
- cursors minted on another model or under a different `order:` configuration,
- tampered values (non-scalar entries, wrong value count).

On real controllers a `rescue_from InvalidCursor, with: :render_invalid_cursor` is registered automatically (exactly like ErrorHandleable's handlers), so a garbage `?cursor=` becomes a clean 400 instead of a 500. On bare objects without `rescue_from`, the error propagates.

## Examples

**Client paging loop**

```ruby
# GET /articles?per_page=20            → 20 rows, X-Next-Cursor: abc...
# GET /articles?per_page=20&cursor=abc → next 20, X-Next-Cursor: def...
# ...until X-Has-More: false (no X-Next-Cursor header on the last page)
```

**Multi-column ordering with ties**

```ruby
class LeaderboardController < ApplicationController
  include ConcernsOnRails::Controllers::CursorPaginatable

  def index
    # PK tiebreaker is appended automatically — equal scores never skip/repeat rows
    render json: cursor_paginated(Player.all, order: { score: :desc })
  end
end
```

**Body-based meta with Respondable**

```ruby
def index
  articles = Article.published
  render_success(data: cursor_paginated(articles), meta: cursor_pagination_meta)
end
```

## Notes & gotchas

- **No database columns required**, but ordering columns should be `NOT NULL`. A NULL value on a page-boundary row raises a descriptive `ArgumentError` instead of silently corrupting the walk; on NULLs-last databases (PostgreSQL ASC), NULL-valued tail rows are skipped by the strict keyset comparison without ever reaching a boundary. Use NOT NULL columns or COALESCE in a view.
- **Forward-only.** There is no `before`/previous-page support; clients keep earlier cursors to go back. The pinned payload format leaves room to add it without breaking existing cursors.
- **Cursors are readable, not secret.** The token is Base64 JSON — the boundary row's values are visible to anyone holding it. Don't order by sensitive columns (emails, balances). Tampering is detected structurally; HMAC signing is out of scope.
- **`reorder` semantics.** The keyset columns *replace* any prior ORDER BY — including a model `default_scope` order (e.g. the model Sortable concern's). Don't wrap `cursor_paginated` with the controller Sortable's `sorted` (its ordering would be silently discarded); pass `order:` per call instead.
- **Base-table columns only.** The keyset predicate is built on the model's own table; joined/qualified ordering columns are unsupported.
- **The relation must select the ordering columns** — `select(:id)` with `order: :created_at` raises when minting the next cursor.
- **Single-column primary key required.** Composite-PK (Rails 7.1+) and PK-less tables raise `ArgumentError`.
- **Changing `order:` invalidates in-flight cursors** — clients mid-walk get a 400 and restart from page 1. Intended: silently reinterpreting a cursor under a new ordering would skip or repeat rows.
- **Timestamps round-trip at microsecond precision** (ISO 8601 with 6 fractional digits, cast back through the model's attribute types so each adapter quotes natively).
- **Zero new runtime dependencies** (URL-safe Base64 via `pack("m0")`, same as WebhookVerifiable — no base64 gem needed on Ruby 3.4).
