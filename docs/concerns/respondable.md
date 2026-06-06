A lightweight concern that enforces a consistent JSON envelope shape across every action in an API controller. Rather than each action constructing its own `render json:` call — and gradually drifting in shape — `Respondable` centralizes the two canonical response forms (`success` and `error`) behind two intent-revealing methods. The contract is stable enough that client-side code can rely on the `success` boolean as the single dispatch flag, the `data` key for payload, and the nested `error` object for machine-readable failure metadata.

## When to use it

- Versioned JSON APIs where every endpoint must return a predictably shaped response.
- Controllers that mix resource actions (returning data) with validation actions (returning error lists), and need a single envelope that covers both without conditional branching.
- Base controller classes in Rails API-mode apps where downstream controllers should inherit a shared response contract.
- Situations where frontend or mobile clients key off a top-level `success` boolean rather than inspecting HTTP status codes directly.
- Pairing with `ConcernsOnRails::Controllers::ErrorHandleable`, which delegates its `rescue_from` handlers to `render_error` when `Respondable` is included, keeping the envelope shape in one place.

## Installation

Include the module in any controller — most commonly a shared base class:

```ruby
class Api::BaseController < ApplicationController
  include ConcernsOnRails::Controllers::Respondable
end

class Api::ArticlesController < Api::BaseController
  def show
    article = Article.find_by(id: params[:id])
    return render_error(message: "Not found", status: :not_found) unless article

    render_success(data: article)
  end

  def create
    article = Article.new(article_params)
    if article.save
      render_success(data: article, status: :created)
    else
      render_error(message: "Invalid", errors: article.errors.full_messages)
    end
  end

  private

  def article_params
    params.require(:article).permit(:title, :body)
  end
end
```

No generator, initializer, or configuration macro is required. Including the module is sufficient.

## Configuration

`Respondable` exposes no configuration macro. All behavior is controlled per-call through the keyword arguments documented in the Methods section below.

## Methods

### Instance methods

#### `render_success(data: nil, status: :ok, meta: {})`

Renders a JSON success envelope and halts the action. Returns the result of `render`.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `data` | any JSON-serializable value | `nil` | The primary response payload. Placed under the `data` key as-is; can be a Hash, Array, ActiveRecord model, or `nil`. |
| `status` | Symbol or Integer | `:ok` | HTTP status code passed directly to `render`. Any status symbol or integer accepted by Rails is valid (e.g. `:created`, `:ok`, `200`). |
| `meta` | Hash | `{}` | Optional metadata (pagination counts, cursors, etc.). Included in the body only when the hash is non-empty; omitted entirely otherwise. |

Output envelope:

```json
{ "success": true, "data": <data>, "meta": <meta> }
```

The `meta` key is absent when `meta` is empty (the default), keeping simple responses clean.

---

#### `render_error(message:, status: :unprocessable_entity, code: nil, errors: nil)`

Renders a JSON error envelope and halts the action. Returns the result of `render`.

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `message` | String | _(required)_ | Human-readable description of the failure. Placed under `error.message`. |
| `status` | Symbol or Integer | `:unprocessable_entity` | HTTP status code. Any value accepted by Rails is valid (e.g. `:not_found`, `:forbidden`, `422`). |
| `code` | String or nil | `nil` | Machine-readable error code (e.g. `"not_found"`, `"PERMISSION_DENIED"`). Included under `error.code` only when non-nil. |
| `errors` | Array or nil | `nil` | Detailed error list — typically `record.errors.full_messages`. Included under `error.details` only when non-nil. |

Output envelope:

```json
{ "success": false, "error": { "message": "...", "code": "...", "details": [...] } }
```

Both `code` and `details` are omitted from `error` when their corresponding arguments are not supplied, so the minimal error body contains only `message`.

## Examples

**Standard CRUD controller with validation errors:**

```ruby
class Api::PostsController < ApplicationController
  include ConcernsOnRails::Controllers::Respondable

  def index
    posts = Post.published.page(params[:page]).per(25)
    render_success(
      data: posts.as_json(only: %i[id title published_at]),
      meta: { total: posts.total_count, page: posts.current_page }
    )
  end

  def show
    post = Post.find_by(id: params[:id])
    return render_error(message: "Post not found", status: :not_found, code: "not_found") unless post

    render_success(data: post)
  end

  def create
    post = Post.new(post_params)
    if post.save
      render_success(data: post, status: :created)
    else
      render_error(
        message: "Post could not be saved",
        errors: post.errors.full_messages
      )
    end
  end
end
```

**Machine-readable error codes for client branching:**

```ruby
class Api::SessionsController < ApplicationController
  include ConcernsOnRails::Controllers::Respondable

  def create
    user = User.find_by(email: params[:email])

    unless user&.authenticate(params[:password])
      return render_error(
        message: "Invalid credentials",
        status: :unauthorized,
        code: "INVALID_CREDENTIALS"
      )
    end

    render_success(data: { token: user.generate_api_token })
  end
end
```

**Combining with `ErrorHandleable` on a base controller:**

```ruby
class Api::BaseController < ApplicationController
  include ConcernsOnRails::Controllers::Respondable
  include ConcernsOnRails::Controllers::ErrorHandleable
  # ErrorHandleable delegates its rescue_from handlers to render_error
  # because Respondable is already included, keeping the envelope in one place.
end

class Api::UsersController < Api::BaseController
  def show
    # Will raise ActiveRecord::RecordNotFound if not found;
    # ErrorHandleable catches it and calls render_error automatically.
    user = User.find(params[:id])
    render_success(data: user)
  end
end
```

## Notes & gotchas

- **`data:` is always a keyword argument.** This is intentional. Ruby 3 treats a trailing Hash literal as keyword arguments when the receiving method declares any keyword params. Keeping `data:` as a named keyword means callers can pass a plain `{}` hash without surprises — `render_success(data: { id: 1 })` is unambiguous in all Ruby 3.x versions.
- **`meta` is omitted, not `null`, when empty.** Passing `meta: {}` (the default) results in a response body with no `meta` key at all. A client checking `response.meta` must guard against the key being absent, not just `null`.
- **`code` and `details` follow the same omit-when-nil rule.** The minimal error body is `{ "success": false, "error": { "message": "..." } }`. Both `code` and `details` only appear when explicitly provided.
- **`render_success` accepts `nil` data.** Calling `render_success` with no arguments is valid and produces `{ "success": true, "data": null }`. This is useful for actions that confirm an operation (e.g. `DELETE`) without returning a resource body.
- **No state, no callbacks, no configuration macro.** The concern adds exactly two instance methods to the including controller. There are no `before_action` hooks, class-level macros, or instance variables introduced.
- **HTTP status symbols follow Rails conventions.** Any symbol or integer recognized by `Rack::Utils::SYMBOL_TO_STATUS_CODE` is accepted — the arguments are passed directly to `render`. Passing an invalid status symbol raises the same `ArgumentError` Rails itself would raise.
- **`meta` must be a Hash.** The implementation checks `meta.is_a?(Hash) && meta.any?` before including it. Passing a non-Hash value (e.g. an Array) for `meta` causes it to be silently dropped from the response body.
- **Pairing with `ErrorHandleable`.** When `ConcernsOnRails::Controllers::ErrorHandleable` is included alongside `Respondable` (in either order), its `rescue_from` handlers detect the presence of `render_error` and delegate to it rather than rendering inline. Include `Respondable` before `ErrorHandleable` in the class body to make the delegation intent explicit.
