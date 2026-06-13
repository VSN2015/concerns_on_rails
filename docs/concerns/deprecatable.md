The `Deprecatable` concern adds **standards-based API endpoint deprecation** to any controller: the RFC 9745 `Deprecation` header, the RFC 8594 `Sunset` header, RFC 8288 `Link` rels pointing at the migration docs and the successor endpoint, an instrumentation hook to measure who still calls the endpoint, and optional automatic **410 Gone** enforcement once the sunset instant passes. This is the lifecycle Stripe, GitHub, and Zalando run when they retire API versions — announce, schedule, observe, enforce — and nothing native exists on any Rails version.

## When to use it

- You're shipping `/api/v2` and need `/api/v1` to advertise its own retirement in a form client SDKs, API gateways, and monitoring tools parse automatically.
- Mobile clients linger on old endpoints for years — you need per-endpoint traffic measurement (`notify:` / `ActiveSupport::Notifications`) before a cut-off, not a changelog nobody reads.
- Enterprise deprecation-policy SLAs: the headers are your machine-readable audit trail that notice was given.
- Sunset day should be a clean, self-documenting `410 Gone` pointing at the successor — not a confusing route-deleted 404.

## Installation

```ruby
class Api::V1::OrdersController < ApplicationController
  include ConcernsOnRails::Controllers::Deprecatable

  deprecate_actions :index, :show,
    deprecated_at: "2026-06-01",
    sunset_at:     "2026-12-31T00:00:00Z",
    link:          "https://docs.example.com/v1-migration",
    successor:     "https://api.example.com/v2/orders",
    after_sunset:  :gone,
    notify:        -> { StatsD.increment("api.v1.orders.deprecated") }
end
```

Every matching response then carries:

```
Deprecation: @1780272000
Sunset: Thu, 31 Dec 2026 00:00:00 GMT
Link: <https://docs.example.com/v1-migration>; rel="deprecation", <https://api.example.com/v2/orders>; rel="successor-version"
```

## Configuration

### `deprecate_actions(*actions, deprecated_at:, sunset_at: nil, link: nil, successor: nil, after_sunset: :headers, header_format: :rfc9745, notify: nil)`

| option | default | meaning |
|---|---|---|
| `*actions` | — | Actions the rule covers; **none = catch-all** for the whole controller |
| `deprecated_at:` | required | Time / TimeWithZone / Date / DateTime / String — parsed eagerly, normalized to UTC |
| `sunset_at:` | `nil` | The retirement instant; must be ≥ `deprecated_at`. A bare date means **00:00 UTC that day** |
| `link:` | `nil` | Migration-docs URL → `Link: <…>; rel="deprecation"` |
| `successor:` | `nil` | Replacement endpoint URL → `Link: <…>; rel="successor-version"` |
| `after_sunset:` | `:headers` | `:headers` never blocks; `:gone` halts with 410 (`endpoint_sunset`) once `sunset_at` is reached (requires `sunset_at:`) |
| `header_format:` | `:rfc9745` | `:rfc9745` emits `@<unix-timestamp>`; `:legacy` emits the widely-deployed pre-RFC draft literal `true` |
| `notify:` | `nil` | Callable, `instance_exec`'d per matching request (so `request` / `current_user` resolve). A raising notify **propagates** — broken metrics should be loud |

The macro is repeatable and rules are inherited by subclasses. **The last matching rule wins** and exactly one rule applies per request — so a `V1::BaseController` catch-all is naturally overridden by a later, action-specific declaration in one controller. All option errors raise `ArgumentError` at declaration time (unparseable dates, `sunset_at` before `deprecated_at`, `:gone` without `sunset_at`, blank URLs, non-callable `notify`).

## Methods

- `apply_api_deprecations` — the `before_action` (public: `skip_before_action` it to opt an action out, or override it)
- `on_deprecated_access(rule)` — override point; the default instruments `deprecated_endpoint.concerns_on_rails` with `{controller:, action:, deprecated_at:, sunset_at:}` and runs `notify:`
- `deprecation_active?` / `sunset_passed?` — predicates for serializers and response bodies

## Examples

```ruby
# Measure stragglers before enforcing:
ActiveSupport::Notifications.subscribe("deprecated_endpoint.concerns_on_rails") do |*, payload|
  Metrics.count("deprecated_api_call", tags: ["#{payload[:controller]}##{payload[:action]}"])
end

# Whole-controller catch-all in a base class, one action overridden later:
class Api::V1::BaseController < ApplicationController
  include ConcernsOnRails::Controllers::Deprecatable
  deprecate_actions deprecated_at: "2026-06-01", sunset_at: "2027-01-01",
                    successor: "https://api.example.com/v2"
end

class Api::V1::SearchController < Api::V1::BaseController
  # legacy_search dies earlier, and hard:
  deprecate_actions :legacy_search, deprecated_at: "2026-06-01",
                    sunset_at: "2026-09-01", after_sunset: :gone
end
```

After the sunset instant with `after_sunset: :gone`, the action is halted with:

```json
{ "success": false, "error": { "message": "This endpoint was sunset on Tue, 01 Sep 2026 00:00:00 GMT.", "code": "endpoint_sunset" } }
```

(via `Respondable`'s `render_error` when included; the deprecation headers still ride the 410 so the failure self-documents).

## Notes & gotchas

- `sunset_at` is an **instant**, not a calendar day — `"2026-12-31"` dies at the *start* of that day (00:00 UTC). The boundary instant counts as sunset (inclusive).
- `Link` values are **appended** to any existing `Link` header (pagination, CDN), never clobbered.
- The default `:headers` mode never blocks, however long past sunset — flip to `:gone` only after `notify:`-driven metrics show callers have migrated. The flip is a deliberate, customer-facing cut-off.
- `header_format: :legacy` exists because pre-RFC tooling parses the draft boolean form; the RFC 9745 `@<unix>` form is the default and the right choice for new rollouts.
- CDN/proxy-cached responses can outlive the headers' accuracy — pair enforcement with cache invalidation.
- Clock skew across app servers makes the 410 flip non-simultaneous for a few seconds; comparisons run in UTC through one overridable seam (`deprecation_now`).
