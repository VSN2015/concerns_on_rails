`Normalizable` automatically cleans and transforms model attribute values in a `before_validation` callback, so downstream validations, uniqueness checks, and database writes always operate on canonical data. It ships six built-in presets for the most common string transformations (whitespace stripping, email lowercasing, phone digit extraction, and case conversion) and accepts any custom `Proc` or lambda for domain-specific rules, eliminating the repetitive `before_validation` boilerplate that accumulates across large Rails codebases.

## When to use it

- Storing email addresses that must be lowercase regardless of how a user typed them, so `FOO@Bar.com` and `foo@bar.com` are always deduplicated correctly.
- Normalizing phone numbers to digits-only before indexing or sending to an SMS provider, without writing the same `gsub` in multiple places.
- Stripping accidental leading/trailing whitespace from free-text fields (names, slugs, codes) so uniqueness validations and display are consistent.
- Collapsing internal whitespace in bio or description fields where users may paste text with irregular spacing.
- Applying a URL slug or identifier transformation (e.g., `parameterize`, `tr`, `gsub`) through a custom lambda without subclassing the model.

## Installation

```ruby
class User < ApplicationRecord
  include ConcernsOnRails::Normalizable

  normalizable :email,                   with: :email
  normalizable :phone,                   with: :phone
  normalizable :first_name, :last_name,  with: :whitespace
  normalizable :code,                    with: :upcase
  normalizable :slug,                    with: ->(v) { v.to_s.parameterize }
end
```

The canonical, namespaced path is `ConcernsOnRails::Models::Normalizable`, which is what the gem encourages and what its test suite uses. The top-level `ConcernsOnRails::Normalizable` constant shown above is a backwards-compatibility alias (defined in `lib/concerns_on_rails/legacy_aliases.rb` as `Normalizable = Models::Normalizable`); both resolve to the same module, so either include works.

## Database columns

`Normalizable` does not require any dedicated columns of its own. It operates on whichever columns you declare in `normalizable` calls. Those columns must already exist in the database schema before the class is loaded — the concern validates this at class-definition time via `ConcernsOnRails::Support::ColumnGuard`.

## Configuration

### `normalizable(*fields, with:)`

Declares one or more fields to normalize and the transformation to apply. Call the macro once per rule group; multiple calls accumulate and do not overwrite each other.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `*fields` | One or more `Symbol` (positional) | — | The model attribute(s) to normalize. At least one is required; passing none raises `ArgumentError`. Each field is verified to exist as a database column at class-load time. |
| `with:` | `Symbol` or `Proc`/lambda | — | **Required.** Either a built-in preset symbol (see table below) or any callable that accepts the raw value and returns the transformed value. Passing any other type (e.g., a `String`) raises `ArgumentError`. |

**Built-in presets for `with:`**

| Preset | Transform |
|--------|-----------|
| `:email` | `strip` + `downcase` |
| `:phone` | Remove all non-digit characters (`gsub(/\D/, "")`) |
| `:whitespace` | `strip` (leading/trailing whitespace only) |
| `:squish` | `squish` (strip and collapse internal whitespace to single spaces) |
| `:downcase` | `downcase` |
| `:upcase` | `upcase` |

All built-in presets are string-safe: they apply their transform only when the value is a `String`; non-string values pass through unchanged.

## Scopes

This concern adds no ActiveRecord scopes.

## Methods

### Instance methods

#### `apply_normalizations`

```ruby
def apply_normalizations
```

Iterates over all rules declared with `normalizable` and applies each normalizer to the corresponding attribute. Called automatically via `before_validation`; `nil` values are skipped without transformation. Calling this method manually is not normally necessary but is safe to do so.

### Class methods

#### `normalizable(*fields, with:)`

```ruby
normalizable :email, with: :email
normalizable :first_name, :last_name, with: :whitespace
normalizable :code, with: ->(v) { v.to_s.parameterize }
```

Registers normalization rules on the class. Rules accumulate across multiple calls; later calls for the same field overwrite the previous rule for that field only. Raises `ArgumentError` on configuration errors (missing fields, unknown preset, invalid `with:` type, or non-existent database column).

## Examples

**Basic preset usage — email, phone, and name fields**

```ruby
class Contact < ApplicationRecord
  include ConcernsOnRails::Normalizable

  normalizable :email,                  with: :email
  normalizable :phone,                  with: :phone
  normalizable :first_name, :last_name, with: :whitespace
end

contact = Contact.new(
  email:      "  ALICE@Example.com  ",
  phone:      "+1 (415) 555-1234",
  first_name: "  Alice  ",
  last_name:  "  Smith  "
)
contact.valid?

contact.email      # => "alice@example.com"
contact.phone      # => "14155551234"
contact.first_name # => "Alice"
contact.last_name  # => "Smith"
```

**Custom lambda normalizer**

```ruby
class Product < ApplicationRecord
  include ConcernsOnRails::Normalizable

  normalizable :sku, with: ->(v) { v.to_s.tr("-", "_").upcase }
end

product = Product.new(sku: "abc-def-001")
product.valid?
product.sku # => "ABC_DEF_001"
```

**Pairing normalization with validation — validations see the normalized value**

```ruby
class Account < ApplicationRecord
  include ConcernsOnRails::Normalizable

  normalizable :email, with: :email

  # The format validator runs after before_validation, so it receives the
  # already-downcased, stripped value. Mixed-case input still passes.
  validates :email, format: { with: /\A[a-z0-9.+_-]+@[a-z0-9.-]+\z/ }
end

account = Account.new(email: "  ALICE@Example.com  ")
account.valid?  # => true
account.email   # => "alice@example.com"
```

## Notes & gotchas

- **Callback timing.** Normalization runs in `before_validation`, not `before_save`. Values are transformed before any ActiveRecord validators fire, so uniqueness validators, format validators, and length validators all operate on the normalized form.
- **`nil` is never coerced.** When a field's value is `nil`, `apply_normalizations` skips it entirely. No preset converts `nil` to `""` or any other value.
- **Non-string values pass through preset normalizers unchanged.** Every built-in preset guards with `v.is_a?(String)`, so applying `:downcase` to an integer column returns the integer unmodified rather than raising a `NoMethodError`.
- **Column existence is validated at class-load time.** If a field passed to `normalizable` does not exist in the database table, an `ArgumentError` is raised immediately when the class is evaluated (not at runtime), with the message `"does not exist in the database (table: <table_name>)"`. This is enforced by `ConcernsOnRails::Support::ColumnGuard`.
- **Multiple calls accumulate.** Each `normalizable` call merges its fields into the class-level `normalizable_rules` hash. Rules for distinct fields stack; if the same field appears in two separate calls, the later call's normalizer wins for that field.
- **`with:` accepts only `Symbol` or `Proc`.** Passing a `String` (e.g., `with: "downcase"`) raises `ArgumentError: :with must be a preset symbol or a Proc/lambda`. This catches the common mistake of quoting a preset name.
- **Unknown preset symbols raise immediately.** Passing an unrecognized symbol such as `with: :flarbgnarb` raises `ArgumentError: unknown preset '...'` and lists the valid preset names.
- **`normalizable_rules` is a `class_attribute`.** It is inherited by subclasses. Rules defined on a parent class apply to all subclasses via normal Ruby inheritance; subclasses can add their own rules without affecting the parent.
- **Works on Rails 5+.** The concern intentionally does not depend on Rails 7.1's built-in `normalizes` API, making it usable in projects that cannot upgrade to a recent Rails version.
- **No external gem dependency.** Unlike `Sluggable` or `Sortable`, `Normalizable` requires only `active_support/concern` and the `squish` method available in ActiveSupport, which is already a Rails dependency.
