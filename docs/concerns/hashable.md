Auto-generates random identifiers — hex tokens, UUIDs, numeric codes, or values from a custom alphabet — and stores them in a model column on `before_create`. The concern eliminates the boilerplate of wiring `SecureRandom` into a callback, guards against overwriting values a caller supplies explicitly, and provides a `regenerate_<field>!` method for rotating credentials without deleting the record.

## When to use it

- Generating opaque, unguessable order or payment tokens that are safe to embed in URLs.
- Assigning RFC 4122 UUIDs as public-facing identifiers while keeping an auto-increment primary key internally.
- Creating fixed-length numeric confirmation codes (e.g. 6-digit SMS PINs) or redemption codes.
- Building human-readable codes from an unambiguous alphabet (no `0`/`O`/`I`/`1` confusion) for vouchers, support tickets, or invite keys.
- Any field that needs a random value at record creation time without coupling the model to `SecureRandom` directly.

## Installation

```ruby
class Order < ApplicationRecord
  include ConcernsOnRails::Hashable

  hashable_by :token                    # 32-char hex string (default)
end
```

The module is defined as `ConcernsOnRails::Models::Hashable`; `ConcernsOnRails::Hashable` is a legacy alias for the same module, so either include path works.

## Database columns

`hashable_by` targets a single column that you name in the macro call. The column type must match the chosen generator type.

| Column | Type | Notes |
|--------|------|-------|
| The field passed to `hashable_by` | `string` (hex, uuid, custom) or `integer` | Required. Must exist before the macro is called. |

> For `:integer` type with fixed-width codes such as `000042`, use a **string** column — an integer column silently drops leading zeros.

**Migration example**

```ruby
class AddTokenToOrders < ActiveRecord::Migration[7.1]
  def change
    add_column :orders, :token, :string
    add_index  :orders, :token, unique: true
  end
end
```

## Configuration

```ruby
hashable_by :field, type: :hex, length: 16, alphabet: nil
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `field` (positional, required) | `Symbol` | — | The model attribute that receives the generated value. The column must already exist in the schema. |
| `type:` | `Symbol` | `:hex` | Generator strategy. Valid values: `:hex`, `:uuid`, `:integer`, `:custom`. Any other value raises `ArgumentError`. |
| `length:` | `Integer` | `16` | For `:hex`: byte count (output string is `length * 2` characters). For `:integer`: number of digits. For `:custom`: output length in characters. Ignored by `:uuid`. |
| `alphabet:` | `String` | `nil` | Required when `type: :custom`. A non-empty string of characters to sample from uniformly via `SecureRandom`. Raises `ArgumentError` if omitted or empty when `type: :custom`. |

**Generator output summary**

| `type:` | `length:` meaning | Example output |
|---------|-------------------|----------------|
| `:hex` | byte count → `length * 2` hex chars | `"a3f7c9b1e2d40859e2f1c9b73d40a857"` |
| `:uuid` | ignored | `"550e8400-e29b-41d4-a716-446655440000"` |
| `:integer` | digit count, returns a Ruby `Integer` | `483921` |
| `:custom` | output character count | `"K7M3PQ9A"` |

## Methods

### Instance methods

| Signature | Description |
|-----------|-------------|
| `regenerate_<field>!` | Generates a new random value and immediately persists it with `update!`. The method name is derived from the configured field, e.g. `regenerate_token!` or `regenerate_external_id!`. |

### Class methods

| Signature | Description |
|-----------|-------------|
| `hashable_by(field, type:, length:, alphabet:)` | Configuration macro. Validates options, registers the `before_create` callback, and defines `regenerate_<field>!`. |
| `generate_hashable_value` | Generates and returns a single value using the current `hashable_type`, `hashable_length`, and `hashable_alphabet` settings. Public; useful for testing or manual assignment. |

## Examples

**Hex token (default)**

```ruby
class Order < ApplicationRecord
  include ConcernsOnRails::Hashable

  hashable_by :token, type: :hex, length: 16
end

order = Order.create!(name: "Widget")
order.token              # => "a3f7c9b1e2d40859e2f1c9b73d40a857"  (32 hex chars)

order.regenerate_token!
order.token              # => new 32-char hex string, persisted immediately
```

**UUID as a public-facing identifier**

```ruby
class ApiClient < ApplicationRecord
  include ConcernsOnRails::Hashable

  hashable_by :external_id, type: :uuid
end

client = ApiClient.create!
client.external_id  # => "550e8400-e29b-41d4-a716-446655440000"
```

**Human-readable invite code from a custom alphabet**

```ruby
class Invitation < ApplicationRecord
  include ConcernsOnRails::Hashable

  # Crockford-style alphabet — no ambiguous characters (0/O, I/1)
  hashable_by :code,
              type:     :custom,
              length:   8,
              alphabet: "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
end

invite = Invitation.create!
invite.code  # => "K7M3PQ9A"  (8 chars, only from the given alphabet)
```

## Notes & gotchas

- **`before_create` only, not `before_save`** — the value is generated once at creation and never overwritten by the callback on subsequent saves. Use `regenerate_<field>!` to rotate an existing value.
- **Explicit values are preserved** — `assign_hashable_value` checks `self[field].present?` before assigning. Passing `token: "my-value"` to `create!` keeps `"my-value"` intact.
- **Column must exist at class load time** — `hashable_by` calls `ensure_columns!` immediately via `ConcernsOnRails::Support::ColumnGuard`. Defining the macro before running the migration, or in a class that maps to a table without the column, raises `ArgumentError: '...' does not exist in the database (table: ...)`.
- **Unknown `type:` raises `ArgumentError`** — only `:hex`, `:uuid`, `:integer`, and `:custom` are accepted. Passing anything else (e.g. `type: :base64`) raises immediately at macro call time.
- **`type: :custom` requires a non-empty `alphabet:` String** — omitting `alphabet:` or passing an empty string raises `ArgumentError: ConcernsOnRails::Models::Hashable: type :custom requires a non-empty alphabet: String`.
- **`:integer` output is a Ruby `Integer`** — the generated value is in the range `0..(10**length - 1)`. It is zero-padded internally during generation but stored as a numeric type; if leading-zero preservation matters (e.g. `000042`), declare a `string` column instead.
- **`:hex` output length is `length * 2`** — because `SecureRandom.hex(n)` returns `n` bytes encoded as hex. A `length: 16` configuration produces a 32-character string.
- **No uniqueness retry** — the concern does not rescue `ActiveRecord::RecordNotUnique` or retry on collision. For collision-prone configurations (short integer codes, short hex), add a unique index and handle `ActiveRecord::RecordNotUnique` at the application level.
- **`before_create` fires after `before_validation`** — if the model has `validates :token, presence: true`, the validation runs before the token is assigned, causing a false failure. Work around this by adding `before_validation { self.token ||= self.class.generate_hashable_value }` in your model, or by removing the presence validation (the concern guarantees assignment on create).
- **`regenerate_<field>!` uses `update!`** — it will raise `ActiveRecord::RecordInvalid` if other model validations fail at that point.
- **`generate_hashable_value` is a public class method** — it can be called directly in tests or console sessions without creating a record: `Order.generate_hashable_value`.
