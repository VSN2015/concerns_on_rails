# concerns_on_rails 1.33.0: improvement suggestions for the existing concerns

How grounded each item is: where a bullet cites file:line, I checked it against lib at master 033981a. Bullets marked **(verify in lib)** come from the CLAUDE.md contract only, and someone should confirm the gap before acting on it. I left out everything already in 1.33.0's CHANGELOG and everything already on the maintainer backlog.

## Top 10 overall (do in this order)

1. **ErrorHandleable: map the gem's own exceptions.** These include `Stateable::InvalidTransition`, `Encryptable::DecryptionError`, `ActiveRecord::StaleObjectError`, `RecordNotUnique` and `RecordNotSaved` from the batch verbs. Today every app writes these `rescue_from`s by hand. Effort S, not breaking.
2. **Stateable: validate the state column and add `guard:` per transition.** `update(status: "bogus")` saves today, and guards are the most common reason people switch to AASM. Effort S/M. Breaking only if validation defaults on, so make it opt-in or a 2.0 default.
3. **Real model callbacks for every hooked verb** (`define_model_callbacks :soft_delete, :publish, …`), kept next to the override methods. This removes the "one override per class" limit and is non-breaking. Effort M.
4. **Tokenizable/Lockable: `digest: true` token storage.** A database leak today leaks live reset, invite and unlock tokens. The code's own comment admits it. Effort M, not breaking (opt-in).
5. **Lockable `authenticate_with_lockout`** (in the style of Devise's `valid_for_authentication?`), plus a `lock.concerns_on_rails` event. It is the one call every login controller needs, and today it is assembled by hand from three methods. Effort S.
6. **Schedulable: window validation, plus a raising bang contract and hooks for `start!`/`finish!`/`reschedule!`.** It is the only lifecycle concern without hooks, and its bangs return false. Effort S.
7. **Instrumentation events for the model verbs, plus a LogSubscriber.** Today only four controller concerns instrument anything, and the security events are invisible. Effort M.
8. **SoftDeletable: a `deleted_before` scope and a retention purge, and route `really_delete!` through Support::PrimaryKey.** Purging after a retention window is the most common soft-delete job, and the primary-key call breaks the gem's own rule. Effort S.
9. **Auditable: `without_auditing { }` and `value_at(field, time)`.** These cover bulk imports and "what was the price on date X", the two asks that push people to paper_trail. Effort S/M.
10. **A per-concern "Indexes & performance" docs section.** It would cover Searchable/Taggable LIKE scans, the SoftDeletable partial index, and the expiry/publish column indexes. Today the gem never tells you which index to add, apart from ColumnGuard's `string:uniq` hint. Effort S.

## Cross-cutting themes (ranked by impact / effort)

1. **Lifecycle hooks are override methods only.** There is no `define_model_callbacks` or `run_callbacks` anywhere in lib. Hooks are empty methods: soft_deletable.rb:411-414, publishable.rb:289-292, lockable.rb:359-362, anonymizable.rb:351-352, stateable.rb:152-153, and Stateable's per-event `before_<event>` sent via `respond_to?` at stateable.rb:697-699. As a result a model gets one override per hook, a second concern of the app's can't add its own, and there is no `if:`/`unless:`. paranoia (`before_restore`), discard (`before_discard`) and AASM all register real callbacks. Proposal: `define_model_callbacks :soft_delete, :restore, :publish, :unpublish, :expire, :activate, :deactivate, :lock, :unlock, :anonymize, :transition`. Run them inside the existing HookedWrite block, with the override methods kept as the innermost callback. Effort M, not breaking.
2. **The bang contract.** `HookedWrite.run` returns false on a veto or a validation failure (support/hooked_write.rb:43-61). As a result `publish!`, `soft_delete!` and `activate!` return false instead of raising, and Schedulable's bangs call `update` (schedulable.rb:202,209,228). Stateable's `<event>!` and Tokenizable's `regenerate_` do raise (`update!`), so the gem is inconsistent with itself and with Rails. Proposal: add non-bang `publish`/`soft_delete`/… that return a boolean now. Then make the bangs raise `ConcernsOnRails::RecordNotTransitioned < ActiveRecord::RecordNotSaved` in 2.0, behind a deprecation warning in 1.x when a bang returns false. Effort M, breaking in 2.0.
3. **Uniform instrumentation.** Only deprecatable.rb:193, error_handleable.rb:144, throttleable.rb:160 and authorizable.rb:224 call `ActiveSupport::Notifications.instrument`. Proposed events:
   - `lock_access` and `unlock_access` (Lockable; security/SIEM)
   - `anonymize` and `reencrypt` (compliance evidence)
   - `transition` (Stateable)
   - `soft_delete`, `publish` and `<verb>_all` with a row count and a `fast_path:` flag (this explains surprise slowness after #185/#154)
   - `idempotency_replay` and `idempotency_conflict`
   - `webhook_rejected`, with a reason
   - `invalid_cursor`

   Add one `ConcernsOnRails::LogSubscriber` attached in the railtie. Effort M, not breaking.
4. **ErrorHandleable should know the gem's own errors.** The gem raises `Stateable::InvalidTransition` (stateable.rb:85), `DecryptionError`, `RecordNotSaved` from BatchOps, and `MissingDependency`. Apps also routinely hit `StaleObjectError` (CounterCacheable and Lockable lean on lock_version) and `RecordNotUnique` (UniqueRetry gives up). Default mapping: 409 `conflict` for InvalidTransition, StaleObjectError and RecordNotUnique, and 500 with a scrubbed message for DecryptionError. Make them trimmable with the existing `except:`. Effort S, not breaking if opt-in via `handle_errors include: :concerns`.
5. **Secrets at rest.** Tokenizable (tokenizable.rb:72, lookup at :153) and Lockable's unlock token (lockable.rb:147) store and query the raw token. Add `digest: true`, which stores a SHA-256 (or an HMAC keyed by `ConcernsOnRails.encryption`), returns the plaintext once from `regenerate_<field>!`/create, and looks up by digest. That makes `secure_compare` unnecessary and the lookup genuinely timing-safe. Devise's reset/unlock tokens and GitHub PATs work this way. Effort M, opt-in.
6. **Sibling symmetry of verbs, hooks and batch verbs.**
   - Schedulable has no hooks and no batch verbs.
   - `publish_all` takes no time (publishable.rb:136), while `expire_all(time)` does (expirable.rb:53).
   - Lockable's batch verb is `unlock_expired` (lockable.rb:176), not `*_all`.
   - Tokenizable has no `prefix:`, though Hashable does (hashable.rb:47).

   Work through a single "verb matrix" doc table and fill the holes. Effort S each, not breaking.
7. **Docs: indexes, performance and stale comments.** No doc tells you the index to add. Searchable/Taggable LIKE `%x%` is non-sargable, so recommend `pg_trgm` GIN or MySQL FULLTEXT. SoftDeletable wants `CREATE INDEX … WHERE deleted_at IS NULL`. Publishable, Expirable and Lockable scopes want a btree on their column. Also remove stale "this gem supports Rails >= 5.0" comments (e.g. soft_deletable.rb:341-342; grep for `5.0`/`5.1`, since auditable.rb:250-264 also still carries Rails < 5.1 fallbacks that the 6.0 floor makes dead code). Effort S, not breaking.
8. **Rails 7.1+/8 interop beyond the backlog.**
   - Lockable should compose with `authenticate_by` (Rails 7.1 timing-safe login): `User.authenticate_by(...)` returning nil for a found-but-wrong-password user can't register the attempt, so document or provide the wrapper from top-10 #5.
   - Encryptable needs a documented migration path to and from `ActiveRecord::Encryption` (`encrypts`): a dual-read `reencrypt_all!` source.
   - Ruby 3.4: run the suite with `-W:deprecated` and `RUBYOPT=--enable-frozen-string-literal` (chilled strings) in one CI cell. Several modules build strings with `<<` (verify in lib).

   Effort M, not breaking.

Backlog refinement: extend the composite-primary-key item to SoftDeletable. `really_delete!` uses `where(self.class.primary_key => id)` (soft_deletable.rb:463) and `is_really_deleted?` uses `unscoped.exists?(id)` (:479), the exact form CLAUDE.md says to replace with `Support::PrimaryKey`. Also pass this to the bug hunters.

## Per-concern improvements: model concerns

### SoftDeletable
- **SoftDeletable: retention scope and purge verb.** Why: `deleted_within(duration)` (soft_deletable.rb:345) answers "recent trash", but retention jobs need "older than". Today that means `only_deleted.where(arel…)` by hand. What: add a `deleted_before(time_or_duration)` scope (affixable via SCOPE_BASES) so `only_deleted.deleted_before(30.days).really_destroy_all` reads naturally. Optionally add `soft_deletable_by retain_for: 30.days` with `purge_expired_trash` (cascade-aware, using the existing purge path). Effort S, breaking: no.
- **SoftDeletable: `really_delete!`/`is_really_deleted?` should use Support::PrimaryKey.** Why: soft_deletable.rb:463 and :479 use `where(primary_key => id)` and `exists?(id)`, which the CLAUDE.md support section forbids. What: route both through `Support::PrimaryKey`. Effort S, breaking: no.
- **SoftDeletable: `kept?`/`undeleted?` predicate and a `kept` scope alias.** Why: the predicates are `deleted?`/`soft_deleted?`/`is_soft_deleted?` (:469-476) with no positive form, so views write `!post.deleted?`. discard's `kept`/`kept?` is the idiom people port from. What: alias `kept?` and add the `kept` scope next to `active`/`without_deleted`. Effort S, breaking: no (check the sibling-name guard: the `active` scope already collides with Expirable/Activatable, so prefer `kept`).

### Publishable
- **Publishable: `publish_all(at:)` for bulk scheduling.** Why: `publish_at!(time)` (publishable.rb:358) schedules one record, but `publish_all` (:136) takes no time, so an editorial "schedule these 20 for Monday 9:00" needs a loop. `expire_all(time)` already sets the precedent. What: add an optional `at:` (timestamp column only; refuse for a boolean column) that reuses the fast path and the `TimeValue.cast_argument!` validation. Effort S, breaking: no.
- **Publishable: `published_between(from, to)` scope / `published_within(duration)`.** Why: feeds and sitemaps ("published this week") are the most common query after `.published`. SoftDeletable has `deleted_within`, and Publishable has no counterpart. What: add an affixable scope on the timestamp form (`none` on a boolean column). Effort S, breaking: no.

### Expirable
- **Expirable: `default_scope:` option, like SoftDeletable and Publishable.** Why: invite and coupon tables usually want expired rows hidden everywhere. Today every query must remember `.active`. What: `expirable_by default_scope: true` with the same flag-driven single default_scope and AssociationScope peel as Publishable. Effort M (the Duplicable/Anonymizable `AssociationScope.without` lists must learn it), breaking: no.
- **Expirable: hooks on `extend_expiry!`/`expire_in!` (verify in lib).** Why: `before/after_expire` exist (expirable.rb:170-171), but extending a subscription is the event apps bill on. What: add `before/after_extend_expiry` via HookedWrite. Effort S, breaking: no.

### Activatable
- **Activatable: `activate_all`/`deactivate_all` should return affected records or ids on request.** Why: an admin "bulk deactivate then email these users" flow re-queries. What: `returning: :ids` option (PG `RETURNING` via `update_all` + `pluck` in the same transaction elsewhere). Low priority. Effort S, breaking: no.

### Schedulable
- **Schedulable: window validation.** Why: nothing in schedulable.rb validates that `ends_at > starts_at` (no `validate` call). `finish!` with the default "now" on an upcoming record (schedulable.rb:205) silently writes an end before the start, and every scope then misclassifies it. What: `schedulable_by validate: true` (default true in 2.0, opt-in now) adding an error on `ends_at` when it is not after `starts_at`; `reschedule!` then fails cleanly. Effort S, breaking: yes if default on (opt-in now).
- **Schedulable: hooks and a raising bang contract.** Why: `start!`/`finish!`/`reschedule!` call `update` (schedulable.rb:202,209,228). They return false on a validation failure and fire no hooks, unlike every sibling verb that goes through HookedWrite. What: run them through HookedWrite with `before/after_start` and `before/after_finish`, and use `update!` (or document the boolean). Effort S, breaking: mildly (raise instead of false).
- **Schedulable: `duration` and `remaining` helpers.** Why: `time_until_expiry` exists on Expirable (expirable.rb:240), but Schedulable has no `duration`/`time_until_start`/`time_remaining`, so every calendar view recomputes them. Effort S, breaking: no.

### Stateable
- **Stateable: validate the stored state.** Why: no `validates` exists for the field (no inclusion validation anywhere in models apart from Storable's). `record.update(status: "bogus")` or a typo'd `status: params[:status]` persists an undeclared state that no predicate or scope sees. What: `stateable_by …, validate: true` adding an inclusion validation over `stateable_states` (nil allowed only without a `default:`). Effort S, breaking: yes if default on, so opt-in in 1.x and the default in 2.0.
- **Stateable: per-transition `guard:` (`if:`/`unless:`).** Why: transitions accept only `from:`/`to:` (stateable.rb:369-378, OPTIONS :92). "Can submit only when the line items are present" is the #1 AASM feature people need. What: `transitions: { submit: { from: :draft, to: :pending, guard: :complete? } }`, evaluated in `may_<event>?`, in `<event>!` (inside the lock when `lock: true`), and per record in `transition_all`. Effort M, breaking: no.
- **Stateable: introspection and non-raising events.** Why: building a "next actions" UI needs `permitted_events` (AASM `aasm.events(permitted: true)`). Today it means `stateable_transitions.keys.select { may_…? }` by hand, and there is no `<event>` that returns false instead of raising `InvalidTransition`. What: an instance `permitted_<field>_events` (affixed), plus non-bang `<event>` returning a boolean. Effort S, breaking: no (check names against the collision guard).

### Lockable
- **Lockable: `authenticate_with_lockout`.** Why: every login controller hand-composes `access_locked?` → check password → `register_failed_attempt!` or `reset_failed_attempts!` (lockable.rb:371, 448, 458). Getting the order wrong (resetting before the lock check, or registering on a locked account) is a classic bug. Devise wraps this in `valid_for_authentication?`. What: `user.authenticate_with_lockout { |u| u.authenticate(pw) }` returns `:locked`/`false`/`true` and does the bookkeeping atomically. Document pairing it with Rails 7.1 `authenticate_by`. Effort S, breaking: no.
- **Lockable: hashed unlock tokens.** Why: `unlock_by_token` does `find_by(field => given)` on the raw token (lockable.rb:147). A DB read means you can unlock any locked account. What: `unlock_token: { digest: true }`, storing a SHA-256 and mailing the plaintext returned from `lock_access!`. Effort M, breaking: no.
- **Lockable: instrument lock and unlock, and an attempt window.** Why: a lockout is a security event, and nothing emits one. Devise also lacks a sliding window: `failed_attempts` never decays, so 5 typos over a year lock the account. What: emit `lock_access.concerns_on_rails` and `unlock_access.concerns_on_rails`. Optionally add `attempts_window: 1.hour` (needs a `last_failed_attempt_at` column) to reset the counter when stale. Effort S (events) / M (window), breaking: no.

### Tokenizable
- **Tokenizable: `digest: true` storage.** Why: the code's own note (tokenizable.rb:139-143) says "for a truly constant-time lookup, store and query a digest instead". Raw API keys and reset tokens in the DB are the leak that matters. What: store `SHA256(token)` and expose the plaintext only on generation (`regenerate_<field>!` returns it, and `<field>_plaintext` stays readable in memory after create). `authenticate_by_`/`consume_` hash the input then do an exact lookup. Pairs with `blind_index`-style HMAC when a key is configured. Effort M, breaking: no (opt-in).
- **Tokenizable: `prefix:` option.** Why: Hashable has `prefix:` (hashable.rb:47), and Tokenizable does not (tokenizable.rb:72). Prefixed tokens (`sk_live_`, GitHub `ghp_`) enable secret scanning and tell humans what a leaked string is. What: `tokenizable_by :api_key, prefix: "sk_"`, with the prefix excluded from `length:` and validated on lookup before any query. Effort S, breaking: no.
- **Tokenizable: `last_used_at` touch on authenticate.** Why: API-key UIs show "last used". Today that's a manual `update_column` after `authenticate_by_`. What: `track_usage: :api_key_last_used_at` that throttles the write (e.g. at most once a minute). Effort S, breaking: no.

### Hashable
- No high-value gaps found. It is single-field by design (hashable.rb:48), and multi-field needs are covered by Tokenizable.

### Sluggable
- **Sluggable: `slug_changed_from` redirect helper (verify in lib).** Why: with `history: true` the classic controller dance is "find via history and 301 if `request.path` slug != `record.slug`". friendly_id documents it, but every app re-implements it. What: a tiny controller-side helper or model `stale_slug?(param)`. Effort S, breaking: no.

### Sortable (model)
- **Sortable: document the `reposition!` index and lock behaviour.** Why: `reposition!(ids, missing:)` (sortable.rb:128) issues per-row writes under a list scope. Concurrent drag-and-drops race unless the app locks the scope parent. What: a docs note plus an optional `lock: true` that locks the scope parent row first. Effort S, breaking: no.

### Searchable
- **Searchable: association columns.** Why: `searchable_by *fields` only takes columns of the model's own table (`ensure_columns!` at searchable.rb:71). "Search posts by author name" forces a custom scope. ransack and pg_search's `associated_against` cover it. What: `searchable_by :title, author: %i[name]`, joined with `left_outer_joins` and deduplicated with `distinct` (ranked mode already handles DISTINCT by returning unranked). Effort M, breaking: no.
- **Searchable: performance docs and a full-text backend.** Why: `match: :contains` compiles to `LIKE '%x%'`, which is a full scan. What: document `pg_trgm` GIN (`gin_trgm_ops`) and MySQL FULLTEXT. Optionally add `using: :tsvector` on PostgreSQL. Effort S (docs) / L (backend), breaking: no.

### Taggable
- **Taggable: exclusion scope.** Why: `tagged_with(*names, any:)` (taggable.rb:104) has no negative form, and "everything except `archived`" is common. acts-as-taggable-on has `exclude: true`. What: `not_tagged_with(*names)` reusing the boundary-safe predicate under `NOT`, with NULL columns included. Effort S, breaking: no.
- **Taggable: index guidance.** Why: delimiter-joined LIKE matching scans the table. What: document a `pg_trgm` index or a generated array column, and when to graduate to a join table. Effort S, breaking: no.

### Normalizable / Sanitizable / Addressable / Aliasable
- No new items. Normalizes bridges and Addressable i18n are already on the backlog.

### Maskable
- **Maskable: `:name` and `:ip` presets.** Why: presets are `:email`/`:phone`/`:credit_card`/`:last4`/`:all` (per the maskable.rb:54 docs). Support dashboards most often need "J*** D**" and "192.168.x.x", and these get hand-written as Procs. Effort S, breaking: no.

### Monetizable
- **Monetizable: per-record currency.** Why: `unit:`/`subunit_to_unit:` are fixed per macro (monetizable.rb:54). A multi-currency app (JPY subunit 1, KWD subunit 1000) can't use the concern. money-rails offers `with_model_currency`. What: `currency_column: :currency` plus a small ISO table (unit, subunit, precision), resolved per record. Effort M, breaking: no.

### Storable
- **Storable: index docs for `where_<key>`.** Why: on jsonb, `where_<key>` needs an expression or GIN index, and nothing says so. What: a docs table of PG expression indexes, MySQL generated columns and SQLite. Effort S, breaking: no.

### Encryptable
- **Encryptable: migration to and from `ActiveRecord::Encryption`.** Why: Rails 7+ apps will ask "why not `encrypts`?", and teams on 7.0+ may want to move either way. What: a docs guide plus a `previous_scheme: :active_record` decrypt fallback in `reencrypt_all!` so a table can be migrated in place. Effort M, breaking: no.
- **Encryptable: KMS envelope key provider (verify in lib).** Why: keys come from config or a per-field Proc. Teams on AWS KMS or Vault want data keys wrapped by a KMS, as lockbox and AR Encryption's key providers offer. What: document a `key:` Proc pattern for KMS, or a `key_provider` interface. Effort M, breaking: no.

### Auditable
- **Auditable: `without_auditing { }` / `auditable: false` per save.** Why: bulk imports and backfills bloat the trail and evict real history under `max_entries` (auditable.rb:221-222). paper_trail has `PaperTrail.request(enabled: false)`. What: a fiber-local switch checked in `auditable_capture_changes`. Effort S, breaking: no.
- **Auditable: `value_at(field, time)` and `revert_last_change!(field)`.** Why: the trail already has from/to/at per field (auditable.rb:270-277), so a point-in-time read is a reverse scan. It covers the "reify-lite" need the header punts to paper_trail (auditable.rb:61). Effort S/M, breaking: no.
- **Auditable: `"event"` and request metadata.** Why: entries can't tell create from update except by `from: nil`, and there is no request_id/IP, which audits often require. What: `"event" => "create"|"update"`, plus `meta: -> { { ip: Current.ip } }` resolved like `actor:`. Effort S, breaking: no (additive keys).

### CounterCacheable
- **CounterCacheable: `delta:` (sum instead of count).** Why: order totals and "sum of line item quantity" are the second most common counter_culture use (`delta_column`). Today that needs custom callbacks that miss the reparent/condition matrix this concern gets right. What: `counter_cacheable_by :order, count: :items_total, delta: :quantity`, reusing the same adjustment flush with `±value`. Effort M, breaking: no.
- **CounterCacheable: one rule, many columns (`column: ->(child) { … }`).** Why: `published_count`/`draft_count` today need N declarations with `if:` (re-declaring the same association + `count:` replaces). counter_culture's `column_name:` proc is the idiom. Effort M, breaking: no.

### Sequenceable
- **Sequenceable: `next_<field>_preview` (verify in lib).** Why: invoice forms show "will be INV-2026-0042" before save. What: a read-only peek with the same MAX query, documented as advisory under concurrency. Effort S, breaking: no.

### Anonymizable
- **Anonymizable: dry-run preview.** Why: DPOs ask "what exactly will erasure change?". `anonymizable_payload` (anonymizable.rb:455) already builds it privately. What: a public `anonymization_preview` returning `{ field => [old_present?, strategy] }` without decrypting or writing. Effort S, breaking: no.

### Duplicable
- **Duplicable: per-association filters (verify in lib).** Why: "duplicate the project but only open tasks" is common. `associations:` takes names only (duplicable.rb:110). What: `associations: { tasks: ->(rel) { rel.where(done: false) } }`. Effort M, breaking: no.

## Per-concern improvements: controller concerns (from the CLAUDE.md contract)

- **ErrorHandleable: built-in mapping of the gem's and Rails' conflict errors.** See theme 4. It covers `Stateable::InvalidTransition`, `StaleObjectError` and `RecordNotUnique` → 409, plus `ActionController::UnknownFormat` → 406, each trimmable via `except:`. Effort S, breaking: no if opt-in.
- **Respondable: `render_accepted(location:)` and `render_no_content`.** Why: async-job APIs (202 + status URL) and DELETE (204) are the two statuses beside `render_created`/`render_invalid` that apps hand-roll. Effort S, breaking: no.
- **Cacheable: `immutable`, `stale_if_error`, `s_maxage` directives.** Why: options per CLAUDE.md are `visibility/max_age/must_revalidate/no_store/stale_while_revalidate/vary`. CDN setups need `s-maxage`, and fingerprinted payloads want `immutable`. Effort S, breaking: no. (verify in lib)
- **Throttleable: IETF `RateLimit` / `RateLimit-Policy` headers (verify in lib).** Why: clients can back off before the 429. rack-attack and Rails 8 `rate_limit` don't emit them, so this would be a real differentiator. Effort S, breaking: no.
- **Idempotentable: `Idempotent-Replayed: true` on replays (verify in lib).** Why: Stripe sets it, and clients and tests use it to tell a replay from a fresh run. Effort S, breaking: no.
- **WebhookVerifiable: `:standard_webhooks` and `:slack` presets.** Why: presets are stripe/github/shopify/hex/base64. The Standard Webhooks spec (`webhook-id`/`webhook-timestamp`/`webhook-signature`, used by Svix, Resend, Clerk and others) and Slack's `v0:` timestamped scheme are the next most common inbound sources, and both carry timestamps. That gives replay protection without the store. Effort S each, breaking: no.
- **CursorPaginatable: RFC 8288 `Link` rel=next/prev (verify in lib).** Why: `support/link_header.rb` exists, but CLAUDE.md lists only `X-*` cursor headers, and the GitHub-style Link header is what generic clients follow. Effort S, breaking: no.
- **Paginatable: `count: false` (countless) mode (verify in lib).** Why: COUNT on big tables is the #1 offset-pagination cost. pagy's countless fetches `per_page + 1`. Effort S, breaking: no.
- **Authorizable: `verify_authorized` after_action (verify in lib).** Why: an action with no matching `authorize_by` rule is allowed silently. Pundit's `verify_authorized` catches forgotten rules in dev and test. Effort S, breaking: no (opt-in).
- **SecureHeadable: `Permissions-Policy` and COOP/CORP defaults (verify in lib).** Why: these are the modern headers secure_headers ships that the CSP passthrough doesn't cover. Effort S, breaking: no.
- **Filterable: `null`/`not_null` operators (verify in lib).** Why: `?archived_at[null]=true` is the common ransack `_null` predicate, and blank values are skipped, so nil can't be requested today. Effort S, breaking: no.
- **Includable: JSON:API-compatible `include=`/`fields[type]=` parsing mode (verify in lib).** Effort S, breaking: no.
- **Localizable / Timezoneable: a `from: -> { current_user&.locale }` source (verify in lib).** Why: a signed-in user's saved preference usually beats the header, and there is no hook for it other than overriding. Effort S, breaking: no.
- **Sortable (controller) / Deprecatable / Permittable:** no new items. Permittable lives in its own gem.
