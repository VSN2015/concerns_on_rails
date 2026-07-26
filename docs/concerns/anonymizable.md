`Anonymizable` adds declarative right-to-erasure ("GDPR-lite") to ActiveRecord models: each personal-data field gets an erasure strategy, and `anonymize!` rewrites them all in a single `UPDATE` while stamping when the erasure happened. It completes the gem's sensitive-data suite — Maskable masks *display*, Sanitizable strips *HTML*, Encryptable protects *at rest*; Anonymizable **destroys**.

## When to use it

- **GDPR / CCPA erasure requests** — a user asks to be forgotten; their row must survive (foreign keys, financial records) but their identity must not.
- **Churned-tenant retention windows** — anonymize personal fields at churn, hard-delete after the retention period.
- **Production data in staging** — `User.anonymize_all!` turns a copied database into one you can hand to contractors.
- **Compliance evidence** — the `anonymized_at` stamp records exactly when erasure happened, and the `anonymized` / `not_anonymized` scopes drive the audit dashboard.

## Installation

```ruby
class User < ApplicationRecord
  include ConcernsOnRails::Models::Anonymizable

  anonymizable :email, with: :email                 # unique fake address
  anonymizable :first_name, :last_name, with: :redact
  anonymizable :ssn, with: :nullify
  anonymizable :bio, with: ->(value) { value && "removed by user request" }
end
```

The fully-qualified form `ConcernsOnRails::Models::Anonymizable` and the top-level alias `ConcernsOnRails::Anonymizable` are equivalent.

## Database columns

| Column | Type | Required | Notes |
|---|---|---|---|
| each anonymized field | any | Yes | Must exist; validated at macro time (`ArgumentError` otherwise) |
| `anonymized_at` (or custom `stamp:`) | `datetime` | Recommended | Powers `anonymized?`, the scopes, and `anonymize_all!` idempotency. Opt out with `stamp: false`. |

```ruby
class AddAnonymizedAtToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :anonymized_at, :datetime
    add_index  :users, :anonymized_at
  end
end
```

## Configuration

```ruby
anonymizable(*fields, with:, stamp: :anonymized_at, clear_audit_trail: true, prefix: nil, suffix: nil)
```

The macro is repeatable — field rules merge across calls. `stamp:` and `clear_audit_trail:` apply only when explicitly passed (the last explicit value wins), so later calls can't silently reset earlier choices.

| Option | Type | Default | Description |
|---|---|---|---|
| `*fields` | one or more Symbols (required) | — | The columns to erase. |
| `with:` | Symbol preset or callable (required) | — | The erasure strategy for these fields (see below). |
| `stamp:` | Symbol or `false` | `:anonymized_at` | The datetime column stamped by `anonymize!`. `false` disables stamping (and the scopes). |
| `clear_audit_trail:` | Boolean | `true` | When the model is also `Auditable` and any anonymized field is tracked, clear the audit column in the same UPDATE (the trail holds historical plaintext). |
| `prefix:` / `suffix:` | Symbol/String | `nil` | Affix the scope names (e.g. `prefix: :privacy` → `privacy_anonymized`). Taken from the first defining call. |

### Strategy presets

| Preset | Result | Notes |
|---|---|---|
| `:nullify` | `nil` | Simplest erasure; watch NOT NULL constraints. |
| `:redact` | `"[REDACTED]"` | Presence validations survive. |
| `:hash` | SHA-256 hex of the value | Deterministic **pseudonymization** — equal inputs digest equal, so joins keep working. Not full anonymization. |
| `:email` | `"anon-<hex>@anonymized.invalid"` | Random per record, so NOT NULL + unique-index email columns survive; `.invalid` is an RFC 2606 reserved TLD. |
| `:random_hex` | 32 random hex chars | Unique replacement tokens/usernames. |
| callable | your return value | `->(value)` or `->(value, record)`. Presets pass `nil` through untouched; callables choose their own nil handling. |

## How it writes

`anonymize!` runs `before_anonymize`, a **single `update_columns` UPDATE**, and `after_anonymize`, all in one transaction — then reloads the record.

- **No validations** — erasure must not be blocked by a presence/format validation.
- **No callbacks** — a `before_save` hook must never see (or copy) the old values; Auditable's capture hook is the canonical example.
- **Types still apply** — `update_columns` serializes each value through the model's attribute types, so a field that is also `encryptable` stores a fresh ciphertext envelope of the anonymized value, never plaintext.

## Scopes

| Scope | Description |
|---|---|
| `.anonymized` | Records whose stamp column is set. |
| `.not_anonymized` | Records whose stamp column is `NULL`. |

Not defined when `stamp: false`. Names honor `prefix:`/`suffix:`.

## Methods

| Signature | Description |
|---|---|
| `anonymize!` | Erases all configured fields + stamps, in one transaction (single UPDATE). Raises `ArgumentError` on a new record. Returns `true`. Terminal: unsaved changes are discarded by the post-write reload. |
| `anonymized?` | `true` when the stamp column is present; always `false` with `stamp: false`. |
| `before_anonymize` / `after_anonymize` | Hook methods (no-op defaults) run inside the transaction — a raising hook rolls the erasure back. |
| `.anonymize_all!` | Anonymizes every matching record that isn't already stamped, in one transaction. Returns the Integer count of newly anonymized records. |

## Examples

**Erasure request handler:**

```ruby
class ErasureRequestsController < ApplicationController
  def create
    current_user.anonymize!
    sign_out current_user
    head :no_content
  end
end
```

**Compliance sweep for churned tenants:**

```ruby
User.where(account_id: churned_account_ids).anonymize_all!
# => 42 (already-stamped records are skipped)
```

**Composed with Encryptable and Auditable:**

```ruby
class Patient < ApplicationRecord
  include ConcernsOnRails::Models::Encryptable
  include ConcernsOnRails::Models::Auditable
  include ConcernsOnRails::Models::Anonymizable

  encryptable :ssn                          # ciphertext at rest
  auditable_by :legal_name, into: :audit_log
  anonymizable :ssn, :legal_name, with: :nullify
end

patient.anonymize!
# ssn and legal_name are NULL, and because legal_name is audited, the
# audit_log column (which held its plaintext history) was cleared in the
# same UPDATE.
```

## Notes & gotchas

- **`:hash` is pseudonymization, not anonymization.** The digest is stable, so anyone holding the original value can re-identify the row. Use it when cross-dataset joins must survive; use `:random_hex`/`:nullify` for true erasure.
- **The audit trail is cleared all-or-nothing.** Auditable stores every field's history in one column; when any anonymized field is tracked, the whole column is nil'ed (unless `clear_audit_trail: false`).
- **Erasure is terminal for the instance.** `anonymize!` ends with `reload`, discarding unsaved changes and refreshing every attribute.
- **Skipped callbacks cut both ways.** Cache-key touches, counter caches, and search-index sync hooks do not run — trigger those manually from `after_anonymize` if you need them.
- **Backups and logs are out of scope.** Anonymizing the row does not rewrite database backups, replicas, or historical log lines; pair with your retention policies.
