Adds offset-based pagination to any Rails controller, exposing a single `paginated` helper method that applies `LIMIT`/`OFFSET` to an ActiveRecord relation — or slices an in-memory collection such as an `Array`, `Set` or `Range` — and writes standard `X-*` response headers. It requires no Kaminari, will_paginate, or any other pagination library — the entire implementation is self-contained.

## When to use it

- JSON API endpoints that clients consume with `?page=` and `?per_page=` query params, where response headers carry the total record count and page metadata.
- Admin list views where the default page size should differ per controller and a hard cap prevents accidental full-table dumps.
- GraphQL or REST endpoints that feed paginated tables in React, Vue, or mobile clients that read `X-Total-Count` and `X-Total-Pages` from response headers.
- Any controller that needs pagination without pulling in a full pagination gem and its view helpers.
- Controllers that compose pagination with `ConcernsOnRails::Controllers::Filterable` or `ConcernsOnRails::Controllers::Sortable` — `paginated` accepts any scoped relation.
- Endpoints whose results never touch the database — an external API response, a search-service hit list, a loaded association or a hand-built list of Structs — `paginated` slices any Enumerable and emits the identical headers, so clients cannot tell the two apart.

## Installation

Include the concern and, optionally, call `paginate_by` to override the class-level defaults. The macro call is not required; omitting it leaves both defaults in effect.

```ruby
class ArticlesController < ApplicationController
  include ConcernsOnRails::Controllers::Paginatable

  # Optional — shown with their default values:
  paginate_by per_page: 25, max_per_page: 200

  def index
    render json: paginated(Article.published.order(created_at: :desc))
  end
end
```

## Configuration

`paginate_by` is a class-level macro that sets two `class_attribute` values. Both keyword arguments are optional; any omitted argument falls back to its built-in default.

| Option | Type | Default | Description |
|---|---|---|---|
| `per_page` | Integer | `25` | Default number of records per page when the caller supplies no `?per_page=` param, or supplies a value less than 1. Coerced with `.to_i`. |
| `max_per_page` | Integer | `200` | Hard upper bound on `per_page`. Any caller-supplied value above this cap is silently reduced to this value. When set to `0` or a negative integer the cap is disabled and any requested `per_page` is honored. Coerced with `.to_i`. |
| `link_header` | Boolean | `true` | Emit the RFC 8288 `Link` header (`first`/`prev`/`next`/`last`) on every paginated response. Set `false` to send only the `X-*` headers. |
| `page_param` | Symbol/String or Array | `:page` | Where the page number is read from: a top-level param name, or an Array path into nested params (`%i[page number]` → `?page[number]=2`). Must be a name or a non-empty path of names. |
| `per_page_param` | Symbol/String or Array | `:per_page` | Same for the page size (`%i[page size]` → `?page[size]=10`). |
| `style` | `:flat` or `:jsonapi` | `:flat` | Shortcut: `:jsonapi` sets `page_param: %i[page number]` and `per_page_param: %i[page size]` (the JSON:API page-based strategy); `:flat` keeps `page` / `per_page`. Explicit `page_param:`/`per_page_param:` win over the style. |

**URL params read from `params`**

| Param | Default | Notes |
|---|---|---|
| `?page=` | `1` | Values below 1 (including negative numbers and zero) are clamped to `1`. |
| `?per_page=` | value of `paginatable_per_page` | Values below 1 fall back to the class default; values above `max_per_page` are capped. |

Both names are configurable (`page_param:` / `per_page_param:` / `style: :jsonapi`). Nested paths are read by digging through the params (`params[:page][:number]`); a non-Hash where a Hash is expected, or an Array/Hash where a scalar is expected, falls back to the default exactly like garbage in the flat form.

## Methods

### Instance methods

**`paginated(collection, total: nil) → ActiveRecord::Relation | Array`**

Applies pagination to the given collection and sets the four standard response headers. The argument is not mutated. Two kinds of input are accepted:

- **A relation** — anything that answers `limit` and `offset` (an `ActiveRecord::Relation`, an association `CollectionProxy`, a model class). The method strips `ORDER`, `LIMIT`, `OFFSET` and a custom `SELECT` before running the `COUNT` query, so pre-applied ordering does not affect the total. Returns a new relation with `LIMIT` and `OFFSET` applied; it is not yet evaluated (lazy).
- **An in-memory collection** — any other non-`Hash` `Enumerable` (`Array`, `Set`, `Range`, `Enumerator`, …). It is materialized once with `to_a` (so an `Enumerator` is consumed a single time for both the count and the slice), the total is its size, and the current page is returned as an `Array` — `[]` when the requested page is past the end.

A `Hash` is rejected with an `ArgumentError` rather than silently paginated as `[key, value]` pairs (call `.to_a` if that is what you mean); `nil` and non-collections (a String, an Integer) raise the same error, naming the class received.

**`total:`** — the collection is already the current page (an external API or search service returned page N of a set it counted for you). Nothing is sliced, limited or counted: an Array comes back as the same Array, a relation is not given `LIMIT`/`OFFSET`, no `COUNT` runs, and `total` drives `X-Total-Count`, `X-Total-Pages` and the `Link` header. Must be a non-negative Integer (`ArgumentError` otherwise). Request the same `page`/`per_page` upstream that this controller reads.

**`pagination_meta(collection = nil, total: nil) → Hash`**

Returns `{ total:, page:, per_page:, total_pages: }` **without** applying `LIMIT`/`OFFSET` or slicing — handy for body-based pagination composed with `Respondable`'s `meta:`. Called with no argument after `paginated`, it reuses that call's memoized metadata (no second `COUNT`); pass a relation or collection to compute fresh. Accepts exactly the same inputs as `paginated`; with `total:` the `COUNT` is skipped and the collection may be omitted entirely (`pagination_meta(total: result.total_hits)`).

The four `X-*` headers set on `response`:

| Header | Value |
|---|---|
| `X-Total-Count` | Total number of records in the un-paginated relation (integer, as string). |
| `X-Page` | The resolved current page number (always >= 1). |
| `X-Per-Page` | The resolved per-page value after applying defaults and the cap. |
| `X-Total-Pages` | `ceil(total / per_page)`. Returns `"0"` when the relation is empty. |
| `Link` | RFC 8288 web links: `<…?page=1>; rel="first", <…?page=1>; rel="prev", <…?page=3>; rel="next", <…?page=5>; rel="last"`. URLs are the current request's base URL + path with the page param replaced — under the configured name, nested ones encoded by Rack (`page%5Bnumber%5D=3`) with the rest of that nested Hash (`page[size]`) preserved — and every other query param kept. `prev`/`next` appear only when such a page exists (past the end, `prev` points at the last page). Not emitted for an empty collection, when `link_header: false`, or when the controller has no request. Appended to an existing `Link` header, never replacing it. |

## Examples

**Basic JSON API endpoint**

```ruby
class PostsController < ApplicationController
  include ConcernsOnRails::Controllers::Paginatable

  paginate_by per_page: 20, max_per_page: 100

  def index
    render json: paginated(Post.order(:created_at))
  end
end
# GET /posts?page=2&per_page=20
# Response headers:
#   X-Total-Count: 87
#   X-Page: 2
#   X-Per-Page: 20
#   X-Total-Pages: 5
```

**Paginating an in-memory collection**

```ruby
class CatalogController < ApplicationController
  include ConcernsOnRails::Controllers::Paginatable
  include ConcernsOnRails::Controllers::Respondable

  def search
    hits = ExternalCatalog.search(params[:q])          # a plain Array from a third-party API
    render_success(data: paginated(hits), meta: pagination_meta)
  end
end
# GET /catalog/search?q=lamp&page=2&per_page=10
# => data holds hits[10, 10]; meta and the X-* headers describe all of `hits`
```

**Combining with filtering and sorting**

```ruby
class ProductsController < ApplicationController
  include ConcernsOnRails::Controllers::Paginatable

  def index
    scope = Product.where(active: true).order(name: :asc)
    render json: paginated(scope)
  end
end
```

**Controller subclass overriding defaults**

```ruby
# ApplicationController carries the gem's built-in defaults (25/200).
class ApplicationController < ActionController::API
  include ConcernsOnRails::Controllers::Paginatable
end

# This subclass overrides them for its own actions only.
class ReportsController < ApplicationController
  paginate_by per_page: 50, max_per_page: 500

  def index
    render json: paginated(Report.all)
  end
end
```

**JSON:API page-based pagination**

```ruby
class Api::ArticlesController < ApplicationController
  include ConcernsOnRails::Controllers::Paginatable

  paginate_by style: :jsonapi, per_page: 20, max_per_page: 100

  def index
    articles = paginated(Article.order(:id))
    render json: { data: articles, meta: pagination_meta }
  end
end

# GET /api/articles?page[number]=2&page[size]=10&filter[state]=live
# X-Page: 2   X-Per-Page: 10
# Link: <…?page%5Bnumber%5D=1&page%5Bsize%5D=10&filter%5Bstate%5D=live>; rel="first",
#       <…?page%5Bnumber%5D=1…>; rel="prev", <…?page%5Bnumber%5D=3…>; rel="next", <…?page%5Bnumber%5D=9…>; rel="last"
```

## Notes & gotchas

- **`Link` header is on by default.** Every non-empty paginated response carries `first`/`prev`/`next`/`last` links built from `request.base_url + request.path` and the current query string — behind a proxy, make sure `X-Forwarded-Host`/`-Proto` reach Rails (`config.action_dispatch.trusted_proxies`) or the links will name the internal host. `paginate_by link_header: false` disables it; the `X-*` headers are unaffected.
- **`Link` is appended, not set.** If Deprecatable (or a CDN hint) already put a `Link` header on the response, the pagination links are appended after it with a comma.
- **No database columns required.** This is a pure controller concern with no model-layer dependency.
- **In-memory collections are sliced in Ruby.** The whole collection is already in memory by definition, so `paginated(array)` costs one `to_a` plus an `Array#[]` — there is no lazy path. If the data lives in a table, pass the relation so the database does the work.
- **Relation detection is duck-typed.** Anything answering `limit` and `offset` takes the SQL path; that includes association proxies and model classes, and keeps a `has_many` collection paginating in the database rather than loading it.
- **Headers require a live `response` object.** The `set_pagination_headers` method guards with `respond_to?(:response) && response`. In plain unit tests without a real HTTP response object, headers are silently skipped; the return value (the paginated relation) is still correct.
- **Page clamping is one-directional.** Values below 1 are raised to 1, but there is no upper bound on `page`. Requesting a page far beyond the last page returns an empty relation and still sets all headers correctly, including the real `X-Total-Count`.
- **`max_per_page: 0` (or any non-positive value) disables the cap.** The guard `cap.positive? ? [requested, cap].min : requested` means a zero or negative `max_per_page` lets any caller-requested value through unchecked.
- **`paginate_by` is inherited.** Because `paginatable_per_page` and `paginatable_max_per_page` are `class_attribute` values, a call to `paginate_by` in a parent controller is inherited by all subcontrollers unless they call `paginate_by` themselves.
- **`COUNT` strips ordering.** The total-count query calls `.except(:order, :limit, :offset)` before `.count`, so pre-applied `ORDER BY` clauses on the relation do not produce an extra subquery or count error.
- **Integer coercion.** Both `per_page` and `max_per_page` arguments to `paginate_by` are coerced with `.to_i`. Passing a string (e.g., from an env variable) is safe. Similarly, `params[:page]` and `params[:per_page]` are coerced with `.to_i`, so string params from query strings work without manual conversion.
- **No Kaminari or will_paginate dependency.** There is no gem dependency beyond `active_support/concern`. The concern implements LIMIT/OFFSET arithmetic directly.

## Changed in 1.22.0

- `?page[]=1` / `?per_page[x]=5` no longer raise — untrusted params are coerced through the shared `Support::ScalarParam` and fall back to defaults.
- `pagination_meta` can now be called with no argument after `paginated` to reuse its memoized metadata — the records+meta composition previously ran the identical COUNT twice per request.
- The COUNT strips a custom `SELECT` list and uses `count(:all)`, so `.select(...)`/`.distinct` relations no longer produce invalid SQL or skewed totals.
