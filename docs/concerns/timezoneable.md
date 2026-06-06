`Timezoneable` is a controller concern that sets `Time.zone` to a per-request value for the duration of each action, then restores it afterward. It solves the common Rails problem of serving users across multiple time zones: without explicit zone switching, all timestamp arithmetic and display defaults to the application's global `Time.zone`, producing incorrect local times in views and serializers. The concern wraps the action in `Time.use_zone`, pulling the desired zone from request params, a `Time-Zone` header, or an optional cookie — in that priority order — and falling back to a configured default or the current `Time.zone` when nothing matches.

## When to use it

- An API that serves mobile or SPA clients which send the user's IANA time-zone name in a `Time-Zone` header on every request.
- A multi-tenant SaaS application where each user stores a preferred time zone in their browser cookie and all timestamps (created dates, due dates, scheduled jobs) must display in that zone.
- A booking or scheduling app where date boundaries (start-of-day, end-of-day) must align with the requesting user's local time, not the server's.
- Any controller that pairs with model concerns such as `Publishable`, `Schedulable`, or `Expirable`, where `.where("published_at > ?", Time.current)` must be evaluated in the right zone.
- Applications that want a strict allow-list of supported zones, rejecting arbitrary zone names from untrusted clients without crashing.

## Installation

Include the module in `ApplicationController` (or any specific controller) and call the `timezoneable` macro once. The macro is evaluated at class load time, so misconfigured zone names raise immediately on boot rather than at request time.

```ruby
class ApplicationController < ActionController::Base
  include ConcernsOnRails::Controllers::Timezoneable

  timezoneable available: ["UTC", "Eastern Time (US & Canada)", "London"],
               default: "UTC"
end
```

A more customized setup using all options:

```ruby
class ApplicationController < ActionController::Base
  include ConcernsOnRails::Controllers::Timezoneable

  timezoneable available: ["UTC", "Eastern Time (US & Canada)", "London"],
               default:   "UTC",
               param:     :tz,
               header:    false,
               cookie:    :user_time_zone
end
```

## Configuration

The `timezoneable` class macro accepts the following keyword options.

| Option | Type | Default | Description |
|---|---|---|---|
| `available:` | `Array<String>` or `nil` | `nil` | Allow-list of accepted time-zone names, validated through `ActiveSupport::TimeZone[]` at declaration time. When set, param/header/cookie values that do not match an entry in this list are silently ignored and resolution falls through to the next source. The `default:` value bypasses this allow-list. When `nil`, any valid `ActiveSupport::TimeZone` name is accepted from any source. |
| `default:` | `String` or `nil` | `nil` | Zone to use when no source resolves a usable zone. Validated at declaration time; bypasses the `available:` allow-list. When `nil` and no source resolves, the current global `Time.zone` is used unchanged. |
| `param:` | `Symbol` | `:time_zone` | The request parameter key inspected for a zone name, e.g. `params[:time_zone]`. Set to a custom symbol to use a different param name. The param source is skipped entirely if `params` is unavailable. |
| `header:` | `Boolean` | `true` | When `true`, the `Time-Zone` HTTP request header is read as a zone source. Set to `false` to disable header-based zone selection. |
| `cookie:` | `Boolean` or `Symbol` | `false` | Controls cookie-based zone reading. `false` disables it. `true` reads the cookie named `:time_zone`. Pass any other symbol (e.g. `:user_time_zone`) to read that specific cookie key instead. |

## Methods

### Instance methods

**`switch_time_zone(&block) → Object`**
An `around_action` registered automatically on include. Calls `Time.use_zone(resolved_time_zone, &block)`, running the action body under the resolved zone and restoring the previous `Time.zone` after the block exits — even if an exception is raised. Declared `public` so that subclasses can override it.

**`resolved_time_zone → ActiveSupport::TimeZone`**
Returns the `ActiveSupport::TimeZone` chosen for the current request. Evaluates sources in order — param, header, cookie, configured default — and returns the first that produces a valid zone matching the allow-list. Falls back to the current `Time.zone` if nothing resolves. Exposed as a public method so controllers or views can reference the selected zone directly (e.g., to render a timezone indicator).

## Examples

**Basic usage with a param and a default**

```ruby
class ApplicationController < ActionController::Base
  include ConcernsOnRails::Controllers::Timezoneable

  timezoneable available: ["UTC", "Eastern Time (US & Canada)"], default: "UTC"
end

# GET /reports?time_zone=Eastern+Time+(US+%26+Canada)
# => Time.zone is "Eastern Time (US & Canada)" for the duration of the action.
#
# GET /reports?time_zone=Mars
# => "Mars" is not in the allow-list; falls back to default "UTC".
```

**Header-driven zone selection for an API**

```ruby
class ApiController < ActionController::Base
  include ConcernsOnRails::Controllers::Timezoneable

  # Clients send:  Time-Zone: London
  timezoneable available: %w[UTC London Pacific\ Time\ (US\ &\ Canada)],
               default: "UTC"
end
```

**Cookie-based persistence with a custom cookie name**

```ruby
class ApplicationController < ActionController::Base
  include ConcernsOnRails::Controllers::Timezoneable

  timezoneable available: ActiveSupport::TimeZone.all.map(&:name),
               default:   "UTC",
               header:    false,
               cookie:    :preferred_time_zone

  # After login, set the cookie from the user's profile:
  before_action :set_time_zone_cookie

  private

  def set_time_zone_cookie
    cookies[:preferred_time_zone] = current_user.time_zone if user_signed_in?
  end
end
```

## Notes & gotchas

- **Fail-fast validation at class load time.** Both `available:` and `default:` are resolved through `ActiveSupport::TimeZone[]` when `timezoneable` is called, not on the first request. An unrecognized name (e.g. `"Pluto"`) raises `ArgumentError` with a descriptive message immediately, so misconfiguration surfaces during boot rather than under production load.

- **Resolution order is strict.** Param is always checked before header, header before cookie. If a param value is present but not in the allow-list, the concern does not fall through to the param itself — it falls through to the header source. There is no way to make cookie take precedence over the header without subclassing and overriding `switch_time_zone`.

- **`default:` bypasses the allow-list.** The configured default zone is never filtered by `available:`. This mirrors the behavior of the sibling `Localizable` concern and ensures a working fallback even when the allow-list is restrictive.

- **`Time.use_zone` is thread-safe.** The zone is stored in a thread-local variable by Active Support, so concurrent requests do not interfere with each other. However, code that spawns additional threads inside an action (e.g., `Concurrent::Future`, `Thread.new`) will inherit or lose the zone depending on how Active Support's thread-local isolation interacts with the new thread.

- **Zone name matching is name-equality, not object identity.** The allow-list check compares `zone.name == z.name` for each candidate against each allowed zone. The underlying `ActiveSupport::TimeZone[raw]` lookup accepts both IANA names and Rails display names (e.g., both `"America/New_York"` and `"Eastern Time (US & Canada)"` resolve to the same zone object), so the allow-list and request values do not need to use the same naming convention as long as they resolve to the same `ActiveSupport::TimeZone`.

- **Blank or unrecognized param/header/cookie values are silently skipped.** If `params[:time_zone]` is `nil`, `""`, or an unknown string such as `"bogus"`, `zone_from_param` returns `nil` and resolution continues to the next source. No error is raised for invalid runtime values; only boot-time configuration raises `ArgumentError`.

- **No `timezoneable` call needed.** If `timezoneable` is never called, `timezoneable_options` defaults to `{}` and `resolved_time_zone` returns the current `Time.zone` unchanged on every request. The `around_action` is still registered but behaves as a no-op.

- **`switch_time_zone` is public by design.** Subclasses can override it to add logging, metrics, or additional fallback logic while still calling `super` to retain the zone-switching behavior.

- **Cookie reading requires the controller to expose `cookies`.** If the controller does not respond to `cookies` (e.g., an API-mode controller that does not include the cookie middleware), the cookie source is silently skipped. The same applies to `params` for the param source and `request` for the header source.
