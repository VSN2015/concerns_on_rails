Non-destructive display masking for sensitive model attributes. `Maskable` adds a `masked_<field>` reader for each declared field and **never writes to the database column** — the raw value is preserved exactly as stored, making masking a pure presentation concern. It ships five built-in masking presets (email, phone, credit card, last-four, and full mask) and accepts a custom `Proc` for arbitrary strategies. There are no runtime gem dependencies beyond `ActiveSupport`.

## When to use it

- Rendering email addresses in audit logs or admin UIs where only the domain and first character should be visible.
- Displaying payment card numbers in receipts or account pages where only the last four digits can be shown.
- Logging or serializing phone numbers with PII regulations (GDPR, CCPA) that prohibit full exposure.
- Showing SSNs or national ID numbers in read-only views where a partial hint is sufficient for identity confirmation.
- Building API responses that include a "safe" representation of a secret token or API key without exposing the full value.

## Installation

```ruby
class User < ApplicationRecord
  include ConcernsOnRails::Maskable

  maskable :email,  with: :email
  maskable :card,   with: :credit_card
  maskable :phone,  with: :phone
  maskable :ssn,    with: :last4, mask: "•"
  maskable :token,  with: ->(v) { "#{v.to_s[0, 3]}…" }
end
```

The fully-qualified alias `ConcernsOnRails::Models::Maskable` also works and is equivalent.

## Database columns

`Maskable` reads existing columns but never writes to them. No new columns are added. Each field passed to `maskable` must already exist in the model's database table, or an `ArgumentError` is raised at class-load time (see [Notes & gotchas](#notes--gotchas)).

The concern works with any column type. Preset masking methods are string-safe: a non-`String` value (e.g. an integer, `nil`) is returned untouched. Only `String` values are processed by the built-in presets.

## Configuration

The `maskable` macro is the sole configuration entry point. Multiple fields can be declared in a single call.

```ruby
maskable :field_one, :field_two, with: :last4, mask: "•"
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| *(positional args)* | `Symbol` (one or more) | — | One or more model attribute names to mask. At least one field is required. |
| `with:` | `Symbol` or `Proc` | `:all` | The masking strategy. Must be one of the built-in preset symbols or a `Proc`/lambda. |
| `mask:` | `String` | `"*"` | The character used as a replacement in preset strategies. Ignored when `with:` is a `Proc`. |

### Built-in presets

| Preset | Example input | Example output | Notes |
|--------|---------------|----------------|-------|
| `:all` | `"secret"` | `"******"` | Replaces every character. This is the default when `with:` is omitted. |
| `:email` | `"john.doe@example.com"` | `"j*******@example.com"` | Keeps the first character of the local part and the full domain. Strings without `@` are returned unchanged. |
| `:phone` | `"+1 (415) 555-2671"` | `"***-2671"` | Extracts all digits, keeps the last four. Returns the value unchanged if no digits are found. |
| `:credit_card` | `"4242424242424242"` | `"**** **** **** 4242"` | Extracts all digits, keeps the last four. Falls back to `:all` masking when four or fewer digits are present. |
| `:last4` | `"123456789"` | `"*****6789"` | Keeps the last four characters; fully masks values of four characters or fewer. |

## Methods

### Instance methods

For each field declared with `maskable`, the concern defines one reader on the model instance:

| Signature | Description |
|-----------|-------------|
| `masked_<field>` | Returns the masked representation of the attribute. Returns `nil` when the column value is `nil`. Returns non-`String` values unchanged (for preset strategies). |

### Class methods

| Signature | Description |
|-----------|-------------|
| `maskable(*fields, with: :all, mask: "*")` | Declares masking for one or more fields. Validates each field exists in the schema, validates the `with:` value, and defines the `masked_<field>` reader. Raises `ArgumentError` on misconfiguration. |

The class-level attribute `maskable_rules` (a `Hash` mapping field symbols to their resolved masker `Proc`) is exposed as a `class_attribute` but is intended for introspection only.

## Examples

### Email and credit card masking

```ruby
class User < ApplicationRecord
  include ConcernsOnRails::Maskable

  maskable :email, with: :email
  maskable :card,  with: :credit_card
end

user = User.new(email: "john.doe@example.com", card: "4242424242424242")
user.masked_email  # => "j*******@example.com"
user.masked_card   # => "**** **** **** 4242"
user.email         # => "john.doe@example.com"  (column untouched)
user.card          # => "4242424242424242"       (column untouched)
```

### Custom mask character and multiple fields in one call

```ruby
class Employee < ApplicationRecord
  include ConcernsOnRails::Maskable

  maskable :ssn, :tax_id, with: :last4, mask: "•"
end

emp = Employee.new(ssn: "123456789", tax_id: "987654321")
emp.masked_ssn    # => "•••••6789"
emp.masked_tax_id # => "•••••4321"
```

### Custom Proc strategy

```ruby
class ApiKey < ApplicationRecord
  include ConcernsOnRails::Maskable

  maskable :token, with: ->(v) { v.is_a?(String) ? "#{v[0, 4]}…[REDACTED]" : v }
end

key = ApiKey.new(token: "sk_live_abc123xyz")
key.masked_token  # => "sk_l…[REDACTED]"
key.token         # => "sk_live_abc123xyz"
```

## Notes & gotchas

- **Read-only by design.** `masked_<field>` is a reader-only method. There is no corresponding writer, and the concern never calls `write_attribute` or `update_column`. The raw value in the database is never modified.
- **Column existence is validated at class load time.** If a field passed to `maskable` does not exist in the model's database table, an `ArgumentError` is raised immediately (message: `"does not exist in the database"`). This means misconfiguration is caught at boot, not at runtime.
- **Unknown preset symbols raise immediately.** Passing a symbol to `with:` that is not one of `:email`, `:phone`, `:credit_card`, `:last4`, `:all` raises `ArgumentError` at class load time (message: `"unknown preset"`). The valid preset list is `ConcernsOnRails::Models::Maskable::PRESETS`.
- **`:with` must be a Symbol or Proc.** Any other type (e.g. a string, integer) raises `ArgumentError` (message: `":with must be a preset symbol or a Proc/lambda"`).
- **At least one field is required.** Calling `maskable` with no positional arguments (e.g. `maskable with: :all`) raises `ArgumentError` (message: `"at least one field is required"`).
- **`nil` values are passed through.** All preset strategies return `nil` when the column value is `nil`. When using a custom `Proc`, the caller is responsible for nil-guarding.
- **Non-String values are passed through by presets.** An integer or other non-String column value is returned as-is by every built-in preset. Custom `Proc` strategies receive the raw value and must handle type-checking themselves.
- **Email preset edge case.** If the column value is a string that does not contain `@`, the `:email` preset returns the value unchanged rather than masking it.
- **Phone preset edge case.** If the column value contains no digit characters, the `:phone` preset returns the value unchanged.
- **Credit card with four or fewer digits.** When a card value has four or fewer digit characters, `:credit_card` falls back to `:all` and masks every character rather than using the grouped format.
- **`maskable_rules` is a `class_attribute`.** Because `maskable_rules` is defined with `class_attribute`, subclasses inherit a reference to the parent's hash. Calling `maskable` in a subclass merges into a new hash (`self.maskable_rules = maskable_rules.merge(...)`) rather than mutating the parent, so subclass declarations do not bleed up.
- **No ActiveRecord callbacks or hooks.** The concern does not register `before_save`, `after_initialize`, or any other callback. There is no performance impact at persistence time.
- **No runtime gem dependencies.** `Maskable` requires only `active_support/concern`, the bundled `ConcernsOnRails::Support::Masker` helper, and the shared `ConcernsOnRails::Support::ColumnGuard` (used for the column-existence check). It does not depend on `friendly_id`, `acts_as_list`, or any other third-party gem.
