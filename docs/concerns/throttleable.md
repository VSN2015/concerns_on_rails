A store-agnostic, per-request rate limiter for Rails controllers. `Throttleable` registers a `before_action` that evaluates one or more declarative rules; when a rule's counter exceeds its limit the request is halted immediately with HTTP 429, a human-readable JSON body, and the standard `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`, and `Retry-After` response headers. The implementation uses a fixed-window counter strategy: the cache key embeds a floored time bucket (`epoch / period`) so each window resets cleanly and `X-RateLimit-Reset` is always exact. No middleware, no Rack middleware gem, and no database table are required.

## When to use it

- Protecting a public JSON API from abusive clients by capping requests per IP to a high global limit (e.g. 100 per minute), with a tighter per-authenticated-user limit on write actions.
- Limiting expensive mutation endpoints (`create`, `update`) independently from cheap read endpoints without duplicating controller logic.
- Adding standardized rate-limit headers to a Rails 5–7 app before Rails 7.2's built-in `rate_limit` is available.
- Applying per-user throttling in a multi-tenant SaaS API where the discriminator is `current_user.id` rather than client IP.
- Preventing brute-force attempts on authentication endpoints by scoping a strict rule to `:create` on `SessionsController`.

## Installation

Add the include and configure at least one rule in the controller (or a shared base controller):

```ruby
class Api::BaseController < ApplicationController
  include ConcernsOnRails::Controllers::Throttleable

  # Must be set before any request is processed.
  # The store must support atomic increment-with-expiry.
  self.throttleable_store = Rails.cache

  # Global rule: 100 requests per minute, bucketed by client IP.
  throttle_by limit: 100, period: 1.minute

  # Tighter rule: 5 write requests per minute, bucketed by user ID
  # with IP fallback for unauthenticated callers.
  throttle_by limit: 5,
              period: 1.minute,
              only: :create,
              name: :write_limit,
              by: -> { current_user&.id || request.remote_ip }
end
```

## Configuration

`throttle_by` is the sole configuration macro. It may be called multiple times on the same class to register multiple independent rules. Rules are evaluated in declaration order; the first rule whose counter exceeds its limit stops the request.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `limit:` | `Integer` | — (required) | Maximum number of requests allowed in a single window. Must be a positive integer; zero or negative values raise `ArgumentError` at class-load time. |
| `period:` | `ActiveSupport::Duration` or `Integer` (seconds) | — (required) | Length of the fixed window in seconds. `period.to_i` must be positive; `0` raises `ArgumentError`. |
| `by:` | callable (`Proc`, `lambda`) | `-> { request.remote_ip }` | Discriminator evaluated with `instance_exec` on the controller instance, so `request`, `params`, and helpers such as `current_user` are all in scope. Must respond to `#call`; a plain string or symbol raises `ArgumentError`. |
| `only:` | `Symbol` or `Array<Symbol>` | `nil` (all actions) | Restricts the rule to the listed action names. Mutually exclusive with `except:`; passing both raises `ArgumentError`. |
| `except:` | `Symbol` or `Array<Symbol>` | `nil` (no exclusions) | Skips the rule for the listed action names. Mutually exclusive with `only:`. |
| `name:` | `Symbol` or `String` | `"rule0"`, `"rule1"`, … | Embedded in the cache key to disambiguate counters when multiple rules share the same discriminator value. Defaults to `"rule#{index}"` based on declaration order. |

`throttleable_store` is a class-level attribute (not a macro argument). It must be assigned before the first throttled request and must support atomic increment-with-expiry — specifically `store.increment(key, 1, expires_in: seconds)`. `Rails.cache` backed by Memcache or Redis satisfies this contract. A store that returns `nil` from `#increment` for a missing key is handled: the concern falls back to `store.write(key, 1, expires_in: period)` and treats the count as `1`.

## Methods

### Instance methods

| Signature | Description |
|-----------|-------------|
| `enforce_throttles` | `before_action` entry point. Iterates every applicable rule, increments its counter, sets rate-limit headers, and renders a 429 response if the limit is exceeded. Public so subclasses can call or override it. |
| `throttled_response(rule, result)` | Renders the 429 body. Public override point. By default renders `{ success: false, error: { message: "...", code: "rate_limited" } }` with `status: :too_many_requests`. If `Respondable` is also included the call is delegated to `render_error`. Override this method to customize the body format. |

### Class methods

| Signature | Description |
|-----------|-------------|
| `throttle_by(limit:, period:, by: nil, only: nil, except: nil, name: nil)` | Declares a rate-limit rule and appends it to `throttleable_rules`. Raises `ArgumentError` immediately if any argument is invalid. |

## Examples

**Global IP-based limit on an API base controller:**

```ruby
class Api::V1::BaseController < ApplicationController
  include ConcernsOnRails::Controllers::Throttleable

  self.throttleable_store = Rails.cache

  throttle_by limit: 200, period: 1.minute
end
```

**Multiple rules with action scoping and a custom discriminator:**

```ruby
class Api::V1::PostsController < Api::V1::BaseController
  # Inherits the global 200 req/min IP rule from BaseController.

  # Additional tighter rule: authenticated writes are capped at 10/minute per user.
  throttle_by limit: 10,
              period: 1.minute,
              only: [:create, :update, :destroy],
              name: :write_limit,
              by: -> { current_user&.id || request.remote_ip }
end
```

**Custom 429 response body:**

```ruby
class Api::V2::BaseController < ApplicationController
  include ConcernsOnRails::Controllers::Throttleable

  self.throttleable_store = Rails.cache
  throttle_by limit: 60, period: 1.minute

  def throttled_response(_rule, result)
    render json: {
      error: "too_many_requests",
      retry_after: result[:retry_after]
    }, status: :too_many_requests
  end
end
```

## Notes & gotchas

- **No default store.** `throttleable_store` is `nil` by default on purpose. If a rule fires before the attribute is set, `enforce_throttles` raises `ArgumentError` with a message containing "no store configured". This prevents silent per-process in-memory counters that reset on every deploy or dyno restart.

- **Atomic increment is required for correctness.** Under concurrency, a store whose `#increment` is not atomic will under-count — two simultaneous requests can both read `0`, both write `1`, and both pass through when only one should. `Rails.cache` with a Dalli (Memcache) or Redis backend satisfies the contract; the file store and memory store do not.

- **`nil` return from `#increment` is handled.** Some store adapters return `nil` instead of `1` on the first write of a missing key. The concern detects this and calls `store.write(key, 1, expires_in: period)`, then treats the count as `1`, so the first request in a window is always allowed through.

- **`only:` and `except:` are mutually exclusive.** Passing both to a single `throttle_by` call raises `ArgumentError: pass either :only or :except, not both` at class-load time, not at request time.

- **Action name matching is string-based.** `only: :create` is stored as `["create"]` and compared against `action_name.to_s`. Symbols and strings in the array are both accepted at declaration time.

- **First-exceeding rule wins.** Rules are evaluated in declaration order. The first rule whose counter exceeds its limit renders the 429 body and returns immediately — subsequent rules are not evaluated for that request.

- **`X-RateLimit-Remaining` floors at zero.** Once a counter surpasses the limit the header reads `"0"`, never a negative value. `Retry-After` is only set on responses that exceed the limit.

- **`enforce_throttles` is public.** Subclasses can override it or call `super` to insert custom pre/post logic around the rate-limit check.

- **Rules are inherited but not shared.** `throttleable_rules` is a `class_attribute`. Subclasses inherit the parent's rules array but appending a rule in a subclass does not mutate the parent class's array (the macro does `self.throttleable_rules = throttleable_rules + [rule]`).

- **Counter key format.** Cache keys follow the pattern `throttleable:<name>:<discriminator>:<window_bucket>`. Changing `name:`, the discriminator, or the `period` effectively resets all existing counters for that rule.
