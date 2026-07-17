<!-- CHANGELOG.md -->

## 1.21.0 (2026-07-01)

A new model concern for transparent field-level encryption — the "encrypt SSN/DOB at rest" capability the sensitive-data toolkit (Maskable, Sanitizable, Tokenizable) was missing. Hand-rolled on stdlib OpenSSL so it behaves identically on Rails 5.0–8, rather than delegating to Rails 7.1+ native `encrypts`. 978 examples, 0 failures.

### Added
- **Models::Encryptable**: transparent per-field encryption for sensitive columns (SSN, DOB, cards) — AES-256-GCM via stdlib OpenSSL, no new dependency (the crypto toolbox already proven in Controllers::WebhookVerifiable). `encryptable :ssn, :dob, type: :date, key: ...` (repeatable; per-field options) registers a custom `ActiveModel::Type` on the declared column, so reads/writes stay plaintext and the DB column holds a versioned, authenticated Base64 envelope (`ver|alg|key_id|iv|tag|ciphertext`, the 3-byte header fed to GCM as additional authenticated data). Because it is an immutable value type, dirty tracking compares the decrypted plaintext — a re-save of unchanged data is never spuriously dirtied by GCM's random IV, and an unchanged field is not re-encrypted. `type:` casts the decrypted value through the Storable caster set (`:string`/`:integer`/`:float`/`:decimal`/`:boolean`/`:date`/`:datetime`; `:decimal` precision-safe, `:datetime` UTC microseconds). Keys come from a gem-level config (`ConcernsOnRails.configure_encryption { |c| c.key = ... }`, memoized like `.deprecator`; a String / 64-hex / 32-byte-raw value or a lazy Proc, stretched via PBKDF2-HMAC-SHA256) or a per-field `key:` override; a missing key raises `MissingKeyError` at first use, never at class-load. Adds `<field>_ciphertext` (raw envelope) and `<field>_encrypted?` readers. Composes transparently: Normalizable normalizes plaintext before it is encrypted (order-independent), Maskable masks the decrypted value; declaring a field with BOTH `encryptable` and `auditable_by` RAISES (auditing would persist plaintext). Wrong key / tampered ciphertext / malformed envelope raise `DecryptionError` (never a raw OpenSSL error); `on_missing_key: :passthrough` and `raise_on_decrypt_error: false` are documented dev-only escape hatches. Non-deterministic by design, so encrypted columns are not queryable/searchable — deterministic equality lookups and multi-key rotation are planned follow-ups (the envelope already reserves the `alg`/`key_id` bytes). Zero new runtime dependencies.

## 1.20.0 (2026-06-18)

Two new concerns — the conditional counter cache the prior design panel held back as "too risky for one release" (1.19.0's notes), now shipped with the full update matrix specified and tested, plus the HTTP conditional-GET layer the API-oriented controller suite was missing. 933 examples, 0 failures.

### Added
- **Models::CounterCacheable**: conditional, denormalized association counters ("counter_culture-lite"). Rails' native `counter_cache: true` counts *every* `belongs_to` child into one column — it can't keep an `approved_comments_count` beside a `comments_count`, and offers no drift repair. Declared on the CHILD, `counter_cacheable_by :post` (repeatable; rules reassigned-not-mutated so subclasses inherit; `count:` defaults to `"<table_name>_count"`, `if:` an optional Ruby condition, `touch:` to bump the parent's `updated_at`) keeps one or many parent columns in sync. `after_create`/`after_update`/`after_destroy` adjust via `update_counters` — a single SQL `COALESCE(col,0) ± 1`, atomic under concurrency — inside the record's own save transaction (a rolled-back save rolls back the counter). The update path resolves the full matrix: a foreign-key reparent decrements the old parent and increments the new one; a condition flip (`if:` result changed) increments/decrements in place; a simultaneous reparent + flip composes both; a no-op save writes nothing. The previous condition state is reconstructed by transiently restoring the changed attributes to their pre-save values (`saved_changes`, `previous_changes` on 5.0). `recount_counter_caches!(association = nil)` repairs drift / backfills portably (no adapter-specific SQL: unconditional counters via `group(fk).count`, conditional via a Ruby tally), rewriting every parent. Macro-time `ArgumentError` validation: the `belongs_to` must be declared first, must not be polymorphic, the parent counter column must exist (deferred when the parent class isn't yet loadable — load-order tolerant), `:if` callable, `:touch` boolean, unknown options rejected. Zero new runtime dependencies.
- **Controllers::Cacheable**: HTTP conditional GET + declarative `Cache-Control` ("fresh_when/stale?-lite" for JSON APIs), with method names chosen NOT to shadow Rails' `ActionController::ConditionalGet`. `http_cache_actions :index, :show, max_age: 5.minutes, visibility: :public, must_revalidate:, no_store:, stale_while_revalidate:, vary:` declares a policy (repeatable; no actions = catch-all; LAST matching rule wins — the Deprecatable override convention) emitted via `after_action`; `no_store` overrides `max_age`, `Vary` is appended (deduped) to any existing header, and the policy rides a 304. `stale_resource?(resource, etag:, last_modified:)` sets the validators and, for a safe (GET/HEAD) request whose precondition matches, sends `304 Not Modified` and returns false (mirrors `stale?`); `set_cache_validators` / `request_matches_cache?` / overridable `cache_etag_for` / `cache_last_modified_for` round out the surface. Standards-correct: weak ETag `W/"<md5>"` from the resource's cache key (collections fold member keys + size), `Last-Modified` via `Time#httpdate` (not the hand-rolled-ISO8601 bug), `If-None-Match` weak comparison honouring `*` and lists, `If-Modified-Since` compared at whole-second granularity, and `If-None-Match` taking precedence over `If-Modified-Since` (RFC 7232 §3.3). Every `request`/`response` touch is guarded so it runs on bare objects. Macro-time `ArgumentError` validation for `:visibility`, durations, `:vary`, and the booleans. Zero new runtime dependencies.

## 1.19.0 (2026-06-13)

Two new concerns, selected by a unanimous three-judge design panel over six independently-proposed candidates (typed-JSON-settings and RFC-deprecation-headers each beat conditional counter caches, deep cloning, anonymization, params contracts, feature gates, and maintenance mode on value × shippability), then hardened in review (an `ActiveSupport::TimeWithZone` passed as `deprecated_at:`/`sunset_at:` — i.e. `Time.current` — was spuriously rejected as unparseable because `Module#===` ignores TimeWithZone's `is_a?(Time)` lie; a bare `Date` written to a `:datetime` key now anchors to midnight UTC instead of the host zone via `Date#to_time`; an unknown `header_format:` now raises at declaration time instead of silently emitting the RFC form). 894 examples, 0 failures.

### Added
- **Models::Storable**: typed, defaulted, optionally-validated accessors over a single JSON-or-text column ("store_attribute-lite") — native `store_accessor` is untyped on every supported Rails version (a form-submitted `"true"` stays a String), has no defaults and no per-key dirty methods. `storable_by :settings, theme: { type: :string, default: "light", in: %w[light dark] }, ...` (repeatable — same column merges keys, columns independent, subclasses add keys without mutating the parent; `prefix:`/`suffix:` affix the generated names) gives a casting reader/writer, a `?` predicate (boolean keys), `_changed?`/`_was` computed per key against the column's own previous value, and `reset_<key>` (key removal → default applies again, distinct from an explicitly-written nil, which reads back as nil). Casting via `ActiveModel::Type` with JSON-safe representations: `:decimal` as a precision-safe String, `:datetime` as UTC ISO8601 with microseconds, `:date` as ISO8601, `:json` passthrough (reader returns a dup — reassign, don't mutate). The codec never uses `serialize` (sidestepping the Rails 7.1 kwarg drift entirely): a plain text column is JSON-encoded/decoded manually and tolerantly (corrupt JSON → `{}`, garbage values cast to nil, readers never raise), while native `json`/`jsonb` columns and host-app-`serialize`d columns are detected lazily and handed the Hash. Undeclared keys are preserved; string keys throughout; `in:` adds an inclusion validation on the (affixed) accessor name, nil/absent passing. Every generated name is collision-checked against methods and columns at macro time; key specs are shape- and type-validated (`ArgumentError`, ColumnGuard for the column). Whole-column dirty / last-write-wins semantics documented. Zero new runtime dependencies.
- **Controllers::Deprecatable**: standards-based API endpoint deprecation — RFC 9745 `Deprecation` (final structured-fields form `@<unix>`, or the widely-deployed pre-RFC draft literal `true` via `header_format: :legacy`), RFC 8594 `Sunset` (IMF-fixdate via `Time#httpdate`, not the classic hand-rolled ISO8601 bug), and RFC 8288 `Link` rels (`rel="deprecation"` migration docs + `rel="successor-version"`, appended to any existing Link header, never clobbered). `deprecate_actions :index, :show, deprecated_at:, sunset_at:, link:, successor:, after_sunset:, header_format:, notify:` — repeatable, inherited; no positional actions = whole-controller catch-all; the LAST matching rule wins (deliberately the reverse of Idempotentable's first-match: deprecation rules are configuration overrides, so a base-controller catch-all is naturally overridden by a later action-specific declaration) and exactly one Deprecation header is ever emitted. Times parse eagerly at declaration (`ArgumentError` on garbage; bare dates = 00:00 UTC — sunset is an instant; `sunset_at >= deprecated_at` enforced; TimeWithZone accepted). `after_sunset: :gone` (requires `sunset_at`) halts with 410 `endpoint_sunset` at/after the boundary instant — headers still ride the 410 so the cut-off self-documents — via Respondable's `render_error` when present, inline envelope otherwise; the default `:headers` never blocks. Every matching hit instruments `deprecated_endpoint.concerns_on_rails` (`ActiveSupport::Notifications`) and `instance_exec`s `notify:` (raising notify propagates — broken metrics should be loud) through the `on_deprecated_access(rule)` override point, so teams can measure stragglers before flipping enforcement. `deprecation_active?`/`sunset_passed?` predicates for serializers; one UTC clock seam (`deprecation_now`). Zero new runtime dependencies.

## 1.18.0 (2026-06-12)

Two new concerns, designed and hardened through adversarial design- and code-review rounds (a shared-reflection registration strategy that produced invalid SQL was caught and replaced before implementation; a time-serialization path that silently lost sub-second precision likewise; a NULL page-boundary value that would have silently dropped rows now raises; a post-review pass fixed `has_many :through` aliasing, which crashed at macro time under lazy class loading and re-derived its `source:` from the alias name at query time). A follow-up enhancement round added bidirectional cursors, allow-listed order presets, and row-value predicates to CursorPaginatable, and `only:`/`except:`/`deprecated:`/`alias_foreign_key:` to Aliasable. 793 examples, 0 failures.

### Added
- **Models::Aliasable**: full association aliasing — `alias_association :writer, :author` (argument order mirrors `alias_method new, old`) gives read, write/assign, `build_`/`create_`/`create_!`/`reload_`/`reset_`, the `_ids` pair, and the query side (`joins`/`includes`/`preload`/`eager_load`/`where`-hash/`reflect_on_association`). One loaded cache under two names (`record.association(:alias)` IS the source's proxy) and only the source macro installs callbacks, so `dependent:`, counter caches, autosave and validations run exactly once. The query side registers a *renamed reflection copy* (registering the same object emits mismatched JOIN/WHERE table names — invalid SQL), with `class_name`/`foreign_key`/`foreign_type` (direct associations) or `source:` (`has_many`/`has_one :through` — resolved exactly when the through class is already loaded, anchored to the source association's own name when it is not) pinned so nothing re-derives from the alias name; the `_reflections` key form (String on <= 7.x, Symbol on newer) is probed at runtime. Aliases are inherited; re-declaring one with the same source in a subclass after redefining that source refreshes the reflection (descendant caches cleared), while repointing an existing alias at a different source raises. Collision validation sweeps every generated method name against associations, methods, columns, and virtual attributes — skipped gracefully when no database is reachable at load time. Aliases of aliases collapse to the terminal source; `has_and_belongs_to_many` is rejected (use `has_many :through`); the `belongs_to` FK attribute is not aliased by default (`alias_foreign_key: true` aliases the `<alias>_id`/`<alias>_type` pair via `alias_attribute`, collision-checked). Options: `only:`/`except:` narrow the generated method map by group (`:reader`/`:writer`/`:build`/`:reload`/`:ids`; narrowing re-declares prune their stale delegators); `deprecated:` (true or a String hint) warns through the new `ConcernsOnRails.deprecator` on every delegator call — the gradual-rename story. Zero new runtime dependencies.
- **Controllers::CursorPaginatable**: cursor/keyset pagination — the no-COUNT, concurrent-insert-stable complement to Paginatable. `cursor_paginate_by order: { created_at: :desc }, per_page: 25, max_per_page: 200` (+ per-call `order:`/`per_page:`); `cursor_paginated(scope)` returns the page (loaded Array, limit+1 has-more detection) and sets `X-Per-Page`, `X-Count` (this page — totals deliberately never computed), `X-Has-More`, `X-Next-Cursor`; `cursor_pagination_meta` memoizes for Respondable `meta:` composition. The primary key is always appended as a strict tiebreaker (duplicate values never skip/repeat rows; proven by a ties-walk spec) and the keyset WHERE is Arel OR-expansion, portable across adapters and mixed asc/desc. Cursors are opaque URL-safe Base64 tokens pinned to the table + column:direction list — malformed, tampered (non-scalar values, wrong arity), cross-model, or stale-config cursors raise `InvalidCursor`, auto-rescued to a 400 (`invalid_cursor`, `render_invalid_cursor` override point, delegates to Respondable) on any Rescuable controller. Boundary timestamps serialize at microsecond precision (`iso8601(6)`) and cast back through the model's attribute types so each adapter quotes natively. Ordering columns are chosen in code only, validated against the schema; `reorder` defeats `default_scope` ordering; composite/PK-less tables raise `ArgumentError`, as does a NULL ordering value on a page-boundary row (which would otherwise silently drop rows — SQL three-valued logic). Opt-in extras: `bidirectional: true` mints `X-Prev-Cursor`/`X-Has-Prev` (backward fetches walk the inverted ordering and flip back to canonical order; direction is pinned in the token, so prev tokens replayed at forward-only endpoints 400 and pre-bidirectional tokens stay valid forward cursors); `order_presets:`/`default_preset:`/`order_param:` give clients allow-listed named orderings (unknown names → 400 `invalid_order_preset`; switching presets mid-walk invalidates the cursor); `predicate: :auto` upgrades the keyset WHERE to a composite-index-friendly row-value tuple `(a, b, id) > (x, y, z)` on PostgreSQL/MySQL/SQLite under uniform directions, falling back to the portable OR-expansion (`:row` forces tuples and raises on mixed directions; `:or` forces the expansion). Zero new runtime dependencies (URL-safe Base64 via `pack("m0")`, as in WebhookVerifiable).

## 1.17.0 (2026-06-10)

Two new concerns, hardened by two adversarial review rounds (in-memory state is restored when a raising lock/unlock hook rolls the write back, so retries can't silently no-op; a hook aborting via `ActiveRecord::Rollback` makes `lock_access!`/`unlock_access!` return false instead of a fake success; invalid-UTF-8 signature headers fail closed instead of raising). 679 examples, 0 failures.

### Added
- **Models::Lockable**: failed-attempt tracking + account lockout ("Devise lockable-lite") for apps on Rails 8 native auth / `has_secure_password`. `lockable_by attempts: :failed_attempts, locked_at: :locked_at, max_attempts: 5, unlock_in: 15.minutes, prefix:/suffix:` — `register_failed_attempt!` increments SQL-side (`update_counters`: atomic under concurrency, NULL-coalescing) and auto-locks at the threshold; `access_locked?` / `lock_expired?` / `lock_expires_at` / `attempts_remaining` readers are side-effect free with lazy expiry (the boundary instant counts as unlocked); `lock_access!` / `unlock_access!` persist via `update_columns` (validations/callbacks bypassed so an invalid record can still be locked) with `before/after_lock`, `before/after_unlock` hooks in a transaction; `reset_failed_attempts!` is the hook-free successful-login path; expiry-aware `.locked` / `.unlocked` scopes (affixable, Ruby-computed cutoff so the SQL stays portable). An expired lock is cleared quietly on the next failed attempt — no unlock hooks fire from an attacker's guess. The attempts column is validated to be an integer column. Zero new runtime dependencies.
- **Controllers::WebhookVerifiable**: HMAC signature verification for inbound webhooks (Stripe/GitHub/Shopify and generic `:hex`/`:base64`). `verify_webhook *actions, secret:, scheme:, header:, tolerance:, digest:` appends rules (first match wins; no actions = catch-all); the `verify_webhook_signature!` before_action (public, skip-able) renders 401 (`webhook_signature_missing`/`webhook_signature_invalid`/`webhook_timestamp_stale`) or 400 (`webhook_signature_malformed`) and halts the action. Comparison is constant-time (digest-collapsed `secure_compare`, portable to Rails 5.0) and the attacker-controlled header is never decoded — garbage including invalid UTF-8 is scrubbed and fails closed instead of raising. Stripe: signs `"#{t}.#{body}"`, tries every `v1` (≤16), ignores unknown keys, first `t` feeds both the symmetric tolerance check (default 300s) and the payload so a re-stamped stale header stays dead. Secrets: String / callable (`instance_exec`'d per request, multi-tenant) / Array (rotation, any match passes); a secret resolving blank at request time raises `ArgumentError` (misconfiguration should page, not 401 into the provider's retry loop). `:shopify`/`:base64` encode via `pack("m0")` (no base64-gem dependency on Ruby 3.4). Delegates error bodies to `render_error` when Respondable is present. Zero new runtime dependencies.

## 1.16.0 (2026-06-10)

Two new concerns, hardened by an adversarial edge-case review. 574 examples, 0 failures.

### Added
- **Models::Auditable**: lightweight single-column change history ("paper_trail-lite"). `auditable_by :price, :status, into: :audit_log, actor: -> { Current.user&.email }, max_entries: 100` appends one JSON entry per changed field per save (creates record `from: nil`) into one text column — no extra tables, written in the same INSERT/UPDATE via `before_save`. Readers: `audit_trail`, `last_change_for(:field)`, `audited_changes_since(time)`, `clear_audit_trail!`. Tolerant JSON decode (corrupt column → `[]`), newest-N trimming (default 200), opt-in value truncation (`max_value_length:` stores the first N characters of long String values + `…`), values JSON-coerced (times → ISO8601 UTC, BigDecimal → precision-safe string, non-finite floats → `"NaN"`/`"Infinity"` strings), `"by"` omitted when no actor. Entries build on the persisted trail, so a save aborted by a later callback cannot duplicate entries on retry. Zero new runtime dependencies.
- **Controllers::Idempotentable**: Stripe-style `Idempotency-Key` support with an injectable store (`self.idempotency_store = Rails.cache`; contract: `#read`, `#write(expires_in:, unless_exist:)`, `#delete` — no in-process default on purpose). `idempotent_actions :create, ttl: 24.hours, lock_ttl: 1.minute, header: "Idempotency-Key", required: false` claims each key atomically, caches 2xx–4xx responses and replays them with `X-Idempotency-Replayed: true`; concurrent duplicates get 409 + `Retry-After`, payload mismatches get 422 (`idempotency_key_reuse`, fingerprint overridable), 5xx/exceptions release the claim so retries re-execute. Keys are validated (≤255 chars, control characters rejected to prevent response-header injection via the echoed `X-Idempotency-Key`), SHA256-hashed, and scoped per `controller#action`. Error bodies delegate to `render_error` when Respondable is present. Zero new runtime dependencies.

## 1.15.0 (2026-06-10)

A review-driven release: 23 correctness/safety fixes (each with a regression spec) and 7 backward-compatible enhancements. 510 examples, 0 failures.

### Fixed
- **Controllers::SecureHeadable**: `content_security_policy_for(report_only: true)` no longer silently drops the policy block — the policy is defined via `content_security_policy` and report-only mode is toggled separately (a report-only rollout previously registered no policy at all).
- **Controllers::Authorizable**: `require_role` / actor resolution now find a private or `helper_method` `current_user` (`respond_to?(.., true)`), so Devise-style private `current_user` is no longer denied.
- **Controllers::Sortable**: uses `reorder` so the requested sort replaces a model `default_scope` ORDER BY instead of becoming a silent secondary key.
- **Controllers::Paginatable**: the total count no longer breaks on grouped relations (it returned a Hash); it collapses to the group count.
- **Controllers::Filterable**: a nested-hash param in direct-where mode no longer raises a user-triggerable 500 — non-scalar values are ignored.
- **Controllers::Localizable**: the `Accept-Language` parser honors q-values (rejects `q=0`, orders by preference) per RFC 7231.
- **Controllers::ErrorHandleable**: the 404 handler renders a generic message instead of the raw `RecordNotFound` message, which leaked the model class name and queried attribute/value.
- **Models::SoftDeletable**: `deleted_within` uses an explicit `>=` predicate (the previous endless range was unsupported on Rails 5.x); `soft_delete_all` / `restore_all` roll the whole batch back when a record fails.
- **Models::Sluggable**: backfills a blank slug on save even when the source is unchanged, and no longer overwrites an explicitly-assigned slug.
- **Models::Publishable**: scopes branch on the column type so a boolean publishable column uses equality predicates instead of nonsensical timestamp comparisons.
- **Models::Hashable**: validates that `length` is positive; `:integer` drops dead padding code.
- **Models::Taggable**: `tagged_with` matches consistently (all branches use LIKE) and escapes the delimiter so a wildcard delimiter matches literally.
- **Models::Monetizable** / **Support::Money**: no spurious `-` for amounts that round to zero; `subunit_to_unit: 0` is rejected.
- **Models::Sequenceable**: the generation-time clock is memoized so a record's period anchor stays consistent (no boundary straddle).
- **gemspec**: `spec.metadata` is merged rather than reassigned, preserving the `license` key.

### Added
- **Models::Activatable** / **Models::Expirable**: `prefix:` / `suffix:` options to affix scope names, so `.active` / `.expired` can coexist with the same-named scopes from sibling concerns on one model.
- **Models::Publishable**: `before/after_publish` and `before/after_unpublish` lifecycle hooks.
- **Models::Stateable**: `before/after_transition` hooks fired by guarded `<event>!` transitions.
- **Models::Hashable**: `unique: true` retries on an in-Ruby collision before insert (parity with Tokenizable).
- **Controllers::Sortable**: applies multiple whitelisted columns from a comma-separated `params[:sort]`.
- **Controllers::Paginatable**: `pagination_meta(relation)` for body-based pagination (composes with `Respondable`'s `meta:`).

### Changed
- **Controllers::ErrorHandleable**: the default 404 message is now generic (`"Resource not found"`); override `handle_record_not_found` to surface detail in non-production environments.

### Docs
- Rewrote `CLAUDE.md` to cover all 29 concerns and 7 support modules, the model/controller layout, the macro conventions, the supported dependency ranges, and the release process.
- Noted native Rails 7.1+ alternatives (`normalizes`, `generates_token_for`) in `Normalizable` / `Tokenizable`.

## 1.14.1 (2026-06-07)

### Fixed
- **gemspec**: `source_code_uri` now points to the GitHub repository (`https://github.com/VSN2015/concerns_on_rails`) instead of the documentation site, so RubyGems' "Source Code" link resolves to the actual source again (it had been set to the Pages homepage in 1.14.0).

### Docs
- Added a GitHub Pages documentation site covering all 29 concerns (model + controller) — per-concern pages, search, and copyable examples.
- SPA: shared/deep links to in-page section anchors (e.g. `#api`, `#features`) now render the page instead of hanging on the loading placeholder.
- Landing page: corrected the `SoftDeletable` example to `#soft_delete!` / `#restore!` (instance `destroy` is a hard delete — only the class `destroy_all` soft-deletes), and replaced a non-existent `respond_*` reference with the real `render_success` / `render_error` helpers.
- Fixed two `Includable` doc examples that used an invalid controller constructor; added Open Graph / Twitter Card metadata for link previews.

## 1.14.0 (2026-06-06)

### Added
- **Controllers::Authorizable**: declarative, block-only per-action authorization gate. `authorize_by { current_user.admin? }` (arity-safe — also `|action|` / `|action, user|`) halts the first failing rule with 403; `require_role :admin, :editor, only: :publish` is sugar over the common role check. `only:` / `except:` scope a rule to a subset of actions. When `Respondable` is included the denial delegates to `render_error` (`code: "forbidden"`), otherwise the same envelope is rendered inline. Deliberately not a policy/ability framework (no policy objects, no ability DSL, no resource inference). Zero new runtime dependencies.
- **Controllers::Throttleable**: per-request rate limiting with a store-agnostic, injectable backend. `throttle_by limit: 100, period: 1.minute` (bucketed per-IP by default, or by any `by:` lambda) halts an over-limit request with 429 plus `Retry-After` and `X-RateLimit-Limit` / `X-RateLimit-Remaining` / `X-RateLimit-Reset`. Fixed-window counter keyed by a floored time bucket; requires an explicit atomic store (`self.throttleable_store = Rails.cache`) — there is no silent in-process default, so the first throttled request raises until one is configured. Backports the essentials of Rails 7.2's `rate_limit` (with standardized headers) to Rails 5.0+. Zero new runtime dependencies.
- **Controllers::Timezoneable**: per-request `Time.zone` selection via an `around_action` (`Time.use_zone`) — the time analogue of `Controllers::Localizable`. `timezoneable available: [...], default: "UTC"` resolves from `params` → `Time-Zone` header → cookie → default, every candidate validated through `ActiveSupport::TimeZone[...]` so it can never raise at request time; an unknown configured zone fails fast at declaration. Options `param:` / `header:` / `cookie:`. Zero new runtime dependencies.

### Notes
- All changes are additive and backward-compatible, with zero new runtime dependencies. The three new controller concerns stay namespace-only (`ConcernsOnRails::Controllers::*`), matching the existing controller concerns.

## 1.13.0 (2026-06-06)

### Added
- **Models::Maskable**: non-destructive display masking for sensitive attributes. `maskable :email, with: :email` adds a `masked_<field>` reader and never writes the column (the raw value stays in the DB). Presets `:email` / `:phone` / `:credit_card` / `:last4` / `:all`, a configurable `mask:` character, and a `Proc` escape hatch. Backed by `Support::Masker`; complements `Sanitizable`.
- **Models::Monetizable**: exact, float-free money handling over an integer subunit column. `monetizable :price_cents` derives `price` / `price=` / `formatted_price` (the `_cents` suffix is stripped, or name them with `as:`). Options `unit:` / `precision:` / `delimiter:` / `separator:` / `subunit_to_unit:`. Uses `BigDecimal` throughout; backed by `Support::Money`.
- **Controllers::Localizable**: per-request locale selection from `params` and/or the `Accept-Language` header via an `around_action` (`I18n.with_locale`). `localizable available: %i[en fr], default: :en`; options `param:` / `header:`. The resolved locale is always validated against `I18n.available_locales`, so it can never raise `I18n::InvalidLocale`.

### Notes
- All changes are additive and backward-compatible, with zero new runtime dependencies (BigDecimal and I18n already ship with the existing stack). `ConcernsOnRails::Maskable` / `ConcernsOnRails::Monetizable` are aliased to their `Models::*` modules; the controller concern stays namespace-only (`ConcernsOnRails::Controllers::Localizable`).

## 1.12.1 (2026-06-06)

### Added
- **Models::Sanitizable**: opt-in HTML sanitization for string attributes — defense-in-depth on top of Rails' default output escaping (not a replacement for it). `sanitizable :body, with: :safe_list` is **non-destructive by default** (`on: :read`): it adds a `sanitized_<field>` reader and leaves the stored column raw. `on: :write` is an explicit, lossy opt-in that overwrites the column in `before_validation` (so presence/length validations see the cleaned value). Presets: `:strip` (remove all tags), `:safe_list` (Rails' allow-list), `:no_links`, `:none`, plus custom `Array` / `Hash` (`{ tags:, attributes: }`) allow-lists and a `Proc` escape hatch. Schema-checked via `ColumnGuard`. Zero new runtime dependencies.
- **Controllers::SecureHeadable**: modern security response headers + a thin delegation to Rails' native Content-Security-Policy DSL. `secure_headers :nosniff, :sameorigin_frame, :no_referrer_leak, :no_cross_domain, :disable_legacy_xss` (and custom `"Header-Name" => "value"` pairs), applied in an `after_action`. `content_security_policy_for(report_only:, only:, except:, …, &block)` forwards straight to Rails. Ships `X-XSS-Protection: 0` (the only correct modern value) and deliberately does **not** scrub params. Zero new runtime dependencies.
- **Support::HtmlSanitizers**: shared, lazily-memoized, feature-detected (HTML5/HTML4) `FullSanitizer` / `SafeListSanitizer` / `LinkSanitizer` instances backing `Models::Sanitizable`, reusing the `rails-html-sanitizer` that already ships with Action View.

### Notes
- All changes are additive and backward-compatible. `ConcernsOnRails::Sanitizable` is aliased to `Models::Sanitizable`; the controller concern stays namespace-only (`ConcernsOnRails::Controllers::SecureHeadable`), matching the existing controller concerns.
- These features were first tagged as `1.12.0`, but that tag's CI lint failed before the RubyGems publish step, so it was never released. `1.12.1` is the first published version carrying them.

## 1.11.2 (2026-06-06)

### Added
- **Models::Taggable**: Lightweight, dependency-free tagging over a single string column (no join tables, no tagging engine; works on any database including SQLite). `taggable_by :tags` adds `tag_list` get/set (accepts a String or an Array, stripped + de-duped), `add_tags` / `remove_tags`, a `tagged_with?` predicate, a boundary-safe `tagged_with(*tags, any:)` class scope (AND by default, OR with `any: true`), and `all_tags`. Options: `delimiter:` and `downcase:`. Reach for `acts-as-taggable-on` when you need tag contexts, ownership, or tag clouds.
- **Models::SoftDeletable**: `soft_deletable_by` gained `default_scope:` (default `true`) to opt out of the deleted-hiding `default_scope`; new explicit `soft_delete_all` class method (preferred over the `destroy_all` override).
- **Models::Sluggable**: `sluggable_by` gained `reserved_words:` (reject slugs like `new` / `edit` / `admin` — saving such a record fails validation) and `finders: true` (`Model.find` accepts a slug directly), layering friendly_id's `:reserved` / `:finders` modules.
- **Models::Sortable**: `sortable_by` now threads acts_as_list's `scope:` (independent position sequence per group) and `add_new_at:` (`:top` / `:bottom`) options through to `acts_as_list`.

### Fixed
- **Models::SoftDeletable**: `soft_delete!` / `restore!` (and the bulk `soft_delete_all` / `restore_all` / `destroy_all`) now run inside a transaction, so a raising `before_*` / `after_*` hook rolls the timestamp change back instead of leaving a half-applied state — adopting `discard`'s transactional playbook.

### Notes
- All changes are backward-compatible: the soft-delete `default_scope` stays on by default and `destroy_all` continues to soft-delete. New models are encouraged to set `default_scope: false` and use the explicit `soft_delete_all`.

## 1.11.1 (2026-06-05)

### Added
- **Models::Addressable**: `addressable_by` gained four options:
  - `lengths:` — per-part length limits (`{ line1: 100, city: 3..50 }`); an Integer is a positive maximum, a Range is `min..max` (inclusive/exclusive, endless, and beginless all supported). Length is measured on the normalized value; messages mirror Rails (singular/plural). Bad bounds raise an `ArgumentError` at load time.
  - `allow_blank:` — per-field opt-out (an Array of parts, or `true`) for the length check when a value is blank. Independent of `required:`.
  - `normalize_country:` — opt-in canonicalization of a country value to its ISO 3166-1 alpha-2 code: a recognized English name (`"Canada"`) or 3-letter alpha-3 (`"CAN"`) maps to the alpha-2 (`"CA"`); unrecognized values are left untouched. Lets postal/state validation recognize a named country.
  - `if:` / `unless:` — standard Rails validation conditions (Symbol, Proc, or Array) gating the address validations. Normalization still runs unconditionally.

### Fixed
- **Models::Addressable**: a present-but-unrecognized country (e.g. a full name with `normalize_country` off, or an invalid code) no longer borrows the `default_country`'s postal/state rules. It now falls back to the permissive postal pattern and skips state validation, so valid foreign postal codes aren't rejected against the wrong country. `default_country` still applies when the country column is absent or blank.

### Internal
- **Support::AddressData**: added `COUNTRY_DATA` (all 249 ISO 3166-1 countries → `[name, alpha-3]`) as the single source of truth; `ISO_COUNTRY_CODES` and the name / alpha-3 lookups are derived from it, and a new `normalize_country_code` backs the country normalization.

## 1.10.0 (2026-06-03)

### Added
- **Models::Addressable**: Declarative postal-address normalization + format validation via a single `addressable_by` macro. Maps the canonical parts (`line1` / `line2` / `city` / `state` / `postal_code` / `country`) onto real columns — any subset works, missing columns are skipped, and required parts are schema-checked. Normalizes in `before_validation` (strip + squish, postal-code upcasing with canonical CA spacing, 2-letter country/state codes upcased) and validates required-part presence, ISO 3166-1 alpha-2 country codes, per-country postal formats (US/CA/GB/AU/DE/FR + a permissive fallback), and opt-in US/CA state codes. Offline and dependency-free; layer real deliverability checks via the opt-in `verify_with:` callable. Adds helpers `full_address`, `address_lines`, `address_present?`, `address_complete?`, and `address_attributes`.

### Internal
- Added `ConcernsOnRails::Support::AddressData` — ISO 3166-1 alpha-2 country codes, per-country postal-format patterns, US state / CA province sets, and the case-insensitive lookups (`valid_country?`, `postal_format_for`, `valid_state?`, `normalize_postal`) backing the Addressable concern.

## 1.9.0 (2026-05-25)

### Added
- **Models::Stateable**: Lightweight string-backed state machine — predicates (`draft?`, `published?`), scopes (`Article.draft`), direct setters (`published!`), guarded transitions (`publish!` / `may_publish?`) with optional `transitions:` config, generic `transition_to!`, and a configurable default applied via `after_initialize`. Supports `prefix:` / `suffix:` to avoid name clashes. Raises `Stateable::InvalidTransition` for disallowed state changes.
- **Controllers::Includable**: Whitelisted association sideloading + sparse fieldsets for JSON APIs. `includable :author, :comments, fields: { articles: %i[id title] }` declares an allow-list; `with_includes(relation)` applies only the requested, permitted associations; `requested_includes` / `requested_fields` return sanitized values to pass directly to serializers.
- **Models::SoftDeletable**: New scopes `with_deleted` (all records including deleted), `only_deleted` (alias for `soft_deleted`), `deleted_within(duration)` (recently deleted in a time window); new class method `restore_all` (bulk-restores all soft-deleted records).
- **Models::Publishable**: New scopes `scheduled` (future `published_at`) and `draft` (nil `published_at`); predicates `scheduled?` / `draft?`; mutator `publish_at!(time)` for scheduling a future publish; opt-in `publishable_by :published_at, default_scope: true` to hide unpublished records from `.all` (default is off).
- **Models::Searchable**: New options — `mode: :all` (AND all whitespace-separated terms across fields instead of OR), `match: :prefix` (anchors at start) / `match: :exact` (full match) / `match: :contains` (default, substring); option validation raises `ArgumentError` for unknown values.
- **Models::Sluggable**: New options — `history: true` (keeps slug history via the `friendly_id_slugs` table so old slugs still resolve) and `scope: :account_id` (slug uniqueness scoped to a foreign-key column). Both delegate to `friendly_id`'s built-in `:history` / `:scoped` modules.

### Internal
- Extracted duplicated column-existence checks from all 11 model concerns into `ConcernsOnRails::Support::ColumnGuard`. Error messages are now unified: `"<Concern>: '<field>' does not exist in the database (table: <table>)"` — the `/does not exist/` substring is preserved across all concerns.
- Extracted duplicated random-value generation (`Hashable` `:custom` branch + `Tokenizable`) into `ConcernsOnRails::Support::RandomValue`. No behavior change.

## 1.8.2 (2026-05-22)

### Internal
- Regenerated `Gemfile.lock` so the pinned `concerns_on_rails` version matches the gemspec. No behavior change.

### Notes
- The `v1.8.1` tag was pushed but failed CI (`bundle install --deployment` rejected the stale `Gemfile.lock`); `1.8.2` is the first usable release of the Tokenizable concern.

## 1.8.1 (2026-05-22)

### Internal
- Refactored `Models::Tokenizable` `class_methods` blocks to satisfy `Metrics/BlockLength`. No behavior change.

### Notes
- The `v1.8.0` tag was pushed but failed RuboCop; `1.8.1` is the first usable release of the Tokenizable concern.

## 1.8.0 (2026-05-22)

### Added
- **Models::Tokenizable**: Security-token generation for API keys, invite codes, share links, password-reset tokens. Each `tokenizable_by` call adds an independently-configured field (one model can hold many tokens). Defaults to 32-char URL-safe values; also supports `:hex`, `:alphanumeric`, and `:numeric` types with a configurable `length:`. Auto-generates on create with best-effort uniqueness retry, and provides `regenerate_<field>!`, `revoke_<field>!`, `<field>?`, and a timing-safe `.authenticate_by_<field>` class method.

## 1.7.0 (2026-05-21)

### Added
- **Models::Searchable**: LIKE-based search across one or more columns via `searchable_by :title, :body`. Adds a `.search(query)` scope that uses Arel's `matches` (emits `ILIKE` on Postgres, `LIKE` elsewhere), ORs predicates across all configured fields, escapes user input so `%` / `_` / `\` are treated as literals, and returns the full relation for blank queries.
- **Models::Activatable**: Boolean active/inactive toggle via `activatable_by` (defaults to the `:active` column). Adds `.active` / `.inactive` scopes (treats `NULL` as inactive), predicates (`active?`, `inactive?`), and mutators (`activate!`, `deactivate!`, `toggle_active!`).
- **Controllers::ErrorHandleable**: `rescue_from` handlers for `ActiveRecord::RecordNotFound` (404), `ActionController::ParameterMissing` (400), and `ActiveRecord::RecordInvalid` (422) that render the same JSON envelope as `Respondable#render_error`. Each handler is overridable for custom wording. Pairs naturally with `Respondable`.

## 1.6.0 (2026-05-19)

### Added
- **Models::Normalizable**: Declarative attribute normalization via `before_validation`. Supports built-in presets (`:email`, `:phone`, `:whitespace`, `:squish`, `:downcase`, `:upcase`) and custom lambdas. Works on Rails 5+ (no dependency on Rails 7.1's `normalizes`).
- **Controllers::Paginatable**: Offset-based pagination via `paginated(relation)` with `X-Total-Count` / `X-Page` / `X-Per-Page` / `X-Total-Pages` response headers. No Kaminari/will_paginate dependency.
- **Controllers::Filterable**: Declarative URL-param filtering via `filter_by` with three modes (direct `where`, named `scope:`, custom `with:` lambda). Pairs naturally with the model concerns (e.g., drive `Publishable.published` from a URL param).
- **Controllers::Sortable**: URL-param-driven ordering with a strict allow-list of sortable columns. Safe by default — non-whitelisted columns fall back to the configured default.
- **Controllers::Respondable**: Standardized JSON envelopes — `render_success(data:, status:, meta:)` and `render_error(message:, status:, code:, errors:)`.

### Changed
- Concerns are now organized under `ConcernsOnRails::Models::*` and `ConcernsOnRails::Controllers::*` namespaces. The pre-1.6 paths (`ConcernsOnRails::Sluggable`, etc.) continue to work as aliases — no migration is required.

## 1.5.0 (2026-05-16)

### Added
- Expirable: Single-timestamp expiry for tokens, API keys, sessions, and similar records. Adds `expirable_by` macro, `.active` / `.expired` / `.expiring_within(duration)` scopes, predicates (`active?`, `expired?`), mutators (`expire!`, `extend_expiry!`), and `time_until_expiry`. `nil` expiry means "never expires"; the expiry boundary is exclusive.

## 1.4.2 (2026-05-16)

### Added
- Schedulable: Manage time-windowed records via `starts_at` / `ends_at` columns. Adds `schedulable_by` macro, scopes (`.current`, `.upcoming`, `.expired`, `.active_at(time)`), predicates (`current?`, `upcoming?`, `expired?`, `active_at?`), and mutators (`start!`, `finish!`, `reschedule!`). Supports custom column names and open-ended schedules (`starts_at: nil`).

### Internal
- Refactored `active_at?` into two private predicate helpers (`schedulable_started_by?` / `schedulable_not_ended_at?`) to satisfy `Metrics/CyclomaticComplexity`.

### Notes
- The `v1.4.0` and `v1.4.1` tags were created but never released to RubyGems (CI failed on `Gemfile.lock` regeneration and a RuboCop complexity check respectively). `1.4.2` is the first usable release of the Schedulable concern.

## 1.3.0 (2026-05-16)

### Added
- Hashable: Auto-generate a random value on create (`:hex`, `:uuid`, `:integer`, or `:custom` alphabet). Adds `hashable_by` macro and a dynamic `regenerate_<field>!` instance method.

## 1.1.0 (2025-04-17)

### Added
- SoftDeletable: Add soft delete concern with configurable field, scopes, callbacks, and default_scope support

## 1.0.0 (2025-04-12)

### Added
- Initial release

### Fixed
- None