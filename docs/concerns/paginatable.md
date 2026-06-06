Adds offset-based pagination to any Rails controller, exposing a single `paginated` helper method that applies `LIMIT`/`OFFSET` to an ActiveRecord relation and writes standard `X-*` response headers. It requires no Kaminari, will_paginate, or any other pagination library — the entire implementation is self-contained.

## When to use it

- JSON API endpoints that clients consume with `?page=` and `?per_page=` query params, where response headers carry the total record count and page metadata.
- Admin list views where the default page size should differ per controller and a hard cap prevents accidental full-table dumps.
- GraphQL or REST endpoints that feed paginated tables in React, Vue, or mobile clients that read `X-Total-Count` and `X-Total-Pages` from response headers.
- Any controller that needs pagination without pulling in a full pagination gem and its view helpers.
- Controllers that compose pagination with `ConcernsOnRails::Controllers::Filterable` or `ConcernsOnRails::Controllers::Sortable` — `paginated` accepts any scoped relation.

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

**URL params read from `params`**

| Param | Default | Notes |
|---|---|---|
| `?page=` | `1` | Values below 1 (including negative numbers and zero) are clamped to `1`. |
| `?per_page=` | value of `paginatable_per_page` | Values below 1 fall back to the class default; values above `max_per_page` are capped. |

## Methods

### Instance methods

**`paginated(relation) → ActiveRecord::Relation`**

Applies pagination to the given relation and sets the four standard response headers. The `relation` argument can be any ActiveRecord relation or scope — it is not mutated. The method strips `ORDER`, `LIMIT`, and `OFFSET` clauses before running the `COUNT` query, so pre-applied ordering does not affect the total count. Returns the paginated relation (a new relation object with `LIMIT` and `OFFSET` applied); the relation is not yet evaluated (lazy).

The four `X-*` headers set on `response`:

| Header | Value |
|---|---|
| `X-Total-Count` | Total number of records in the un-paginated relation (integer, as string). |
| `X-Page` | The resolved current page number (always >= 1). |
| `X-Per-Page` | The resolved per-page value after applying defaults and the cap. |
| `X-Total-Pages` | `ceil(total / per_page)`. Returns `"0"` when the relation is empty. |

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

## Notes & gotchas

- **No database columns required.** This is a pure controller concern with no model-layer dependency.
- **Headers require a live `response` object.** The `set_pagination_headers` method guards with `respond_to?(:response) && response`. In plain unit tests without a real HTTP response object, headers are silently skipped; the return value (the paginated relation) is still correct.
- **Page clamping is one-directional.** Values below 1 are raised to 1, but there is no upper bound on `page`. Requesting a page far beyond the last page returns an empty relation and still sets all headers correctly, including the real `X-Total-Count`.
- **`max_per_page: 0` (or any non-positive value) disables the cap.** The guard `cap.positive? ? [requested, cap].min : requested` means a zero or negative `max_per_page` lets any caller-requested value through unchecked.
- **`paginate_by` is inherited.** Because `paginatable_per_page` and `paginatable_max_per_page` are `class_attribute` values, a call to `paginate_by` in a parent controller is inherited by all subcontrollers unless they call `paginate_by` themselves.
- **`COUNT` strips ordering.** The total-count query calls `.except(:order, :limit, :offset)` before `.count`, so pre-applied `ORDER BY` clauses on the relation do not produce an extra subquery or count error.
- **Integer coercion.** Both `per_page` and `max_per_page` arguments to `paginate_by` are coerced with `.to_i`. Passing a string (e.g., from an env variable) is safe. Similarly, `params[:page]` and `params[:per_page]` are coerced with `.to_i`, so string params from query strings work without manual conversion.
- **No Kaminari or will_paginate dependency.** There is no gem dependency beyond `active_support/concern`. The concern implements LIMIT/OFFSET arithmetic directly.
