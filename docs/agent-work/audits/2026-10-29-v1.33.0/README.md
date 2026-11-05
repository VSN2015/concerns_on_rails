# Audit of concerns_on_rails v1.33.0 — 2026-10-29

Scope: every file under `lib/concerns_on_rails/` at master `033981a` (v1.33.0), split into six slices
(DATA, STATE, GRAPH, TRANS, PARAMS, HTTP) reviewed by six independent read-only reviewers, plus one
brainstormer for improvements. Nothing in `lib/`, `spec/` or `docs/` was modified.

**Verification.** Every "proven" finding below has a failing RSpec example in `repros/<SLICE>_spec.rb`
that the coordinator ran on the default Gemfile (Rails 8.1.4, Ruby 3.2.2, SQLite). Each example asserts
the CORRECT behaviour, so a failure is the bug. Run one file with:

```sh
ASDF_RUBY_VERSION=3.2.2 bundle exec rspec docs/agent-work/audits/2026-10-29-v1.33.0/repros/STATE_spec.rb
```

Observed totals: DATA 7 failures / 8 examples (1 pending, PG-only), STATE 18/24 (6 passing are control
probes), GRAPH 7/7, TRANS 10/11 (1 passing control), PARAMS 12/12, HTTP 4/4.

Items marked "reasoned, not run" need PostgreSQL/MySQL or another Rails line and were not executed.
The four known-open issues from the 1.32.1 changelog were excluded on purpose.

## Totals

| Slice | Proven | HIGH | MEDIUM | LOW | Suspected / reasoned only |
|---|---|---|---|---|---|
| DATA (Encryptable, Tokenizable, Hashable, Lockable, Auditable, registry) | 4 | 0 | 3 | 1 | 3 (DATA-3 PG-only, S-1, S-2) |
| STATE (Publishable, SoftDeletable, Expirable, Activatable, Stateable, Anonymizable, BatchOps, HookedWrite) | 12 | 2 | 5 | 5 | 1 |
| GRAPH (CounterCacheable, Duplicable, Aliasable, Sluggable, Sortable, Sequenceable, Schedulable, loader) | 6 | 0 | 4 | 2 | 0 |
| TRANS (Normalizable, Sanitizable, Taggable, Maskable, Monetizable, Addressable, Storable, Searchable) | 4 | 2 | 1 | 1 | 4 |
| PARAMS (Filterable, Paginatable, CursorPaginatable, Sortable ctrl, Includable) | 8 | 0 | 4 | 4 | 4 |
| HTTP (Respondable, ErrorHandleable, SecureHeadable, Localizable, Timezoneable, Authorizable, …) | 4 | 0 | 3 | 1 | 3 |
| **Total** | **38** | **4** | **20** | **14** | **15** |

## Proven bugs (one line each; full write-ups in `<SLICE>_FINDINGS.md`)

### HIGH
- **STATE-11** HookedWrite: a vetoed hooked verb (`publish!`, `activate!`, `expire!`, `soft_delete!`, Stateable `<event>!`…) on a NEW record inside a caller's transaction leaves the record `persisted?` with `id nil`; the next `save` runs `UPDATE … WHERE id IS NULL`, returns true, and no row is ever written (StaleObjectError with `lock_version`). `support/hooked_write.rb:71-90` snapshots identity only for already-persisted records.
- **STATE-1** Expirable `time_until_expiry` raises `TypeError: expected numeric` on a `date` column with a future date (`expirable.rb:240-248`); the 1.33.0 date-column fix covered the predicates only.
- **TRANS-1** Storable on a PG `jsonb` column or an `attribute :x, :json` column stores a JSON *string* scalar, so `where_<key>(v)` never matches and `where_<key>(nil)` matches every row (`storable.rb:451-460`; Auditable got this fix in e098675, Storable did not).
- **TRANS-2** Normalizable's settle step re-normalizes Sanitizable `on: :write` output: `:titleize` + `:strip` stores "A &Lt; B" (≪ entity) for a validated "A &lt; B"; a decoding normalizer stores live `<img onerror>` markup in a `:strip` column (`normalizable.rb:264-273`).

### MEDIUM
- **DATA-1** Lockable (`register_failed_attempt!`, `lock_access!`, `unlock_by_token`, lapsed-lock clear) and Tokenizable `consume_<field>` raise ArgumentError on composite primary keys — `where(primary_key => id)` not routed through `Support::PrimaryKey` (incomplete #138).
- **DATA-2** A per-field `key:` Proc returning nil silently encrypts under the GLOBAL key; once the field key appears those rows raise DecryptionError and `needs_reencryption` can never find them (`encryption.rb:117-123`).
- **STATE-2** Expirable `expire!` on a `date` column skips its hooks when the process TZ is behind `Time.zone` (`Date#to_time` uses ENV TZ, `expirable.rb:269-270`).
- **STATE-3** SoftDeletable `really_delete!` / `is_really_deleted?` crash on composite primary keys (`soft_deletable.rb:463,479`).
- **STATE-4** Association `destroy_all` marks the association "loaded, empty" after a SOFT delete even when the rows remain members (`default_scope: false` model, `-> { with_deleted }` association) (`contextual_destroy.rb:256-266`).
- **STATE-5** `unpublish!` on a draft / already-unpublished record re-fires before/after_unpublish (the other verbs became no-ops in #146).
- **STATE-12** `soft_delete!` / `restore!` decide "already done" from the UNSAVED in-memory stamp and return true while writing nothing (no hooks, no cascade) (`soft_deletable.rb:435,447`).
- **GRAPH-1** Sequenceable: after switching to `period_column:`, pre-switch rows (NULL there) format in TODAY's period, so a 2025 invoice prints "INV-2026-1" like the real 2026 #1 (`sequence_calculator.rb:181`).
- **GRAPH-2** CounterCacheable accepts a composite `foreign_key:` but never counts the children; `recount_counter_caches!` emits invalid SQL `WHERE NOT (())`.
- **GRAPH-5** Sluggable `history: true` + `scope:`: moving a record into a scope where another record's HISTORY holds its slug raises RecordNotUnique on the friendly_id_slugs index (or silently hijacks the old URL without the index) (`sluggable.rb:348-363`).
- **GRAPH-6** Duplicable copies a child the loaded association has marked `_destroy` / `mark_for_destruction` as a live child (`duplicable.rb:269-306`).
- **TRANS-3** A save halted (`throw :abort` in a later before_save) or rolled back (RecordNotUnique) and then retried on the same record re-applies non-idempotent Normalizable / Sanitizable rules ("Tom &amp;amp; Jerry", "a!!").
- **PARAMS-1** Filterable on an `encryptable` column: `?ssn_not=123` / `?ssn_not_in=` return the excluded row; `=`, `in`, `contains` silently match nothing (fresh random-IV ciphertext as the operand).
- **PARAMS-2** Re-declaring `paginate_by` / `includable` in a subclass resets every omitted option (parent `max_per_page: 20` → 200, `style: :jsonapi` → flat, `fields:`/`default:`/`strategy:` lost); CursorPaginatable's UNSET-sentinel fix was never ported.
- **PARAMS-3** Paginatable's COUNT strips the SELECT list, so a grouped relation with `having("alias > n")` raises StatementInvalid (SQLite/MySQL) (`paginatable.rb:261-264`).
- **PARAMS-4** CursorPaginatable `predicate: :row` with mixed directions is accepted at the macro; page 1 mints a cursor, every page-2 request raises ArgumentError (500) (`cursor_paginatable.rb:872-883`).
- **HTTP-1** Authorizable `status: :not_found` keeps the default message "Forbidden", so its 404 body still differs from ErrorHandleable's ("Resource not found"): the existence oracle #145 meant to close is still open.
- **HTTP-2** `require_role %i[admin editor]` (roles as one Array) is never flattened → every user gets 403; `require_role []` passes the "at least one role" guard.
- **HTTP-3** Timezoneable never emits `Vary: Time-Zone` unless `response_header:` is on (default off), so a shared cache can serve one client's zone-rendered body to another. The README documents the coupling, so this is a design flaw rather than a code/doc mismatch.

### LOW
- **DATA-4** `register_failed_attempt!` increments the counter in SQL on a `readonly!` record, then `lock_access!` raises ReadOnlyRecord: row left at max attempts, unlocked.
- **STATE-6** A Stateable event named `transition` makes `transition!` always raise ArgumentError (per-event hook `before_transition` resolves to the generic 3-arg hook).
- **STATE-7** Batch verbs and relation `destroy_all` raise MissingAttributeError on a relation with a partial `select` (per-record path only; the fast path succeeds, so the outcome depends on whether a validator exists).
- **STATE-8** `transition_all` raises RecordInvalid instead of the documented RecordNotSaved on a validation failure.
- **STATE-9** Anonymizable ignores the write result: `anonymize_all!` counts a row its UPDATE never reached, `after_anonymize` fires for an erasure that did not happen.
- **STATE-10** `expire_in!(nil)` raises TypeError instead of the concern's ArgumentError.
- **GRAPH-3** Sortable (model) `reposition!` raises `TypeError: can't quote Array` on a composite primary key.
- **GRAPH-4** `legacy_aliases` `const_missing` prints "already initialized constant" under a racing first reference (unconditional `const_set`).
- **TRANS-4** Taggable with a multi-character delimiter (`"--"`) mis-splits a tag ending in `-`: `["a-", "b"]` reads back as `["a", "-b"]`.
- **PARAMS-5** CursorPaginatable on SQLite refuses a cursor it minted itself when the boundary string holds a NUL byte; the walk stops with a 400.
- **PARAMS-6** `?<field>_null=maybe` (any non-FALSE_VALUES string) is read as true → `IS NULL`.
- **PARAMS-7** `page`/`per_page` are read with `String#to_i`: `?per_page=1e3` → 1, `?per_page=10abc` → 10.
- **PARAMS-8** Float-column operands are rounded to the nearest double and treated as exact (`?score_gt=0.1000000000000000000001` drops the 0.1 row).
- **HTTP-4** ErrorHandleable's RecordNotDestroyed 422 echoes Rails' "Failed to destroy <Model> with id=<id>" (model class name leak).

## Suspected / reasoned only (not run locally)
- **DATA-3** [MEDIUM, PG] A NUL byte in a token (`?token=%00`) makes `authenticate_by_`/`consume_`/`unlock_by_token` raise (pg refuses NUL in a bound text param) instead of answering nil; Filterable got `ScalarParam.nul_free?` in #152, these did not. (Example pending unless DB=postgresql.)
- **DATA-S1** [MEDIUM, PG] Encryptable on a `bytea` column never decrypts (the custom type replaces OID::Bytea, nothing unescapes `\x…`); docs say "text (or binary)".
- **DATA-S2** [LOW] A generated value (token/sequence number) survives a create halted by `throw :abort` inside a caller's transaction (Rails swallows the Rollback, `rolledback!` never runs), so a retried save reuses it.
- **STATE-S1** [MEDIUM] Whether STATE-11 also occurs on Rails 6.0–7.x (`restore_transaction_record_state` level rules differ) — run `STATE_spec.rb` on the matrix.
- **TRANS-S1** [LOW, PG/MySQL] `search(q, ranked: true).distinct` / `.group` chained AFTER search keeps `ORDER BY CASE` → "ORDER BY expressions must appear in select list".
- **TRANS-S2** [LOW, MySQL] Taggable docs promise case-insensitive matching on every adapter; Arel's MySQL visitor ignores `case_sensitive: false` on `_bin`/`_cs` collations.
- **TRANS-S3** [LOW] Monetizable lets `"1e18"` through as 1e20 cents; the save then raises ActiveModel::RangeError instead of the setter casting oversized input to nil.
- **TRANS-S4** [LOW] `EDGE_SPACE` / `TRAILING_COMMENTS` regexes may be quadratic on long whitespace runs (reachable from `search(params[:q])`).
- **PARAMS-S1** [MEDIUM, PG/MySQL] Controller Sortable never appends a primary-key tiebreaker, so OFFSET pages over a non-unique sort can repeat/skip rows.
- **PARAMS-S2** [LOW] `paginated(rel.limit(n))` replaces the caller's LIMIT for the records and strips it for the count.
- **PARAMS-S3** [LOW, PG] A decimal boundary longer than 100 characters (unconstrained `numeric`) mints a cursor the next request rejects.
- **PARAMS-S4** [LOW] `with:` lambdas with `type: :boolean`/`:string` receive cast Arrays (`?flag[]=0` → true) instead of failing closed.
- **HTTP-5** [LOW, Rails 7.1–8.0 + Rack ≥ 3.1] Envelope-format 422s log Rack's "Status code :unprocessable_entity is deprecated" on every call (only the problem-details branch normalizes).
- **HTTP-6** [LOW] SecureHeadable `:hsts` preset wins over `force_ssl`'s HSTS (SSL middleware uses `||=`): shortens 2 years to 1, drops `preload`.
- **HTTP-7** [LOW] SecureHeadable HSTS guard compares the header name case-sensitively.

## Recurring bug classes (coordinator analysis)
1. **The composite-primary-key sweep (#138) stopped short.** DATA-1 (Lockable ×5 sites, Tokenizable consume), STATE-3 (SoftDeletable really_delete!/is_really_deleted?), GRAPH-2 (CounterCacheable composite FK), GRAPH-3 (Sortable reposition!). Grep for `where(.*primary_key =>` and `exists?(id)` and route every hit through `Support::PrimaryKey`, or refuse composite keys at the macro.
2. **The "saved-state idempotency" rule (#146/#141) was applied to some verbs only.** STATE-5 (`unpublish!`), STATE-12 (`soft_delete!`/`restore!` read the unsaved stamp). One shared predicate ("stored, no unsaved change to the column, saved value already in the target state") should back every hooked verb.
3. **`date`-column support (1.33.0) covered the predicates, not the verbs/helpers.** STATE-1 (`time_until_expiry`), STATE-2 (`expire!` future check via `Date#to_time` = ENV TZ).
4. **Repeatable-macro contract broken again, this time in controllers.** PARAMS-2 (`paginate_by`, `includable`); CursorPaginatable's `UNSET` sentinel is the pattern to port.
5. **Encryptable × sibling guards.** PARAMS-1: Filterable has no Encryptable awareness (CLAUDE.md's guard list names searchable_by/taggable_by only). DATA-2: a nil per-field key falls back to the global key.
6. **Transform bookkeeping ("a Proc runs once per save").** TRANS-2 (settle re-normalizes a sibling's rewrite), TRANS-3 (per-save record cleared before the save is known to succeed).
7. **Fail-closed parsing gaps.** PARAMS-6 (`_null=` boolean cast), PARAMS-7 (`to_i`), DATA-3 (NUL in tokens), PARAMS-8 (float rounding).
8. **Per-record paths and partial `select`.** STATE-7: `each_record` keeps the caller's select; `unscope(:select)` before loading.
9. **Incomplete fixes whose regression spec encodes the bug.** HTTP-1 (spec passes `message:` explicitly), GRAPH-1 (spec asserts the new number only), TRANS-2 (spec computes the expected value through the same path). When fixing, add the missing assertion to the EXISTING regression spec too.

## Improvements
See `IMPROVEMENTS.md` (top 10, 8 cross-cutting themes, per-concern bullets) plus the "Improvement
suggestions" section at the end of each `<SLICE>_FINDINGS.md`. Coordinator's pick of the highest-value items:

1. **Real model callbacks** (`define_model_callbacks :soft_delete, :publish, :expire, :activate, :lock, :anonymize, :transition …`) — today every hook is an override-only empty method, so a model gets ONE override per hook and no `if:`/`unless:`; paranoia/discard/AASM all register real callbacks. Non-breaking, effort M.
2. **Stateable `validate: true` (inclusion over declared states) + per-transition `guard:`** — `update(status: "bogus")` persists today; guards are the #1 reason people reach for AASM. Opt-in in 1.x.
3. **Tokenizable / Lockable `digest: true`** — tokens and unlock tokens are stored and queried in plaintext (the code's own comment says a digest is the real fix); plus `prefix:` for Tokenizable (Hashable has it) for secret scanning.
4. **ErrorHandleable mapping for the gem's own exceptions** (`Stateable::InvalidTransition`, `StaleObjectError`, `RecordNotUnique` → 409; `DecryptionError` → scrubbed 500).
5. **Consistent bang contract**: `HookedWrite` returns false on a veto, so `publish!`/`soft_delete!` never raise while Stateable's `<event>!` does; Schedulable's bangs use `update` and have no hooks at all. Add non-bang booleans now, make bangs raise in 2.0.
6. **Uniform instrumentation** (`lock_access`, `anonymize`, `reencrypt`, `transition`, `<verb>_all` with `fast_path:`, `idempotency_replay`, `webhook_rejected`) + a LogSubscriber; only four controller concerns instrument anything today.
7. **Lockable `authenticate_with_lockout`** and documented pairing with Rails 7.1 `authenticate_by`.
8. **Specificity rules**: Idempotentable "first rule wins" and Deprecatable/Cacheable "last rule wins" both let a subclass silently loosen a parent rule; WebhookVerifiable already moved to most-derived-first.
9. **Controller helper visibility**: public `render_success`/`render_error`/`handle_*`/`switch_locale`… become routable `action_methods` on a non-abstract ApplicationController.
10. **Docs**: per-concern "indexes & performance" section (partial index for SoftDeletable, pg_trgm for Searchable/Taggable, jsonb expression indexes for Storable `where_<key>`), and CLAUDE.md corrections listed in the TRANS/PARAMS findings.

## Suggested fix grouping (if a fix wave follows)
- Group A "composite keys": DATA-1, STATE-3, GRAPH-2, GRAPH-3 (+ sweep).
- Group B "idempotent verbs": STATE-5, STATE-12 (+ STATE-9 write-result).
- Group C "date columns": STATE-1, STATE-2, STATE-10.
- Group D "HookedWrite identity": STATE-11 (+ matrix run for STATE-S1).
- Group E "transforms": TRANS-2, TRANS-3 (same files; one PR), TRANS-1 (+ Auditable helper share), TRANS-4.
- Group F "params": PARAMS-2, PARAMS-3, PARAMS-4, PARAMS-6/7 (ScalarParam), PARAMS-1 (Filterable × Encryptable), PARAMS-5/8.
- Group G "http": HTTP-1, HTTP-2, HTTP-4 (+ HTTP-3 design decision).
- Group H "graph": GRAPH-1, GRAPH-5, GRAPH-6, GRAPH-4; STATE-4, STATE-6, STATE-7, STATE-8 (SoftDeletable/Stateable/BatchOps).
- Needs a maintainer decision first: HTTP-3 (Vary coupling is documented), TRANS-2 (which side of the settle contract wins), PARAMS-4 (refuse at macro vs fall back to `:or`).
