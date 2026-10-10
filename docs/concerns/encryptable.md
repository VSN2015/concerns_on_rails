The `Encryptable` concern adds **transparent field-level encryption** to any ActiveRecord model — encrypt sensitive columns (SSN, date of birth, card numbers, notes) at rest with authenticated **AES-256-GCM**, using only Ruby's stdlib OpenSSL (no new dependency). Reads and writes stay plaintext; the column stores a versioned, tamper-evident ciphertext envelope. It is implemented as a custom `ActiveModel::Type`, so encryption is invisible to the rest of the stack and composes with sibling concerns like Maskable and Normalizable. On Rails 7.1+ you may prefer the framework-native `encrypts`; this concern gives you the same transparent encryption on Rails 6.0–7.0 with no app config.

## When to use it

- Store regulated / sensitive fields — SSN, DOB, government IDs, card numbers — encrypted at rest.
- Keep the model API ergonomic: `patient.ssn` reads and writes plaintext; the database never sees it.
- Combine with `Maskable` (show `***6789`) and `Normalizable` (strip before encrypting) on the same field.
- You target Rails 6.0–7.0 and want the transparency of Rails 7.1's `encrypts` without upgrading.

## Configure a key

The gem is agnostic about where your secret lives — you supply it once, usually from credentials or ENV. A key may be raw 32-byte binary, a 64-char hex string, or any passphrase (stretched to 32 bytes with PBKDF2-HMAC-SHA256).

```ruby
# config/initializers/concerns_on_rails.rb
ConcernsOnRails.configure_encryption do |c|
  c.key = -> { Rails.application.credentials.dig(:encryption, :key) }
end
```

| Setting | Default | Description |
|---|---|---|
| `key` | `nil` | The key every new write is encrypted with (raw 32 bytes, 64-hex, a passphrase, or a Proc returning one). Missing → `MissingKeyError` at first use. |
| `key_id` | `0` | The id (0–255) stamped into the envelope header of everything written with `key`. Bump it when you rotate. Any id in the range works. |
| `previous_keys` | `{}` | `{ key_id => material-or-Proc }` — keys that may still **decrypt** rows written before a rotation. Never used to encrypt. |
| `key_derivation_salt` | fixed | PBKDF2 salt; part of the key's identity — keep it stable. |
| `on_missing_key` | `:raise` | `:passthrough` stores/reads plaintext when no key is configured (dev/test escape hatch). |
| `raise_on_decrypt_error` | `true` | `false` returns `nil` instead of raising on a bad read. |

## Key rotation

Every envelope carries the id of the key that wrote it, so old and new rows coexist and reads pick the right key automatically. Rotating is four steps:

```ruby
# 1. Deploy the new key as current, keep the old one for decrypting
ConcernsOnRails.configure_encryption do |c|
  c.key           = -> { Rails.application.credentials.dig(:encryption, :key_v2) }
  c.key_id        = 1
  c.previous_keys = { 0 => -> { Rails.application.credentials.dig(:encryption, :key_v1) } }
end

# 2. See what's left under old keys — a compare against the fixed 4-char Base64 header prefix, no decryption
Patient.needs_reencryption.count           # every gem-keyed encrypted field — EVERY row, default_scope ignored
Patient.needs_reencryption(:ssn).count     # one field

# 3. Rewrite them under the current key (blind indexes refreshed) — idempotent, streams with find_each
Patient.reencrypt_all!                     # => 12_034 rows — soft-deleted / unpublished rows included
patient.ssn_key_id                         # => 1   (nil before anything is stored)
patient.reencrypt!                         # one record

# 4. Once Patient.needs_reencryption is empty for every model, drop `0 =>` from previous_keys
```

- **The sweep covers the whole table.** Called on the model itself, `needs_reencryption` and `reencrypt_all!` bypass the `default_scope`: rows hidden by SoftDeletable or Publishable's `default_scope: true` still hold ciphertext under the old key, and once that key leaves `previous_keys` they could never be decrypted again — a `restore!` would bring back an unreadable record. Called on a **relation** (`Patient.where(org_id: 1).reencrypt_all!`, an association, a `scoping` block) they cover exactly that relation, default scope included like any other chain; start from `unscoped` (`Patient.unscoped.where(org_id: 1).reencrypt_all!`) to include hidden rows in a subset. Run step 4's check on the model, not on a relation.

- **Blind indexes during the window.** `find_by_<field>` / `where_<field>` match the digest under the current key **and** every previous key, so a row indexed under key 0 is still found before it is re-encrypted; `<field>_fingerprint` returns the current-key digest (what gets written). `reencrypt_all!` rewrites the index column too.
- **`reencrypt_all!` writes one UPDATE per row** — no validations, no callbacks, no `updated_at` bump, and no `lock_version` bump on a model with optimistic locking (the column is pinned to itself in the UPDATE): the values do not change, only their ciphertext, so an Auditable capture or webhook must not fire for a key rotation, and a record someone has open in an edit form during the sweep must not turn into a `StaleObjectError`. Each row is valid before and after, so there is no wrapping transaction to hold. This is the one `*_all` verb that does NOT go through `Support::BatchOps`: it is re-runnable rather than atomic, so a row that raises mid-stream leaves the rows before it already rotated, and re-running picks up the rest.
- **Safe to run against a live table.** Each row's UPDATE is guarded on the exact ciphertext it was read with (`WHERE id = ? AND ssn = <ciphertext at load>`), so a value the app wrote between the read and the write is never reverted to the stale plaintext — the row is simply skipped, and it needs no rotating anyway because that write already used the current key. For the same reason `record.reencrypt!` skips a field with an unsaved change instead of committing it without validations. A successful `reencrypt!` reloads the record, so its `<field>_ciphertext` / `<field>_key_id` describe what is now at rest.
- **Per-field `key:` fields are outside rotation.** They always stamp key id 0, decrypt with their own key, and are skipped by `needs_reencryption` / `reencrypt_all!`. Rotate them by changing the field key and re-saving.
- **Unknown key id.** A row whose id is neither `key_id` nor in `previous_keys` raises `DecryptionError` ("encrypted with unknown key id N") — you removed a previous key too early.
- **Every key id 0..255 works.** `needs_reencryption` compares the envelope's 4-character Base64 header with `SUBSTR(...) <> ?` (a binary cast on MySQL), not `LIKE`. A case-folding comparison would have confused ids 26–51 with 0–25, whose prefixes differ only in case, and quietly reported that nothing needed rotating.

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
| `type:` | `Symbol` | `:string` | Casts the decrypted value: `:string`, `:integer`, `:float`, `:decimal`, `:boolean`, `:date`, `:datetime` (the Storable caster set; `:decimal` precision-safe, `:datetime` UTC microseconds). A `:datetime` field behaves like a datetime column on the same model: see [Notes](#notes--gotchas). |
| `key:` | `String` / `Proc` / `nil` | `nil` | Per-field key override (raw / hex / passphrase, or a lazy Proc). Falls back to the gem-level `ConcernsOnRails.encryption` key. |
| `blind_index:` | `true` / `Hash` / `nil` | `nil` | Maintain a deterministic fingerprint column for exact-match lookups. `true` uses `<field>_bidx`; a Hash accepts `column:` and `expression:` (a callable normalizer applied on write and query). See below. |

### Blind index of a typed field

The fingerprint is the keyed HMAC of the field's **canonical plaintext**, which is exactly what the cipher encrypts: the value cast through the field's `type:`, a `:datetime` as UTC ISO8601 with microseconds. Writes and lookups take the same form. So `find_by_meeting_at` finds a record by any rendering of the instant (a `Time` in any zone, `"2026-10-01T13:00:00Z"`, or a zone-less String read the way the writer reads it), whatever `Time.zone` the writer and the reader ran in, and `find_by_age("42")` finds `age: 42`. `expression:` receives that cast value (a `:datetime` as a UTC `Time`), not the raw argument.

Lookups also try the digest of the argument's own `to_s`, which is what the index hashed before this change. So a row indexed then is still found by the same lookup that found it then. For every type except `:datetime` the two digests are identical and nothing needs reindexing. For a **`:datetime` field** (or a typed field with an `expression:` that renders a time), rewrite the index once so that every rendering finds it:

```ruby
Meeting.unscoped.where.not(starts_at: nil).find_each do |meeting|
  starts_at = meeting.starts_at
  next if starts_at.nil? # undecryptable (raise_on_decrypt_error off): keep the digest it has

  meeting.update_columns(starts_at_bidx: Meeting.starts_at_fingerprint(starts_at))
end
```

`update_columns` writes only the digest column: no callbacks, and the ciphertext is untouched. A row whose ciphertext no current or previous key can decrypt reads as `nil` (or raises, with `raise_on_decrypt_error` on). The `next` keeps its old digest instead of erasing it.

### Gem-level configuration — `ConcernsOnRails.encryption`

| Setting | Default | Description |
|---------|---------|-------------|
| `key` | `nil` | Global key (String / 64-hex / 32-byte binary / Proc). |
| `key_derivation_salt` | fixed constant | PBKDF2 salt — **part of the derived key's identity**; change it and existing ciphertext no longer decrypts. |
| `on_missing_key` | `:raise` | `:raise` (prod) or `:passthrough` (dev/test escape hatch: stores/reads plaintext when no key is set). |
| `raise_on_decrypt_error` | `true` | `true` raises `DecryptionError` on a bad read; `false` returns `nil` (a narrow, less-safe opt-out). |

## Accessor surface

- `field` / `field=` — plaintext in, plaintext out (crypto happens at the DB boundary).
- `field_ciphertext` — the raw stored envelope once persisted (for migrations, debugging, and asserting no plaintext is at rest). `nil` while the field carries an unsaved change (a new record, or any pending assignment), so it can never hand back the plaintext you just assigned. After a save or `update_columns` it is exactly what was written: Rails 6.0–7.0 re-serialize the value in memory with a fresh IV after every write, so on those versions the concern re-reads the stored ciphertext (one extra raw `SELECT` of the encrypted columns per write) — which is also what lets `reencrypt!` rotate an instance that was just saved.
- `field_encrypted?` — whether what is stored really is an encryption envelope (not merely whether a value is present). Honestly `false` under `on_missing_key: :passthrough`, where plaintext at rest is the opted-into behaviour.

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
- The index is recomputed automatically just before the row is written — in `before_create`/`before_update`, which run after every `before_save` callback (your own `before_save { self.email = email.downcase }` included), so the digest is always of the value actually stored. On update only a changed field is refreshed; a new row refreshes every indexed field, so a copy (`dup`, a [Duplicable](duplicable.md) reset) never keeps its original's digest. A `nil` value yields a `nil` fingerprint. (A `before_create` of your own that rewrites the field after the include is still not seen.) A value a sibling generates later in the create — a [Tokenizable](tokenizable.md) token, a [Hashable](hashable.md) code, a [Sequenceable](sequenceable.md) number, all assigned in `before_create` — is fingerprinted when it is generated (`Support::GeneratedValues`), so a freshly created record is findable by `find_by_<field>` in either declaration order (it used to be stored with a NULL fingerprint).
- On Rails 7.1+, the field's `normalizes` applies to lookups as well: `find_by_<field>`, `where_<field>` and `<field>_fingerprint` normalize their argument first, as Rails' own `find_by(email:)` does, so `find_by_email("Alice@Example.COM")` finds the row stored as `alice@example.com`.
- **Only exact match** is possible — no `LIKE`, ranges, or `ORDER BY` on the value. A deterministic index **leaks equality** (identical values share a digest), so use it for lookup keys, not low-entropy fields.
- Backfilling existing rows: re-save them (`User.find_each(&:save!)`) so the index populates.

## Composition with other concerns

- **Normalizable** — normalization runs on the plaintext in `before_validation`, and, for saves that skip validation (`update_attribute`, `save(validate: false)`), in a `before_save` backstop that Normalizable *prepends* to the save callbacks — so it runs ahead of the blind-index refresh (a `before_create`/`before_update`, after every `before_save`) whichever concern was included first. Encryption happens later still, at the DB-serialization boundary. So the stored ciphertext and the blind-index fingerprint are both of the *normalized* value, regardless of `include` order, and `find_by_<field>` finds what was stored. (`update_column(s)`/`update_all` skip callbacks: they neither normalize nor refresh the index.)
- **Lockable** — Lockable's `unlock_token:` column cannot be encrypted: the token is minted, claimed and cleared by callback-skipping SQL keyed on the column's value, so an encrypted token would never be found and every unlock link would be dead. Declaring both raises `ArgumentError`, in either order. The token is random, single-use and cleared with the lock, so keep it a plain column.
- **Maskable** — `masked_<field>` masks the *decrypted* value; the column stays ciphertext. Order-independent.
- **Auditable** — auditing an encrypted field would persist its plaintext into the audit column, so declaring a field with **both** `encryptable` and `auditable_by` **raises**. Audit a non-sensitive companion column instead.
- **Sluggable** — a friendly_id slug is plaintext of its source (`"123-45-6789"`), so an encrypted field named as the `sluggable_by` field or in its `candidates:` (nested arrays included) — or as a bare `friendly_id :field, use: :slugged` base — **raises** at declaration. Shapes a declaration cannot see (Sluggable included without `sluggable_by`, which slugs the implicit `:name`; friendly_id declared after `encryptable`) are refused at save time, before the row is written, with the same `ArgumentError`. A method or Proc candidate that reads an encrypted field under another name cannot be detected — keep encrypted values out of those yourself.
- **Searchable / Taggable / Filterable** — encrypted columns are **not** searchable: non-deterministic ciphertext (random IV) means the same plaintext never produces the same bytes, so `where(:ssn)`, `LIKE`, and prefix matching cannot work. For exact-match lookups, add a [blind index](#querying-encrypted-fields-blind-index) and query the `<field>_bidx` column (via `find_by_<field>` / `where_<field>`). Declaring an encrypted field in `searchable_by`, or as the `taggable_by` column, **raises** `ArgumentError` at declaration in either order — `search` / `tagged_with` used to return nothing silently. (A model that includes Taggable without `taggable_by` and encrypts its default `:tags` column is refused when `tagged_with` is called.)
- **Monetizable** — its `sum_` / `average_` / `minimum_` / `maximum_` aggregates run SQL over the cents column, which would be ciphertext (a `DecryptionError` on SQLite, `SUM(text)` rejected on PostgreSQL), so declaring an encrypted field with `monetizable` **raises** `ArgumentError` at declaration in either order. Keep money columns unencrypted.
- **Tokenizable** — `authenticate_by_<field>` / `consume_<field>` on an encrypted token look it up through its blind index (the decrypted value is still compared in constant time) and `consume_` clears the index with the token. Without a blind index they raise `ArgumentError` when called; generating, storing and rotating an encrypted token still works. Hashable's `unique:` precheck also goes through the blind index.

## Security notes

- **AES-256-GCM is authenticated.** A wrong key, a tampered ciphertext, or a corrupted envelope fails the auth tag and raises `DecryptionError` — it never returns garbage plaintext.
- **The header is authenticated too.** The version/algorithm/key-id bytes are fed to GCM as additional authenticated data (AAD), so they cannot be altered.
- **Non-deterministic by design.** Every write uses a fresh random IV, so identical plaintext yields different ciphertext — no equality leakage, but also no equality queries.
- **`update_column` / `update_columns` on an encrypted field still encrypt** — the value serializes through the attribute type — but they skip validations, callbacks, dirty tracking and the blind-index refresh, so the row's fingerprint goes stale and the value stops being findable until a normal save.
- **Keep the KDF salt stable.** It is part of the key's identity; rotating it orphans existing ciphertext.

## Notes & gotchas

- `nil` stays `nil` (the column is left NULL) — a blank value is never encrypted.
- **`type: :datetime` follows the model's time-zone settings, like a datetime column.** With `time_zone_aware_attributes` on (every Rails app), a zone-less String such as a `datetime-local` form value (`"2026-10-01T09:00"`) is wall-clock time in `Time.zone`, a `Date` is midnight in `Time.zone`, and the field reads back as an `ActiveSupport::TimeWithZone` in the current `Time.zone`. Without it, both follow `ActiveRecord.default_timezone` (UTC by default). A `datetime_select` (multiparameter) value is wall-clock time in `Time.zone` too. It is exactly the handling Rails gives an `attribute :name, :datetime` declaration, and `normalizes` on the field is inherited by subclasses. `skip_time_zone_conversion_for_attributes` is honored per field when it is set **before** the `encryptable` line. On Rails 6.0–7.1 it is honored wherever it is set, a subclass included, because Rails decides per class at schema load. From Rails 7.2, Rails decides for every declared attribute when it is declared, on the declaring class, so a skip list naming the field that is set later, or on a subclass, cannot reach it. Re-declaring the field after the skip list applies it; put the re-declaration directly after the skip list, since a macro that reads attribute types in between (`stateable_by`, `alias_association`) already triggers the check. Otherwise the model raises `ArgumentError` when ActiveRecord first builds its attributes (its first record, query or type lookup), instead of silently converting a field you opted out of. Name the field as a Symbol, as ActiveRecord reads the list. An infinite value (`Float::INFINITY`) is handed through uncast by Rails 7.0+'s time-zone conversion, as for a datetime column; the field cannot store it, so it is saved as `NULL` with no blind-index digest. Lookups (`find_by_<field>`) read a zone-less String the same way the class's assignments do. A stored plaintext without `Z` or an offset is read in `default_timezone`, never the server's zone. The plaintext is always UTC ISO8601 with microseconds, so rows written before this change read back as the same instant. Before, a zone-less String was parsed in the server's system zone (or UTC) and reads were plain UTC `Time`s. A frozen or non-UTC `Time` is stored correctly and never modified (it used to be converted in place, and a frozen one was saved as `NULL`).
- Dirty tracking works on the decrypted plaintext: reassigning the same value is **not** dirty, and an unchanged field is not re-encrypted on save, despite the random IV. An in-place edit of a decrypted String (`record.notes << "…"`, `gsub!`, `squish!`) **is** a change and is saved, as for a plain string column (it used to be lost silently). Detecting it decrypts the stored value of each read String field when Rails checks for changes — the approach of Rails' own `encrypts`.
- Decrypted text reads back as UTF-8, equal to the String that was written (plaintext bytes that are not valid UTF-8 stay binary). A stored empty String — a `text null: false, default: ""` column default — is never an envelope and reads back as `""` instead of raising `DecryptionError`.
- The envelope is versioned (`ver`/`alg`/`key_id`): `key_id` drives [key rotation](#key-rotation); `alg 0x11` (deterministic encryption) is still reserved, so it can be added later without a data migration.
- Reach for [`lockbox`](https://github.com/ankane/lockbox) or Rails 7.1+ native [`encrypts`](https://guides.rubyonrails.org/active_record_encryption.html) when you need deterministic search, KMS-backed or per-record keys, or Rails-managed key infrastructure.

## Upgrading: blind indexes of generated values

Before this fix, a blind-indexed value that a sibling generates in `before_create` — a [Tokenizable](tokenizable.md) token, a [Hashable](hashable.md) code, a [Sequenceable](sequenceable.md) number — was stored with a **NULL** fingerprint (the refresh ran in `before_save`, before the value existed). New rows are fingerprinted now, but rows created before the upgrade stay unfindable by `find_by_<field>` / `where_<field>` (and Tokenizable's `authenticate_by_<field>` / `consume_<field>`) until they are backfilled.

`reencrypt_all!` does **not** reach them: it only rewrites rows whose ciphertext is under an older key, and these are under the current one. Fingerprint exactly the affected rows instead — no callbacks, no re-encryption, any key (per-field `key:` included):

```ruby
User.unscoped.where(api_token_bidx: nil).where.not(api_token: nil).find_each do |user|
  user.update_columns(api_token_bidx: User.api_token_fingerprint(user.api_token))
end
```

Repeat per field (`<field>_bidx` / `<field>_fingerprint`, or your `column:`). `unscoped` includes rows a `default_scope` hides. Calling `reencrypt!` on every row (`User.unscoped.find_each(&:reencrypt!)`) works too for gem-keyed fields, but it rewrites every row's ciphertext; per-field `key:` fields are outside rotation and are skipped by it.

## Upgrading: slugs built from an encrypted field

Earlier releases let an encrypted field be a slug source (`sluggable_by :ssn`, a
`candidates:` entry, Sluggable's implicit `:name`, or a bare `friendly_id :ssn`
base). The slug column then stored that field's **plaintext**, and friendly_id
`history` kept every earlier plaintext slug in `friendly_id_slugs`. Such a model
now raises when it is declared or saved. To clean up existing rows:

1. Point the slug at a non-sensitive field (`sluggable_by :public_id`, or
   `friendly_id :public_id, use: :slugged`).
2. Regenerate every slug from it, then delete the history rows that still hold
   the old plaintext slugs:

```ruby
Customer.unscoped.find_each do |customer|        # unscoped: soft-deleted / hidden rows too
  customer.regenerate_slug!                      # Sluggable
  # customer.update!(slug: nil)                  # bare friendly_id: nil forces a new slug
end

current_slugs = Customer.unscoped.where.not(slug: nil).select(:slug)
FriendlyId::Slug.where(sluggable_type: "Customer")
                .where.not(slug: current_slugs)  # NOT IN: a NULL in the list would match nothing
                .delete_all
```

Old URLs built from the sensitive value stop resolving, which is the point. If
the slug column is also audited (Auditable), its trail holds the plaintext
slugs too — clear it with `clear_audit_trail!`.

## Changed in 1.22.0

- `where_<field>(nil)` / `find_by_<field>(nil)` return `none`/nil instead of matching every row without a fingerprint (`bidx IS NULL`).
- Encrypted field names register with Rails parameter filtering through a live registry consulted by a proc the gem's railtie appends at boot — redaction now works with boot-time filter snapshots (ActiveRecord `filter_attributes`, lograge-style initializers) and lazily-loaded model classes.
- PBKDF2-derived keys are memoized (bounded, mutex-guarded); previously every encrypt/decrypt/blind-index call re-ran the 65,536-iteration KDF.
- The encrypted×audited and encrypted×slug-source overlaps raise at macro time from both declaration orders.
