<!-- CHANGELOG.md -->

## 1.4.1 (2026-05-16)

### Added
- Schedulable: Manage time-windowed records via `starts_at` / `ends_at` columns. Adds `schedulable_by` macro, scopes (`.current`, `.upcoming`, `.expired`, `.active_at(time)`), predicates (`current?`, `upcoming?`, `expired?`, `active_at?`), and mutators (`start!`, `finish!`, `reschedule!`). Supports custom column names and open-ended schedules (`starts_at: nil`).

### Notes
- The `v1.4.0` tag was created but never released (CI failed because `Gemfile.lock` was not regenerated alongside the version bump). `1.4.1` is the first usable release of the Schedulable concern.

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