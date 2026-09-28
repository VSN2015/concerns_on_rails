A store-agnostic, Stripe-style `Idempotency-Key` layer for mutating Rails controller actions. `Idempotentable` registers an `around_action` that, for declared actions, atomically claims the request's key, lets the action run, and caches the rendered response; a retry with the same key replays the cached status/body/content type and the allow-listed response headers instead of re-running the action, and a concurrent duplicate while the first request is still in flight is halted with HTTP 409. No middleware and no database table are required — any cache with `read` / `write(expires_in:, unless_exist:)` / `delete` (such as `Rails.cache` on Memcache or Redis) works.

## When to use it

- Payment or order creation endpoints where a client network retry must not double-charge or double-create.
- Mobile/API clients with automatic retry policies (timeouts, flaky networks) hitting non-idempotent POST endpoints.
- Webhook-style "submit once" forms where double-clicks and refreshes replay the same request.
- Any public API that wants to offer the `Idempotency-Key` contract its consumers already know from Stripe/PayPal.

## Installation

Add the include, inject a store, and declare the actions:

```ruby
class PaymentsController < ApplicationController
  include ConcernsOnRails::Controllers::Idempotentable

  # Must be set before any keyed request is processed.
  self.idempotency_store = Rails.cache

  idempotent_actions :create, ttl: 24.hours, required: true
end
```

## Configuration

### `idempotent_actions(*actions, ttl: 86_400, lock_ttl: 60, header: "Idempotency-Key", required: false, headers: DEFAULT_REPLAY_HEADERS, on_store_unavailable: :reject)`

May be called multiple times to register rules with independent options; the first rule listing the current action wins. All arguments are validated at class-load time (`ArgumentError`).

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `*actions` | one or more `Symbol`/`String` | — (required) | The action names the rule applies to. Scoping is purely by action name (declare only mutating actions; don't list GET/HEAD actions). |
| `ttl:` | `ActiveSupport::Duration` or `Integer` (seconds) | `24.hours` | Lifetime of a cached ("done") response. |
| `lock_ttl:` | `Duration` or `Integer` | `1.minute` | Lifetime of the in-flight claim. Kept short so a crashed worker cannot wedge a key until `ttl` expires. |
| `header:` | `String` | `"Idempotency-Key"` | The request header carrying the key. |
| `required:` | `true`/`false` | `false` | When `true`, a missing key is rejected with 400; when `false`, keyless requests pass through untouched. |
| `headers:` | `Array<String>` | `%w[Location Content-Location ETag Last-Modified Link]` (`DEFAULT_REPLAY_HEADERS`) | Response headers captured with the cached response and set again on replay, so a replayed `201` still carries its `Location`. Only headers the action actually set are stored (under `record["headers"]`); the lookup is case-insensitive, so an action setting the Rack-3-style `location` is captured too and stored under the allow-list's own casing. An allow-list on purpose — `Set-Cookie`, `Date`, request ids and rate-limit headers describe the original exchange and are never replayed. `[]` disables capture; a non-Array or blank name raises `ArgumentError`. |
| `on_store_unavailable:` | `:reject` / `:proceed` | `:reject` | What to do when the store cannot be reached. `:reject` answers **503** `idempotency_store_unavailable` with `Retry-After` (`STORE_UNAVAILABLE_RETRY_AFTER`, 5 s) and does **not** run the action; `:proceed` runs the action **without** deduplication. Anything else raises `ArgumentError`. See "Store outages" below for why the default fails closed. |

### `idempotency_store`

A class-level attribute (not a macro argument). There is no in-process default on purpose — the first keyed request raises `ArgumentError` until a store is set, either on the class or once gem-wide via `ConcernsOnRails.setup { |c| c.cache_store = -> { Rails.cache } }` (the class-level assignment wins). The minimal contract:

| Method | Used for | Required semantics |
|--------|----------|--------------------|
| `write(key, hash, expires_in:, unless_exist: true)` | atomic in-flight claim | must return falsey when the key already exists (`Rails.cache` → memcached `add` / Redis `SET NX`) |
| `write(key, hash, expires_in:)` | persisting the cached response | plain set with TTL (overwrites the claim) |
| `read(key)` | replay / conflict / fingerprint lookup | returns the stored `Hash` or `nil` |
| `delete(key)` | releasing the claim on exception or 5xx | — |

## Request lifecycle

```
no matching rule, or no key sent (required: false)   → action runs untouched
required: true and key missing                       → 400  code "idempotency_key_missing"
key blank or longer than 255 characters              → 400  code "idempotency_key_invalid"
claim won (first request)                            → action runs; 2xx–4xx cached for ttl;
                                                       5xx / raised exception releases the claim
retry of a completed request (same payload)          → cached response replayed,
                                                       X-Idempotency-Replayed: true
duplicate while the first is still in flight         → 409  code "idempotency_conflict",
                                                       Retry-After: <lock_ttl>
same key reused with a different payload             → 422  code "idempotency_key_reuse"
store unreachable (on_store_unavailable: :reject)    → 503  code "idempotency_store_unavailable",
                                                       Retry-After: 5; the action does not run
store unreachable (on_store_unavailable: :proceed)   → action runs, no deduplication
```

Cache keys are scoped as `idempotentable:<controller>#<action>:<SHA256(key)>`, so the same client key on different endpoints never collides, and any validated key is safe in any backend (memcached key-length/charset limits).

## Response headers

| Header | When | Value |
|--------|------|-------|
| `X-Idempotency-Key` | every keyed request | the raw key, echoed back |
| `X-Idempotency-Replayed` | original run / replay | `"false"` on the original execution, `"true"` on a replay |
| `Retry-After` | 409 conflict / 503 store unavailable | 409: the remaining lock time in seconds; 503: `STORE_UNAVAILABLE_RETRY_AFTER` (5) |
| captured headers | replay | the `headers:` allow-list entries the original response set (default `Location`, `Content-Location`, `ETag`, `Last-Modified`, `Link`), replayed verbatim before the body |

## Methods

### Instance methods (override points)

| Signature | Description |
|-----------|-------------|
| `enforce_idempotency(&block)` | The `around_action` entry point. Public so subclasses can override it. |
| `idempotency_key` | The raw key sent for the matched rule (`nil` when absent). Handy for logging. |
| `idempotency_scope` | The cache-key namespace, `"<controller>#<action>"` by default. **Override it to add the authenticated principal whenever keys are client-chosen** — `def idempotency_scope = "#{super}:#{current_user&.id}"` — otherwise two users who send the same key with the same payload to the same endpoint share one record, and the second is served the first's cached response, including its captured `Location`. |
| `idempotency_fingerprint` | SHA256 digest of the request params (deep-sorted, minus `controller`/`action`/`format`), used to detect key reuse with a different payload. Override for raw-body APIs: `Digest::SHA256.hexdigest(request.raw_post)`. |
| `replay_idempotent_response(record)` | Sets the captured headers (`record["headers"]`, absent on records written before this feature), renders the cached response, and restores the original's exact `Content-Type` header (`record["content_type_header"]` — so an RFC 9457 `application/problem+json` is not replayed with Rails' default `; charset=utf-8`; records without it replay the media type as before). Override to customize replay. |
| `idempotency_error_response(message:, status:, code:)` | Single funnel for the 400/409/422 outcomes. Delegates to `render_error` when `Respondable` is included, otherwise renders `{ success: false, error: { message:, code: } }` inline. The body is an RFC 9457 problem document instead when [Respondable](respondable.md) is configured with `respondable_by error_format: :problem_details`. |

## Examples

**Required key on a payments endpoint:**

```ruby
class Api::PaymentsController < ApplicationController
  include ConcernsOnRails::Controllers::Respondable
  include ConcernsOnRails::Controllers::Idempotentable

  self.idempotency_store = Rails.cache

  idempotent_actions :create, required: true, ttl: 24.hours

  def create
    payment = Payment.create!(payment_params)
    render_success(data: payment, status: :created)
  end
end
```

**Raw-body fingerprint for a JSON API:**

```ruby
class Api::OrdersController < ApplicationController
  include ConcernsOnRails::Controllers::Idempotentable

  self.idempotency_store = Rails.cache
  idempotent_actions :create

  def idempotency_fingerprint
    Digest::SHA256.hexdigest(request.raw_post)
  end
end
```

**Custom header and several rules:**

```ruby
class Api::BaseController < ApplicationController
  include ConcernsOnRails::Controllers::Idempotentable

  self.idempotency_store = Rails.cache

  idempotent_actions :create,  ttl: 24.hours, required: true
  idempotent_actions :update,  ttl: 1.hour,   header: "X-Request-Id"
end
```

## Notes & gotchas

- **The default scope is not per-user.** Cache keys are namespaced `idempotentable:<controller>#<action>:<SHA256(key)>` — there is no principal in them, so if your clients choose their own keys, two users posting identical params under the same `Idempotency-Key` collide: the second gets the first's cached response, **including the captured `Location`** — i.e. the URL of someone else's resource. Override `idempotency_scope` to namespace by principal: `def idempotency_scope = "#{super}:#{current_user&.id}"`.
- **Replayed headers are an allow-list.** Only `headers:` entries (default `Location`, `Content-Location`, `ETag`, `Last-Modified`, `Link`) are captured — a header the action never set is simply not stored, and records written before this feature (no `"headers"` key) replay exactly as before. Add app-specific headers (`headers: DEFAULT_REPLAY_HEADERS + %w[X-Resource-Version]`) rather than widening to everything: cookies, `Date`, request ids and `X-RateLimit-*` describe the *original* exchange.
- **No default store.** `idempotency_store` is `nil` by default on purpose; the first keyed request raises `ArgumentError` with "no store configured" rather than silently caching per-process. A gem-wide fallback can be set once via `ConcernsOnRails.setup { |c| c.cache_store = -> { Rails.cache } }`.
- **Atomic `unless_exist` is required for correctness.** With a store whose `unless_exist:` write is not atomic (file store, plain memory store across processes), two concurrent firsts can both claim and both execute — the behavior degrades to best-effort. `ActiveSupport::Cache::NullStore` silently disables idempotency entirely (claims always "succeed", reads return `nil`).
- **Store outages fail closed.** Rails' Redis and memcached stores swallow connection errors — `#write` returns false and `#read` returns nil — which looks exactly like "someone else holds the key". A lost claim with nothing to read back is therefore retried once: a lock that merely expired in between is won and the action runs; if that fails too the key is read again — a record there means another request re-claimed the freed key in between, and it is answered as usual (409 / replay / 422). Only nil on **both** reads means the store is down, and the request gets 503 `idempotency_store_unavailable` (not the permanent 409 it used to get). Two edge cases: a key claimed *and* released again between the two reads still reads as an outage (a spurious, retry-safe 503 under `:reject`; under `:proceed` the action runs without a claim, so a concurrent duplicate is possible in that narrow window); and a key whose stored value cannot be deserialized (the store reads it as nil but refuses the `unless_exist:` claim) gets 503 until that entry's TTL expires. The default is `:reject` because this concern exists for requests where a duplicate is harmful — with the store down there is no way to know whether a retry's original already ran, and a 503 the client retries later costs only latency, where running it risks a double charge. Use `on_store_unavailable: :proceed` on endpoints where a duplicate is merely noise.
- **5xx responses and exceptions are retryable by design.** They release the claim and are never cached, so the client's retry re-executes the action. Only 2xx–4xx responses are replayed.
- **`rescue_from` responses are never cached.** Rails' rescue layer wraps outside the callback chain, so an exception handled by `ErrorHandleable` still propagates through the around filter (releasing the claim) before the handler renders.
- **Declare halting filters first.** Include `Throttleable` and declare authentication/authorization `before_action`s *before* including this concern. A filter that runs inside the around filter and halts with 401/403 has that response **cached and replayed** for the full `ttl:` — the client can't fix credentials and retry until it expires (Rails offers no reliable way to detect a halted inner chain).
- **`lock_ttl:` must exceed the slowest action.** If a declared action outlasts its claim, a concurrent retry can win the expired key and execute the action a second time (and the later finisher's response wins the cache). Size `lock_ttl:` above the worst-case wall-clock duration.
- **Multipart endpoints need a custom fingerprint.** `ActionDispatch::Http::UploadedFile` stringifies with its object id, so a retried upload never matches and gets a spurious 422 — override `idempotency_fingerprint` to digest stable parts (e.g. `params[:file]&.original_filename`).
- **Response bodies live in your cache for `ttl`.** Large responses on idempotent actions consume cache memory accordingly.
- **Rules are inherited but not shared.** `idempotency_rules` is a `class_attribute`; the macro appends copy-on-write, so subclass declarations never mutate the parent.
- **Keys are validated, then hashed.** A key must be non-blank, at most 255 characters, and free of control characters (else 400) — the control-character check exists because the raw key is echoed in `X-Idempotency-Key`, and CR/LF would otherwise enable response-header injection on Rack 2. The cache key uses the key's SHA256.

## Changed (unreleased)

- **An unreachable store answers 503, not 409.** A falsy claim write followed by a nil read used to be treated as "in flight", so during a cache outage every keyed request got `409 idempotency_conflict` indefinitely. The claim is now retried once and the key read again; only nil on both reads renders `503 idempotency_store_unavailable` with `Retry-After` (Respondable-aware). New option `on_store_unavailable:` (`:reject` default, `:proceed`).

## Changed in 1.22.0

- The 409 conflict's `Retry-After` reports the remaining lock time (computed from the claim's `claimed_at`) instead of the full `lock_ttl`, so clients stop over-backing-off.
