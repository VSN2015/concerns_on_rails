The `WebhookVerifiable` concern adds HMAC **signature verification for inbound webhooks** — the receiving side of Stripe, GitHub, and Shopify-style integrations. A `before_action` recomputes the HMAC over the **raw request body** and compares it (constant-time) against the provider's signature header; the action runs only when they match, otherwise a 401/400 is rendered and the action never executes. Zero extra dependencies — just OpenSSL and ActiveSupport.

## When to use it

- Receiving Stripe / GitHub / Shopify webhooks without pulling in each provider's SDK just for verification.
- Internal service-to-service callbacks signed with a shared secret (`:hex` / `:base64` schemes).
- Multi-tenant platforms where each tenant has its own webhook secret (callable secrets read `params`).
- Secret rotation windows where old and new secrets must both verify (Array secrets / Stripe multi-`v1`).
- Any endpoint that must reject forged or replayed deliveries **before** business logic, rate limits, or idempotency caching run.

## Installation

```ruby
class WebhooksController < ApplicationController
  include ConcernsOnRails::Controllers::WebhookVerifiable   # declare BEFORE Idempotentable

  skip_before_action :verify_authenticity_token   # webhook POSTs carry no CSRF token

  verify_webhook :stripe,  secret: -> { ENV["STRIPE_WEBHOOK_SECRET"] },    scheme: :stripe
  verify_webhook :github,  secret: -> { ENV["GITHUB_WEBHOOK_SECRET"] },    scheme: :github
  verify_webhook :shopify, secret: [ENV["NEW_SECRET"], ENV["OLD_SECRET"]], scheme: :shopify  # rotation
  verify_webhook :custom,  secret: "s3cr3t", scheme: :hex, header: "X-Acme-Signature"
  # verify_webhook secret: ...   # no actions = catch-all (declare specific rules first)

  def stripe
    event = JSON.parse(request.raw_post)   # parse the raw body — it is what was signed
    # ...
    head :ok
  end
end
```

## Configuration

### `verify_webhook(*actions, secret:, scheme: :hex, header: nil, tolerance: nil, digest: :sha256)`

Each call appends a rule; the **first** rule matching the current action wins (no actions = catch-all, so declare specific rules first). Invalid configuration raises `ArgumentError` at class-load time.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `*actions` | `Symbol`s | none (catch-all) | Actions this rule covers. |
| `secret:` | `String`, callable, or `Array` | — (required) | Callables are `instance_exec`'d per request (read `params` for multi-tenant secrets); an Array means rotation — any match passes. Resolving **blank at request time raises `ArgumentError`**. |
| `scheme:` | `Symbol` | `:hex` | One of the schemes below. |
| `header:` | `String` | scheme preset | Required for `:hex`/`:base64` (they have no standard header); overrides the preset for the others. |
| `tolerance:` | positive duration | `300` (Stripe only) | Replay window for `:stripe` — rejects `\|now − t\| > tolerance`. Raises if passed with any other scheme. |
| `digest:` | `Symbol` | `:sha256` | `:sha1`/`:sha512` allowed for `:hex`/`:base64` only; the provider presets pin SHA256. |

### Schemes

| Scheme | Header (default) | Expected value |
|--------|------------------|----------------|
| `:github` | `X-Hub-Signature-256` | `sha256=<hex HMAC of body>` (the prefix is part of the comparison) |
| `:shopify` | `X-Shopify-Hmac-Sha256` | strict Base64 of the binary HMAC |
| `:stripe` | `Stripe-Signature` | `t=<unix>,v1=<hex>[,v1=…]` — the signed payload is `"#{t}.#{body}"`; every `v1` is tried (key rolls); unknown keys (`v0=`…) are ignored |
| `:hex` | — (`header:` required) | plain hex HMAC of the body |
| `:base64` | — (`header:` required) | strict Base64 HMAC of the body |

### Failure responses

| Condition | Status | Code |
|-----------|--------|------|
| Header absent or blank | 401 | `webhook_signature_missing` |
| Signature does not match | 401 | `webhook_signature_invalid` |
| Stripe `t` outside the tolerance (stale **or** future) | 401 | `webhook_timestamp_stale` |
| Stripe header unparseable (missing/non-numeric `t`, no `v1`) | 400 | `webhook_signature_malformed` |

Bodies use the gem's standard envelope `{ "success": false, "error": { "message": ..., "code": ... } }`, delegating to `Respondable#render_error` when that concern is included.

## Methods

| Signature | Description |
|-----------|-------------|
| `verify_webhook_signature!` | The registered `before_action` — public and named so tests can `skip_before_action :verify_webhook_signature!`. |
| `webhook_verified? → Boolean` | `true` once the current request's signature has verified. |
| `webhook_verification_failed(message:, status:, code:)` | The single failure funnel — override it to customize logging, status, or body. |

## Examples

**Stripe with a custom tolerance:**

```ruby
verify_webhook :stripe, secret: -> { ENV["STRIPE_WEBHOOK_SECRET"] },
               scheme: :stripe, tolerance: 10.minutes
```

**Multi-tenant secrets:**

```ruby
verify_webhook :inbound,
               secret: -> { Shop.find(params[:shop_id]).webhook_secret },
               scheme: :shopify
```

**Signing a test request in specs:**

```ruby
signature = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new("SHA256"), secret, body)
post "/webhooks/custom", params: body, headers: { "X-Acme-Signature" => signature }
```

**Pairing with Idempotentable** (verify first, then dedupe retries):

```ruby
class WebhooksController < ApplicationController
  include ConcernsOnRails::Controllers::WebhookVerifiable   # 1st: authenticity
  include ConcernsOnRails::Controllers::Idempotentable      # 2nd: replay caching

  verify_webhook :stripe, secret: -> { ENV["STRIPE_WEBHOOK_SECRET"] }, scheme: :stripe
  self.idempotency_store = Rails.cache
  idempotent_actions :stripe
end
```

## Notes & gotchas

- **Order matters.** Declare this before `Idempotentable` — a 401 produced *inside* its around filter would be cached and replayed for the full TTL. Verifying before `Throttleable` keeps forged traffic from consuming legitimate rate budget (one HMAC is cheap).
- **The raw body is the contract.** The signature covers the exact bytes the provider sent — parse `request.raw_post` in your action; re-serializing `params` may not round-trip byte-for-byte, and middleware that rewrites the body breaks verification.
- **Never decoded, constant-time.** The attacker-controlled header value is compared against the *encoded* expected signature via digest-collapsed `secure_compare` — garbage, wrong encodings, and invalid UTF-8 bytes simply fail with 401; they cannot raise.
- **Blank secrets raise.** A secret that resolves to `nil`/`""` at request time raises `ArgumentError` (500) instead of 401-ing every delivery — a misconfigured endpoint should page you, not retry into a black hole. Use `-> { ENV[...] }` so the env var is read per request, not at boot.
- **Stripe specifics.** The first `t` in the header feeds both the tolerance check and the signed payload, so appending a fresh `t` to a captured stale header cannot resurrect it. The tolerance window is symmetric (future timestamps are rejected too). At most 16 `v1` candidates are considered.
- **CSRF and auth filters are your job.** Webhook endpoints need `skip_before_action :verify_authenticity_token` and should be excluded from session-auth filters.
- **No raw-body buffering concerns**: verification is a single HMAC pass over `request.raw_post`, which Rails has already read.
