`ConcernsOnRails::Controllers::Sortable` adds URL-parameter-driven ordering to Rails controller index actions. It maintains a strict allow-list of permitted sort columns so that arbitrary user-supplied values — including SQL injection attempts — are silently rejected and fall back to a safe default, rather than being interpolated into a query.

## When to use it

- An index action exposes a sortable table or list and the front end sends `?sort=title&direction=asc` query parameters.
- An API endpoint must support multiple sort orders without exposing every column name as a valid sort target.
- You want to protect against SQL injection via sort parameters without writing the guard logic by hand in every controller.
- Multiple controllers share the same allow-list pattern and you want consistent fallback behaviour without duplication.
- You need to coexist with `ConcernsOnRails::Models::Sortable` (which manages persisted list position via `acts_as_list`) on a resource that also needs ad-hoc URL-driven ordering in its controller.

## Installation

Include the module in any controller and call `sortable_by` once to declare the allow-list and defaults. Then call `sorted` inside your action, passing the relation to order.

```ruby
class ArticlesController < ApplicationController
  include ConcernsOnRails::Controllers::Sortable

  sortable_by :created_at, :title, :published_at,
              default: :created_at, direction: :desc

  def index
    render json: sorted(Article.all)
  end
end
```

## Configuration

`sortable_by` is the sole configuration macro. It must be called at least once; omitting all positional arguments raises `ArgumentError`.

```
sortable_by(*allowed_fields, default: nil, direction: :asc)
```

| Option | Type | Default | Description |
|---|---|---|---|
| `*allowed_fields` | One or more `Symbol` or `String` positional arguments | — (required) | The exhaustive allow-list of column names that `params[:sort]` may reference. Any value not in this list is silently rejected. At least one field must be supplied or `ArgumentError` is raised. |
| `default:` | `Symbol` or `String` | First field in `allowed_fields` | The column used when `params[:sort]` is absent or not whitelisted. When omitted, the first positional argument becomes the default. |
| `direction:` | `:asc` or `:desc` | `:asc` | The sort direction used when `params[:direction]` is absent or invalid. Any value other than `:asc` / `:desc` is silently coerced to `:asc`. |

## Methods

### Instance methods

**`sorted(relation)`**

Applies `ORDER BY` to the given `ActiveRecord::Relation` based on the current request's `params[:sort]` and `params[:direction]`. Returns the relation unchanged (without an `ORDER BY` clause) when no default field has been configured (i.e., `sortable_by` was never called). The method is public and is intended to be called directly from action methods.

```ruby
def index
  @articles = sorted(Article.all)
end
```

The two private helper methods that `sorted` delegates to are not part of the public API:

- `sort_field` — resolves `params[:sort]` against the allow-list, returning the default when the param is missing or not whitelisted.
- `sort_direction` — resolves `params[:direction]`, normalising the value to lowercase before checking against `[:asc, :desc]`, returning the configured default direction when the value is invalid.

## Examples

**Basic descending-by-date default with optional title sort**

```ruby
class PostsController < ApplicationController
  include ConcernsOnRails::Controllers::Sortable

  sortable_by :created_at, :title, :updated_at,
              default: :created_at, direction: :desc

  def index
    @posts = sorted(Post.published)
    render json: @posts
  end
end

# GET /posts             → ORDER BY created_at DESC (defaults)
# GET /posts?sort=title&direction=asc  → ORDER BY title ASC
# GET /posts?sort=body   → ORDER BY created_at DESC (body not whitelisted)
```

**First declared field becomes the default when :default is omitted**

```ruby
class ProductsController < ApplicationController
  include ConcernsOnRails::Controllers::Sortable

  sortable_by :name, :price, :stock_count
  # default field: :name, default direction: :asc

  def index
    render json: sorted(Product.all)
  end
end

# GET /products                        → ORDER BY name ASC
# GET /products?sort=price&direction=desc → ORDER BY price DESC
```

**Combining with scopes and pagination**

```ruby
class UsersController < ApplicationController
  include ConcernsOnRails::Controllers::Sortable

  sortable_by :last_name, :email, :created_at, default: :last_name

  def index
    @users = sorted(User.active).page(params[:page])
    render json: @users
  end
end
```

## Notes & gotchas

- **`sortable_by` must be called.** If the macro is never invoked, `sortable_default_field` remains `nil`. In that case `sorted` returns the relation unmodified — no ordering is applied and no error is raised.
- **Calling `sortable_by` with no arguments raises `ArgumentError`.** The error message is `"ConcernsOnRails::Controllers::Sortable: at least one field is required"`.
- **`params[:direction]` is case-insensitive.** The value is downcased before validation, so `"ASC"`, `"Asc"`, and `"asc"` are all accepted. Any other value (e.g., `"sideways"`, `""`) falls back to the configured default direction.
- **Non-whitelisted `params[:sort]` values fall back silently.** SQL injection payloads such as `"; DROP TABLE articles;--"` are ignored; the default field is used instead. No error or warning is raised.
- **The allow-list is stored as `class_attribute`.** Subclassing a controller and calling `sortable_by` again on the subclass creates an independent allow-list without affecting the parent. Standard Rails `class_attribute` inheritance semantics apply.
- **`sorted` wraps `ActiveRecord::Relation#order`.** It appends ordering to whatever scopes or conditions the relation already carries. Call it last in a chain to avoid unexpected precedence with any existing `order` clauses in the relation.
- **No database columns or migrations are required.** This is a pure controller concern; it reads only `params` and delegates to `ActiveRecord::Relation#order`. The column names in the allow-list must exist in the model's table, but the concern itself does not validate this at load time.
- **Not the same as `ConcernsOnRails::Models::Sortable`.** The model concern integrates `acts_as_list` for persistent positional ordering. Both can coexist: the model manages list position while the controller concern handles URL-driven sort for other columns.
