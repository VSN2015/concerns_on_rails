Declarative URL-parameter filtering for Rails controller index actions. `Filterable` maps incoming `params` keys to ActiveRecord query operations through a simple class-level declaration, keeping filter logic out of action bodies and eliminating repetitive `if params[:x].present?` guards. Three modes are available per filter: direct `where` equality, named scope delegation, and a custom lambda — all composable in a single `filtered` call.

## When to use it

- Filtering a resource index by status or category when query params arrive from a UI (e.g., `?status=draft&category=news`).
- Triggering a model scope (`published`, `active`, `soft_deleted`) only when a specific flag param is present (e.g., `?published=1`).
- Full-text or partial-match search via a `?q=` param without polluting the action with ad-hoc SQL.
- Building admin dashboards or API endpoints that accept multiple independent, optional filter dimensions.
- Composing `Filterable` filters with `ConcernsOnRails::Controllers::Sortable` to produce fully-parameterized, safe index queries.

## Installation

Include the module in the controller class and call `filter_by` for each filterable parameter. All three modes can be declared together.

```ruby
class ArticlesController < ApplicationController
  include ConcernsOnRails::Controllers::Filterable

  # Direct where mode — ?status=draft → Article.where(status: 'draft')
  filter_by :status, :category

  # Scope mode — ?published=1 → relation.published
  filter_by :published, scope: :published

  # Custom lambda mode — ?q=rails → rel.where("title ILIKE ?", "%rails%")
  filter_by :q, with: ->(rel, v) { rel.where("title ILIKE ?", "%#{v}%") }

  def index
    render json: filtered(Article.all)
  end
end
```

## Configuration

### `filter_by(*fields, scope: nil, with: nil)`

Declares one or more filterable URL params. Multiple fields can be batched in a single call when they share the same mode (direct `where` only — `scope:` and `with:` apply to all fields in the call).

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `*fields` | One or more `Symbol` | — (required) | The param key(s) to watch. Each becomes a key in `filterable_rules`. At least one field is required or `ArgumentError` is raised. |
| `scope:` | `Symbol` | `nil` | Name of a model scope to call (`public_send`) when the param is present and non-blank. Mutually exclusive with `with:`. |
| `with:` | `Proc` / `lambda` | `nil` | A callable with signature `(relation, value)` invoked when the param is present and non-blank. Mutually exclusive with `scope:`. |

Passing neither `scope:` nor `with:` activates **direct where mode**: `relation.where(field => value)`.

Passing **both** `scope:` and `with:` raises `ArgumentError` immediately at class load time.

## Methods

### Instance methods

#### `filtered(relation) → ActiveRecord::Relation`

Iterates over all rules declared with `filter_by`, reads the corresponding value from `params`, skips blank values, and applies the matching filter strategy. Returns the narrowed relation (or the original relation unchanged if no params are present).

```ruby
def index
  @articles = filtered(Article.all)
end
```

The method composes all active filters sequentially — each filter receives the relation returned by the previous one, so multiple params narrow the result set via `AND` semantics.

### Class methods

#### `filter_by(*fields, scope: nil, with: nil)`

Class-level DSL method that registers filtering rules. Stores rules in the `filterable_rules` class attribute (a `Hash` keyed by `Symbol`). Calling `filter_by` multiple times is additive; each call merges new rules into the existing hash.

## Examples

**Combining direct and scope filters in one controller**

```ruby
class PostsController < ApplicationController
  include ConcernsOnRails::Controllers::Filterable

  filter_by :status, :author_id          # ?status=published&author_id=42
  filter_by :featured, scope: :featured  # ?featured=1

  def index
    render json: filtered(Post.all)
  end
end
```

**Full-text search with a custom lambda**

```ruby
class ProductsController < ApplicationController
  include ConcernsOnRails::Controllers::Filterable

  filter_by :q, with: ->(rel, v) { rel.where("name ILIKE :q OR sku ILIKE :q", q: "%#{v}%") }
  filter_by :category_id

  def index
    @products = filtered(Product.active)
    render json: @products
  end
end
```

**Pairing with a Publishable scope**

```ruby
class ArticlesController < ApplicationController
  include ConcernsOnRails::Controllers::Filterable

  # Article includes ConcernsOnRails::Models::Publishable
  # and has called publishable_by :published_at, which adds .published
  filter_by :published, scope: :published

  def index
    render json: filtered(Article.all)
  end
end
# GET /articles?published=1  → Article.all.published
# GET /articles              → Article.all (unmodified)
```

## Notes & gotchas

- **Blank values are always skipped.** Both missing params and params set to an empty string (`""`) are treated identically — the filter is not applied and the relation is not narrowed. This means omitting a query parameter never unintentionally restricts results.
- **Scope mode ignores the param value.** When `scope:` is used, only the *presence* (and non-blankness) of the param matters; the actual value is discarded. Any truthy string (`"1"`, `"true"`, `"yes"`) triggers the scope equally.
- **`scope:` and `with:` are mutually exclusive per `filter_by` call.** Declaring both raises `ArgumentError` at class-load time (not at request time), so the misconfiguration is caught immediately during development or test suite startup.
- **At least one field is required.** Calling `filter_by` with no positional arguments raises `ArgumentError`.
- **Rules accumulate across multiple `filter_by` calls.** Each call merges into `filterable_rules`; later calls for the same field key overwrite earlier ones.
- **`filterable_rules` is a `class_attribute`.** Subclassing a controller that includes `Filterable` produces an independent copy of `filterable_rules` on the subclass, so subclass rules do not leak back to the parent.
- **SQL injection via `with:` lambda is the caller's responsibility.** The `with:` lambda receives the raw string value from `params`; the developer must use parameterized queries or sanitize input inside the lambda.
- **Scope mode delegates via `public_send`.** The named scope must be publicly accessible on the relation. Private or protected scopes will raise `NoMethodError` at request time.
- **Filter composition order matches declaration order.** Filters are applied in the order they appear in `filterable_rules`, which is insertion order (Ruby `Hash`). For most queries this is irrelevant, but lambda-based filters that mutate the relation in non-commutative ways should account for it.
