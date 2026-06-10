# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
# Run all tests (use the asdf-pinned Ruby; see Gemfile.lock PATH pin)
ASDF_RUBY_VERSION=3.2.2 bundle exec rspec

# Run a single spec file
ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/models/publishable_spec.rb

# Run a single example by line number
ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/models/publishable_spec.rb:28

# Build the gem
gem build concerns_on_rails.gemspec

# Install locally (version comes from lib/concerns_on_rails/version.rb)
gem install ./concerns_on_rails-<VERSION>.gem
```

## Architecture

This is a Ruby gem providing a collection of `ActiveSupport::Concern` modules that Rails
**models** and **controllers** include directly. There is no Rails app — tests use an
in-memory SQLite database configured in `spec/support/database.rb`, with a
`TestModel < ActiveRecord::Base` (abstract) base for spec model classes, and a
dependency-free `FakeController` harness (`spec/support/controller_test_harness.rb`) for
the controller concerns.

Model concerns live in `lib/concerns_on_rails/models/<name>.rb`, controller concerns in
`lib/concerns_on_rails/controllers/<name>.rb`, and shared internal helpers in
`lib/concerns_on_rails/support/<name>.rb`. `lib/concerns_on_rails.rb` is the loader (note
the require order: support helpers load before the concerns that use them). Top-level
aliases for the pre-1.6 module paths (e.g. `ConcernsOnRails::Sluggable`) live in
`lib/concerns_on_rails/legacy_aliases.rb`.

Most model concerns follow the same pattern: `class_attribute` defaults in `included do`,
a `class_methods` block with a `<concern>_by` configuration macro, and instance methods.
The macro validates that configured columns exist via `Support::ColumnGuard#ensure_columns!`
and raises `ArgumentError` if not. (Field-transform concerns — `normalizable`,
`monetizable`, `maskable`, `sanitizable` — use a bare-verb macro that takes `*fields, with:`
and may be called multiple times, rather than the `<concern>_by` form.)

### Model concerns (`lib/concerns_on_rails/models/`)

- **`Sluggable`** — wraps `friendly_id` (`:slugged`). Regenerates the slug when the source
  field changes, backfills a blank slug, and won't overwrite an explicitly-assigned slug.
  Options: `history:`, `scope:`, `reserved_words:`, `finders:`.
- **`Sortable`** — wraps `acts_as_list`; `default_scope` orders by the configured
  field/direction. `sortable_by :position` / `position: :desc`; `scope:`, `add_new_at:`,
  `use_acts_as_list: false`.
- **`Publishable`** — timestamp (default `published_at`) **or** boolean column; scopes
  `.published/.unpublished/.scheduled/.draft` branch on the column type. `default_scope: true`
  hides unpublished. Lifecycle hooks: `before/after_publish`, `before/after_unpublish`.
- **`SoftDeletable`** — timestamp (default `deleted_at`) + `default_scope` hiding deleted
  rows (opt out with `default_scope: false`). `soft_delete!`/`restore!`, batch
  `soft_delete_all`/`restore_all` (atomic), `really_destroy_all`/`really_delete!` for hard
  deletes. Hooks: `before/after_soft_delete`, `before/after_restore`.
- **`Hashable`** — one random identifier column. `type:` `:hex`/`:uuid`/`:integer`/`:custom`,
  `length:`, `alphabet:`, `unique:` (retry on collision).
- **`Tokenizable`** — multiple security-token columns. `type:` `:urlsafe`/`:hex`/
  `:alphanumeric`/`:numeric`, `length:`; `regenerate_/revoke_/<field>?` + uniqueness retry.
- **`Sequenceable`** — ordered reference numbers (invoice/order numbers). `into:`, `prefix:`,
  `padding:`, `scope:`, `reset:` (`:year`/`:month`/`:day`), `template:`.
- **`Schedulable`** — start/end window (`starts_at`/`ends_at`); `current`/`upcoming`/`expired`
  scopes + predicates.
- **`Expirable`** — single expiry column (default `expires_at`); `active`/`expired`/
  `expiring_within` scopes (affixable via `prefix:`/`suffix:`).
- **`Activatable`** — boolean active flag (default `active`); `active`/`inactive` scopes
  (affixable via `prefix:`/`suffix:`), `activate!`/`deactivate!`/`toggle_active!`.
- **`Stateable`** — lightweight string-backed state machine: states, `default:`,
  `transitions:`, `prefix:`/`suffix:`; guarded `<event>!` + `may_<event>?`,
  `before/after_transition` hooks.
- **`Searchable`** — LIKE search across columns via Arel `matches`. `mode:` `:any`/`:all`,
  `match:` `:contains`/`:prefix`/`:exact`, `case_sensitive:` (Postgres only).
- **`Normalizable`** — `before_validation` normalization. Presets (`:email`, `:phone`,
  `:squish`, …) or a Proc. (On Rails 7.1+, native `normalizes` is an alternative.)
- **`Taggable`** — delimiter-joined tags in one string column (no join table). `tagged_with`,
  `all_tags`, boundary-safe and LIKE-escaped (tag and delimiter).
- **`Sanitizable`** — opt-in HTML sanitization (`on: :read` reader by default, or `:write`).
- **`Maskable`** — non-destructive display masking (`masked_<field>` readers): `:email`,
  `:phone`, `:credit_card`, `:last4`, `:all`, or a Proc.
- **`Monetizable`** — integer-cents money accessors via BigDecimal: `<name>`, `<name>=`,
  `formatted_<name>`; `unit:`, `precision:`, `delimiter:`, `separator:`, `subunit_to_unit:`.
- **`Addressable`** — postal-address normalization + format validation across columns;
  `full_address`, `address_complete?`, `verify_with:`.
- **`Auditable`** — single-column JSON change history ("paper_trail-lite"). `auditable_by
  *fields, into:, actor:, max_entries:`; `audit_trail` / `last_change_for` /
  `audited_changes_since` / `clear_audit_trail!`.

### Controller concerns (`lib/concerns_on_rails/controllers/`)

- **`Paginatable`** — offset pagination (`paginated`, `pagination_meta`) + `X-*` headers.
- **`Filterable`** — declarative URL-param filtering (`filter_by`: direct-where / `scope:` /
  `with:` lambda).
- **`Sortable`** — allow-listed, multi-column ordering from `params[:sort]` (uses `reorder`).
- **`Respondable`** — standard JSON success/error envelopes (`render_success`/`render_error`).
- **`ErrorHandleable`** — `rescue_from` for RecordNotFound / ParameterMissing / RecordInvalid.
- **`Includable`** — allow-listed association sideloading + sparse fieldsets.
- **`SecureHeadable`** — security response headers + native CSP DSL passthrough.
- **`Localizable`** — per-request `I18n.locale` from params / `Accept-Language` (q-values).
- **`Authorizable`** — declarative per-action authorization (`authorize_by`, `require_role`).
- **`Throttleable`** — fixed-window rate limiting with an injectable atomic store.
- **`Timezoneable`** — per-request `Time.zone` from params / header / cookie.
- **`Idempotentable`** — `Idempotency-Key` response replay with an injectable store
  (`idempotent_actions`); 409 on in-flight duplicates, 422 on payload mismatch.

### Support modules (`lib/concerns_on_rails/support/`)

`ColumnGuard` (schema validation), `RandomValue`, `SequenceCalculator`, `HtmlSanitizers`,
`Masker`, `Money`, `AddressData`.

### Test structure

Each spec recreates tables in a `before` block via `ActiveRecord::Schema.define` and drops
them in `after(:each)`. Model classes are defined inline (named classes are removed in the
`after`, or use anonymous `Class.new(TestModel)` to avoid const leakage). Controller specs
subclass `FakeController`. SimpleCov writes coverage to `coverage/`.

### Runtime dependencies

- `rails >= 5.0, < 9`
- `acts_as_list ~> 0.7.5`
- `friendly_id ~> 5.4`
- Ruby `>= 3.2.0`

### Release process

Bump `lib/concerns_on_rails/version.rb`, the `Gemfile.lock` PATH pin, `CHANGELOG.md`, and the
docs version together; create a GitHub Release tag and attach the built `.gem`.
