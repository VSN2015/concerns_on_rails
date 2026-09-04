The `Cacheable` concern adds **HTTP conditional GET and declarative `Cache-Control`** to any controller — "fresh_when/stale?-lite" for JSON APIs. It has two layers: a per-action `Cache-Control`/`Vary` policy declared with `http_cache_actions`, and per-action validators (ETag / `Last-Modified`) with an automatic `304 Not Modified` short-circuit via `stale_resource?`. The method names are chosen so the concern **never shadows** Rails' own `ActionController::ConditionalGet` (`fresh_when` / `stale?` / `expires_in`).

## When to use it

- A read-heavy JSON `show`/`index` endpoint where you want browsers, mobile SDKs, and CDNs to revalidate cheaply with `304 Not Modified` instead of re-sending the body.
- Setting consistent `Cache-Control` (public/private, `max-age`, `stale-while-revalidate`) per action without hand-writing header strings.
- An API behind a CDN that keys on `Vary` and needs the header appended, not clobbered, alongside pagination/CORS headers.
- Any controller that already serializes from a record/relation with an `updated_at` — the ETag and `Last-Modified` derive automatically.

## Installation

The fully-qualified path is `ConcernsOnRails::Controllers::Cacheable`.

```ruby
class Api::ArticlesController < ApplicationController
  include ConcernsOnRails::Controllers::Cacheable

  http_cache_actions :index, :show, max_age: 5.minutes, visibility: :public, vary: "Accept"

  def show
    @article = Article.find(params[:id])
    return unless stale_resource?(@article)   # 304 + halt when the client's copy is fresh
    render json: @article
  end
end
```

A matching response then carries:

```
Cache-Control: public, max-age=300
Vary: Accept
ETag: W/"…"
Last-Modified: Thu, 01 Jan 2026 12:00:00 GMT
```

## Configuration

### `http_cache_actions(*actions, visibility: :private, max_age: nil, must_revalidate: false, no_store: false, stale_while_revalidate: nil, vary: nil)`

Declares the policy emitted via `after_action`. Repeatable; rules are inherited by subclasses. **No positional actions = catch-all** for the whole controller, and **the last matching rule wins** (the Deprecatable convention — caching policy is an override).

| Option | Default | Meaning |
|---|---|---|
| `*actions` | — | Actions the policy covers; **none = catch-all** |
| `visibility:` | `:private` | `:public` or `:private` — the cacheability scope |
| `max_age:` | `nil` | Freshness lifetime; `Integer` seconds or a `Duration` |
| `must_revalidate:` | `false` | Append `must-revalidate` |
| `no_store:` | `false` | Emit the lone `no-store` — **overrides everything else** |
| `stale_while_revalidate:` | `nil` | Append `stale-while-revalidate=<seconds>` |
| `vary:` | `nil` | `String` or `Array` of header names, **appended** (de-duplicated) to any existing `Vary` |

### `etag_with(*sources, vary: nil, &block)`

Declares request context that shapes the representation and therefore belongs in the ETag — the analogue of Rails' class-level `etag { }`. Repeatable; entries accumulate and are folded into every validator `stale_resource?` / `set_cache_validators` writes (`W/"md5(base-etag | value | value …)"`), so two representations of one resource never share an ETag and a client never gets a 304 for a body it has not seen.

| Source | Value folded in | Default `Vary` |
|---|---|---|
| `:locale` | `I18n.locale` | `Accept-Language` |
| `:format` | `request.format` | `Accept` |
| `:query` | `request.query_string` | — |
| any other `Symbol` | the controller method of that name (`send`) | — |
| a block | `instance_exec`'d on the controller | — |

`vary:` (String/Array) replaces the implied header(s) for that call; `vary: false` suppresses them. The `Vary` header is written whenever validators are written and merged (de-duplicated) with the `http_cache_actions` policy. `nil` values are dropped, so an absent context leaves the ETag unchanged. A Symbol that is neither a preset nor a controller method raises `ArgumentError` at request time; an empty call or a non-Symbol source raises at class load. `cacheable_etag_extras` exposes the declared entries.

All option errors raise `ArgumentError` at declaration time (bad `:visibility`, non-positive durations, blank `:vary`, non-boolean flags).

## Methods

- `stale_resource?(resource = nil, etag: nil, last_modified: nil, extras: nil)` — sets the validators (with the `etag_with` context and any per-call `extras:` folded into the ETag); for a safe (GET/HEAD) request whose precondition matches, sends `304 Not Modified` and returns **false**; otherwise returns **true** (render the body). Mirrors Rails' `stale?` under a non-clashing name.
- `set_cache_validators(resource = nil, etag:, last_modified:, extras:)` — sets `ETag`/`Last-Modified` (context folded in, `Vary` merged) without short-circuiting; returns the computed `{ etag:, last_modified: }`. An explicit `etag:` is kept verbatim only when there is no context to fold in.
- `cache_etag_extras(extra = nil)` — the resolved `etag_with` values for this request plus `extra`, nils dropped; reuse it from a `cache_etag_for` override.
- `request_matches_cache?(etag:, last_modified:)` — side-effect-free predicate.
- `cache_etag_for(resource)` / `cache_last_modified_for(resource)` — override points for deriving validators.
- `apply_http_cache_headers` — the `after_action` (public: `skip_after_action` it, or override).

## Conditional-GET correctness

- **ETag** is a WEAK validator `W/"<md5>"` derived from the resource's cache key (`cache_key_with_version` → `cache_key` → a manual key; a relation/array folds its members' keys plus size). `If-None-Match` is matched with **weak comparison**, honours `*`, and accepts a comma-separated list.
- **`Last-Modified`** is an IMF-fixdate via `Time#httpdate` (not the hand-rolled ISO 8601 bug); `If-Modified-Since` is compared at **whole-second** granularity (HTTP dates carry no sub-second part).
- When BOTH `If-None-Match` and `If-Modified-Since` are sent, the **ETag wins** and the date is ignored (RFC 7232 §3.3).
- A 304 is only sent for **safe** requests (GET/HEAD), and still carries the validators **and** the `Cache-Control`/`Vary` policy (the after_action rides the 304).

## Examples

```ruby
# Collection endpoint — ETag/Last-Modified fold the relation:
def index
  @articles = Article.published
  return unless stale_resource?(@articles)
  render json: @articles
end

# An endpoint that must never be stored by any cache:
http_cache_actions :balance, no_store: true

# Custom validator (e.g. a digest of a serialized payload):
def show
  return unless stale_resource?(etag: %(W/"#{payload_digest}"))
  render json: payload
end
```

## Notes & gotchas

- **Context belongs in the ETag, not just in `Vary`.** `Vary: Accept-Language` tells caches to key on the header, but a client that switches locale and revalidates with its old ETag would still get a 304 unless the locale is part of the validator — `etag_with :locale` does both. Anything that changes the body without changing the record (fields, includes, role-based redaction) should be declared the same way.
- The method names are deliberately distinct from `ActionController::ConditionalGet`, so this concern coexists with Rails' own `fresh_when`/`stale?`.
- **Weak validators** signal semantic (not byte-for-byte) equivalence — the right choice for serialized representations that may differ in whitespace/ordering.
- `no_store: true` overrides `max_age`/`visibility`; pair `:public` caching with care behind shared CDNs and proxies.
- `Vary` is **appended**, never clobbered — coordinate with pagination/CORS headers that may also set it.
- Every `request`/`response` touch is guarded, so the concern runs on bare objects and is testable without the full Rails stack.
- For **write-side** preconditions (`If-Match` / `If-Unmodified-Since` → `412 Precondition Failed`), reach for Rails' own conditional-GET helpers; this concern covers the read path.

## Changed in 1.22.0

- `no_store` policies are also applied via `prepend_before_action`, so rescue_from-rendered errors on `no_store` endpoints carry `Cache-Control: no-store`. Positive freshness policies deliberately stay post-action — a rescued error must never become CDN-cacheable.
- `stale_resource?` no longer writes ETag/Last-Modified validators for unsafe (non-GET/HEAD) requests — a POST response must not advertise an ETag a client could replay against GET.
