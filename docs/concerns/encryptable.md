The `Encryptable` concern adds **transparent field-level encryption** to any ActiveRecord model — encrypt sensitive columns (SSN, date of birth, card numbers, notes) at rest with authenticated **AES-256-GCM**, using only Ruby's stdlib OpenSSL (no new dependency). Reads and writes stay plaintext; the column stores a versioned, tamper-evident ciphertext envelope. It is implemented as a custom `ActiveModel::Type`, so encryption is invisible to the rest of the stack and composes with sibling concerns like Maskable and Normalizable. On Rails 7.1+ you may prefer the framework-native `encrypts`; this concern gives you the same transparent encryption on Rails 5.0–7.0 with no app config.

## When to use it

- Store regulated / sensitive fields — SSN, DOB, government IDs, card numbers — encrypted at rest.
- Keep the model API ergonomic: `patient.ssn` reads and writes plaintext; the database never sees it.
- Combine with `Maskable` (show `***6789`) and `Normalizable` (strip before encrypting) on the same field.
- You target Rails 5.0–7.0 and want the transparency of Rails 7.1's `encrypts` without upgrading.

## Configure a key

The gem is agnostic about where your secret lives — you supply it once, usually from credentials or ENV. A key may be raw 32-byte binary, a 64-char hex string, or any passphrase (stretched to 32 bytes with PBKDF2-HMAC-SHA256).

```ruby
# config/initializers/concerns_on_rails.rb
ConcernsOnRails.configure_encryption do |c|
  c.key = -> { Rails.application.credentials.dig(:encryption, :key) }
end
```

## Declaring encrypted fields

```ruby
class Patient < ApplicationRecord
  include ConcernsOnRails::Encryptable

  encryptable :ssn, :notes                 # transparent string encryption
  encryptable :dob, type: :date            # decrypts back to a Date
  encryptable :card, key: -> { Rails.application.credentials.dig(:pci, :key) }
end

p = Patient.create!(ssn: "123-45-6789", dob: Date.new(1990, 1, 1))
p.ssn                 # => "123-45-6789"
p.reload.dob          # => Wed, 01 Jan 1990   (a Date)
p.ssn_ciphertext      # => "AQEA…"  (Base64 envelope — no plaintext at rest)
p.ssn_encrypted?      # => true
```

## Database columns

The declared column stores the Base64 ciphertext envelope, **not** the logical type — always use `text` (or `binary`), never a typed column. The envelope carries a version byte, algorithm byte, key id, a 12-byte IV, a 16-byte GCM auth tag, and the ciphertext, so even a one-character value is ~42 bytes.

```ruby
class AddEncryptedFieldsToPatients < ActiveRecord::Migration[7.1]
  def change
    add_column :patients, :ssn,   :text
    add_column :patients, :notes, :text
    add_column :patients, :dob,   :text   # a :date field is still a TEXT column
  end
end
```

## Configuration

### `encryptable(*fields, type: :string, key: nil, blind_index: nil)`

Repeatable — each call declares more encrypted fields. Rules accumulate (reassigned, never mutated, so subclasses inherit). All configuration errors raise `ArgumentError` at declaration time.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `*fields` | `Symbol…` | — (required) | One or more `text`/`binary` columns to encrypt. |
| `type:` | `Symbol` | `:string` | Casts the decrypted value: `:string`, `:integer`, `:float`, `:decimal`, `:boolean`, `:date`, `:datetime` (the Storable caster set; `:decimal` precision-safe, `:datetime` UTC microseconds). |
| `key:` | `String` / `Proc` / `nil` | `nil` | Per-field key override (raw / hex / passphrase, or a lazy Proc). Falls back to the gem-level `ConcernsOnRails.encryption` key. |
| `blind_index:` | `true` / `Hash` / `nil` | `nil` | Maintain a deterministic fingerprint column for exact-match lookups. `true` uses `<field>_bidx`; a Hash accepts `column:` and `expression:` (a callable normalizer applied on write and query). See below. |

### Gem-level configuration — `ConcernsOnRails.encryption`

| Setting | Default | Description |
|---------|---------|-------------|
| `key` | `nil` | Global key (String / 64-hex / 32-byte binary / Proc). |
| `key_derivation_salt` | fixed constant | PBKDF2 salt — **part of the derived key's identity**; change it and existing ciphertext no longer decrypts. |
| `on_missing_key` | `:raise` | `:raise` (prod) or `:passthrough` (dev/test escape hatch: stores/reads plaintext when no key is set). |
| `raise_on_decrypt_error` | `true` | `true` raises `DecryptionError` on a bad read; `false` returns `nil` (a narrow, less-safe opt-out). |

## Accessor surface

- `field` / `field=` — plaintext in, plaintext out (crypto happens at the DB boundary).
- `field_ciphertext` — the raw stored envelope once persisted (for migrations, debugging, and asserting no plaintext is at rest).
- `field_encrypted?` — whether a value is currently stored.

## Querying encrypted fields (blind index)

Encrypted columns are **not** directly queryable — the ciphertext is non-deterministic (a fresh random IV per write), so `where(email: "a@b.com")` re-encrypts the value with a *different* IV and matches nothing. To look up records by an encrypted value, opt into a **blind index**: a deterministic keyed HMAC of the value, stored in a companion column and indexed.

```ruby
# migration
add_column :users, :email_bidx, :string
add_index  :users, :email_bidx

class User < ApplicationRecord
  include ConcernsOnRails::Encryptable

  # case/space-insensitive lookups: normalize on both write and query
  encryptable :email, blind_index: { expression: ->(v) { v.to_s.downcase.strip } }
end

user = User.create!(email: "Alice@Example.com")

User.find_by_email("alice@example.com")   # => #<User ...>   (exact-match, indexed)
User.where_email("alice@example.com")     # => ActiveRecord::Relation
User.email_fingerprint("alice@example.com") # => "e7f3…"  (the stored digest)
```

`where_<field>` returns a plain Relation, so every standard composition works:

```ruby
# chaining with scopes and further conditions (either order)
User.active.where_email("alice@example.com")
User.where_email("alice@example.com").where(active: true)

# multiple values -> one IN query
User.where_email("alice@example.com", "bob@example.com")
User.where_email(emails_array)

# OR / NOT
User.where_email("a@x.com").or(User.where_email("b@x.com"))
User.where.not(email_bidx: User.email_fingerprint("a@x.com"))

# joins from another model: merge the relation, or target the bidx column
Order.joins(:user).merge(User.where_email("alice@example.com"))
Order.joins(:user).where(users: { email_bidx: User.email_fingerprint("alice@example.com") })
```

- `blind_index: true` uses a `<field>_bidx` column and no normalization; pass a Hash to set `column:` and/or `expression:`.
- The fingerprint's HMAC key is **domain-separated** from the encryption key (derived via a labeled HMAC), so the two are independent even though both come from your configured key.
- The index is recomputed automatically in `before_save`, but only when the field actually changes; a `nil` value yields a `nil` fingerprint.
- **Only exact match** is possible — no `LIKE`, ranges, or `ORDER BY` on the value. A deterministic index **leaks equality** (identical values share a digest), so use it for lookup keys, not low-entropy fields.
- Backfilling existing rows: re-save them (`User.find_each(&:save!)`) so the index populates.

## Composition with other concerns

- **Normalizable** — normalization runs `before_validation` on the plaintext; encryption happens later, at the DB-serialization boundary. So the stored ciphertext is always of the *normalized* value, regardless of `include` order.
- **Maskable** — `masked_<field>` masks the *decrypted* value; the column stays ciphertext. Order-independent.
- **Auditable** — auditing an encrypted field would persist its plaintext into the audit column, so declaring a field with **both** `encryptable` and `auditable_by` **raises**. Audit a non-sensitive companion column instead.
- **Searchable / Filterable** — encrypted columns are **not** searchable: non-deterministic ciphertext (random IV) means the same plaintext never produces the same bytes, so `where(:ssn)`, `LIKE`, and prefix matching cannot work. For exact-match lookups, add a [blind index](#querying-encrypted-fields-blind-index) and query the `<field>_bidx` column (via `find_by_<field>` / `where_<field>`).

## Security notes

- **AES-256-GCM is authenticated.** A wrong key, a tampered ciphertext, or a corrupted envelope fails the auth tag and raises `DecryptionError` — it never returns garbage plaintext.
- **The header is authenticated too.** The version/algorithm/key-id bytes are fed to GCM as additional authenticated data (AAD), so they cannot be altered.
- **Non-deterministic by design.** Every write uses a fresh random IV, so identical plaintext yields different ciphertext — no equality leakage, but also no equality queries.
- **Never `update_column` / `update_columns` an encrypted field.** Those bypass the type and write raw plaintext straight to the column.
- **Keep the KDF salt stable.** It is part of the key's identity; rotating it orphans existing ciphertext.

## Notes & gotchas

- `nil` stays `nil` (the column is left NULL) — a blank value is never encrypted.
- Dirty tracking works on the decrypted plaintext: reassigning the same value is **not** dirty, and an unchanged field is not re-encrypted on save, despite the random IV.
- The envelope is versioned (`ver`/`alg`/`key_id` bytes reserved), so **deterministic (queryable) fields and multi-key rotation** can be added later without a data migration.
- Reach for [`lockbox`](https://github.com/ankane/lockbox) or Rails 7.1+ native [`encrypts`](https://guides.rubyonrails.org/active_record_encryption.html) when you need blind indexes, deterministic search, or built-in key rotation today.
