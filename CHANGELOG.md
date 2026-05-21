<!-- CHANGELOG.md -->

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