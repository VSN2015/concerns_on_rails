<!-- CHANGELOG.md -->

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