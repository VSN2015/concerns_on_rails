<!-- CHANGELOG.md -->

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