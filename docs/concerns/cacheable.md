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

All option errors raise `ArgumentError` at declaration time (bad `:visibility`, non-positive durations, blank `:vary`, non-boolean flags).

## Methods

- `stale_resource?(resource = nil, etag: nil, last_modified: nil)` — sets the validators; for a safe (GET/HEAD) request whose precondition matches, sends `304 Not Modified` and returns **false**; otherwise returns **true** (render the body). Mirrors Rails' `stale?` under a non-clashing name.
- `set_cache_validators(resource = nil, etag:, last_modified:)` — sets `ETag`/`Last-Modified` without short-circuiting; returns the computed `{ etag:, last_modified: }`.
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

- The method names are deliberately distinct from `ActionController::ConditionalGet`, so this concern coexists with Rails' own `fresh_when`/`stale?`.
- **Weak validators** signal semantic (not byte-for-byte) equivalence — the right choice for serialized representations that may differ in whitespace/ordering.
- `no_store: true` overrides `max_age`/`visibility`; pair `:public` caching with care behind shared CDNs and proxies.
- `Vary` is **appended**, never clobbered — coordinate with pagination/CORS headers that may also set it.
- Every `request`/`response` touch is guarded, so the concern runs on bare objects and is testable without the full Rails stack.
- For **write-side** preconditions (`If-Match` / `If-Unmodified-Since` → `412 Precondition Failed`), reach for Rails' own conditional-GET helpers; this concern covers the read path.
