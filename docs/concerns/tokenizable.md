The `Tokenizable` concern generates and manages cryptographically random security tokens directly on ActiveRecord model columns. It solves the repetitive boilerplate of wiring up `SecureRandom`, auto-generating tokens on create, rotating or revoking them later, and performing timing-safe lookups — all while supporting multiple independently-configured token fields on a single model.

## When to use it

- A `User` model needs an `api_token` for programmatic API authentication and a separate `reset_password_token` for email-based password resets.
- An `Invitation` model issues single-use `invite_code` values that must be short, human-readable, and alphanumeric.
- A `Share` model generates a URL-safe `share_token` that is embedded in public links and must be resistant to timing attacks when validated.
- A `Device` model needs a numeric `pin` of fixed length for out-of-band verification.
- Any record that must support token revocation (e.g. OAuth refresh tokens, session tokens) without deleting the row.

## Installation

```ruby
class User < ApplicationRecord
  include ConcernsOnRails::Tokenizable

  tokenizable_by :api_token                              # 32-char URL-safe (default)
  tokenizable_by :reset_password_token, length: 24
  tokenizable_by :invite_code, type: :alphanumeric, length: 8
end
```

The fully-qualified alias `ConcernsOnRails::Models::Tokenizable` also works and is the name used in error messages.

## Database columns

Each field passed to `tokenizable_by` must already exist as a string column. Add one column per declared token field.

| Column | Type | Required |
|---|---|---|
| _(field name, e.g. `api_token`)_ | `string` | Yes |

```ruby
class AddTokensToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :api_token,            :string
    add_column :users, :reset_password_token, :string
    add_column :users, :invite_code,          :string

    # Recommended: unique index per token field used in lookups
    add_index :users, :api_token,            unique: true
    add_index :users, :reset_password_token, unique: true
    add_index :users, :invite_code,          unique: true
  end
end
```

## Configuration

Call `tokenizable_by` once per token field. Multiple calls on the same model are additive and do not interfere with one another.

```ruby
tokenizable_by(field, type: :urlsafe, length: 32)
```

| Option | Type | Default | Description |
|---|---|---|---|
| `field` | `Symbol` / `String` | — (required) | The model column that stores the token. Converted to a symbol internally. Must exist in the database schema at class-load time or `ArgumentError` is raised. |
| `type:` | `Symbol` | `:urlsafe` | Token character set. Valid values: `:urlsafe`, `:hex`, `:alphanumeric`, `:numeric`. Any other value raises `ArgumentError`. |
| `length:` | `Integer` | `32` | Exact character length of the generated token. Must be a positive integer; `0` or negative raises `ArgumentError`. Converted via `to_i`, so string digits are accepted. |

**Type reference**

| Type | Alphabet | Notes |
|---|---|---|
| `:urlsafe` | `A–Z`, `a–z`, `0–9`, `-`, `_` | Uses `SecureRandom.urlsafe_base64`; safe for URLs, HTTP headers, and cookies without encoding. |
| `:hex` | `0–9`, `a–f` | Uses `SecureRandom.hex`; lowercase hex digits only. |
| `:alphanumeric` | `A–Z`, `a–z`, `0–9` | Sampled uniformly via `SecureRandom.random_number`; no special characters. |
| `:numeric` | `0–9` | Sampled uniformly via `SecureRandom.random_number`; useful for PINs and OTPs stored as strings. |

## Scopes

`Tokenizable` does not add any ActiveRecord scopes. Use Rails' built-in `find_by_<field>` or the concern's `authenticate_by_<field>` class method for lookups.

## Methods

### Instance methods

For each field declared with `tokenizable_by`, the following instance methods are defined dynamically (shown here for a field named `api_token`):

| Method | Description |
|---|---|
| `regenerate_api_token!` | Generates a new token value and immediately persists it with `update!`. Overwrites the existing value unconditionally. |
| `revoke_api_token!` | Sets the column to `nil` and immediately persists the change with `update!`. |
| `api_token?` | Returns `true` if the column value is present (non-nil, non-blank), `false` otherwise. |

### Class methods

| Method | Description |
|---|---|
| `tokenizable_by(field, type:, length:)` | Configuration macro. Registers the field, validates options, installs a `before_create` callback, and defines all helper methods for that field. |
| `generate_tokenizable_value(field)` | Generates and returns a new random value for the given field using its registered type and length. Raises `ArgumentError` if `field` is not a registered tokenizable field. |
| `authenticate_by_api_token(value)` | _(one per field)_ Looks up a record by the token column and performs a constant-time comparison using `ActiveSupport::SecurityUtils.secure_compare`. Returns the matching record or `nil`. Returns `nil` immediately for blank input. |

## Examples

**Basic API token with timing-safe lookup**

```ruby
class User < ApplicationRecord
  include ConcernsOnRails::Tokenizable

  tokenizable_by :api_token
end

user = User.create!(name: "Alice")
user.api_token          # => "k3Jf8_mQpR..." (32 URL-safe chars, auto-generated)
user.api_token?         # => true

# Timing-safe authentication (use this instead of find_by in security-sensitive paths)
User.authenticate_by_api_token(request.headers["Authorization"])
# => <User id=1 ...> or nil

# Token rotation
user.regenerate_api_token!
user.reload.api_token   # => new value, different from the original

# Revocation
user.revoke_api_token!
user.reload.api_token?  # => false
```

**Multiple token fields with different types and lengths**

```ruby
class User < ApplicationRecord
  include ConcernsOnRails::Tokenizable

  tokenizable_by :api_token                              # 32-char :urlsafe
  tokenizable_by :reset_password_token, length: 24      # 24-char :urlsafe
  tokenizable_by :invite_code, type: :alphanumeric, length: 8
end

user = User.create!(email: "alice@example.com")
user.api_token.length            # => 32
user.reset_password_token.length # => 24
user.invite_code.length          # => 8
user.invite_code                 # => "Xk3mPq9A" (A-Z, a-z, 0-9 only)
```

**Numeric PIN with pre-set value**

```ruby
class Device < ApplicationRecord
  include ConcernsOnRails::Tokenizable

  tokenizable_by :pin, type: :numeric, length: 6
end

# Caller-supplied values are not overwritten
device = Device.create!(pin: "000000")
device.pin  # => "000000"  (the preset value, not replaced)

# Let the concern generate it
device2 = Device.create!
device2.pin  # => "847203" (random 6-digit string)
```

## Notes & gotchas

- **Column must exist at class load time.** `tokenizable_by` calls `ensure_columns!` immediately when the macro is evaluated. If the migration has not been run, Rails will raise `ArgumentError: '...' does not exist in the database (table: ...)` as soon as the class is loaded, not at runtime.
- **Caller-supplied values are preserved.** The `before_create` callback calls `assign_tokenizable_value` only when the column is blank. `User.create!(api_token: "preset")` will store `"preset"` unchanged.
- **Tokens are generated on `create` only.** There is no `before_save` or `before_update` callback. Tokens do not rotate automatically on update; call `regenerate_<field>!` explicitly when rotation is needed.
- **Uniqueness retry with a ceiling.** Before assigning a generated value, the concern queries the database with `unscoped.exists?` to detect collisions. It retries up to `MAX_GENERATION_ATTEMPTS` (10) times. If all 10 attempts collide, it raises a `RuntimeError` matching `/could not generate a unique value/`. This is a best-effort guard; a unique database index is the authoritative uniqueness constraint and should always accompany short or low-entropy token fields (`:numeric`, short `:alphanumeric`).
- **Timing-safe lookup requires exact byte-length match.** `authenticate_by_<field>` returns `nil` if the stored token and the supplied value have different byte sizes, before `secure_compare` is called. This prevents length-oracle attacks but means tokens containing multi-byte characters (unlikely given the alphabets) would require special handling.
- **`authenticate_by_<field>` returns `nil` for blank input.** Passing `nil` or `""` short-circuits the lookup entirely without hitting the database.
- **Subclass isolation.** `tokenizable_fields` is a `class_attribute` that merges into a fresh hash on each `tokenizable_by` call, so subclasses that call `tokenizable_by` do not mutate the parent class's configuration.
- **`:urlsafe` token length.** `SecureRandom.urlsafe_base64(n)` returns a base64-encoded string longer than `n` bytes. The concern slices the result to exactly `length` characters with `[0, length]`, so the output length is always exactly what was configured.
- **`:hex` token length.** `SecureRandom.hex` generates a string twice the byte count. The concern requests `(length + 1) / 2` bytes and then slices to `length`, ensuring both odd and even lengths are handled correctly.
- **No ActiveRecord validations are added.** The concern does not add presence or uniqueness validations to the model. Add these manually if application logic requires them; rely on a unique database index for collision prevention rather than ActiveRecord-level uniqueness validators.
- **`generate_tokenizable_value` is a public class method.** It can be called directly (e.g. in tests or seeds) without creating a record, but it raises `ArgumentError` if the field name is not registered via `tokenizable_by`.
