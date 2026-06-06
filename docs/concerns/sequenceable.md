`Sequenceable` generates ordered, human-friendly sequential reference numbers — invoice numbers, order numbers, ticket IDs, support cases — and persists them into an integer column that acts as the source of truth. Unlike `Hashable` and `Tokenizable`, which produce random identifiers, `Sequenceable` produces dense, ascending values computed as `MAX(field) + 1` within an optional scope and optional time period. An optional string column stores the formatted representation (e.g. `"INV-2026-00001"`) so display strings remain stable after the record is created.

## When to use it

- Generating sequential invoice or purchase-order numbers (e.g. `INV-00042`) that accounting teams can reference without gaps.
- Issuing per-tenant ticket IDs where each customer account has its own independent counter starting at 1.
- Producing annual or monthly reference codes (e.g. `ORD-202606-0017`) that reset at the start of each billing period.
- Assigning sequential case numbers in a support system where agents need predictable, ordered identifiers.
- Any context where a monotonically increasing, human-readable identifier is required and randomness would be confusing or unacceptable.

## Installation

```ruby
class Invoice < ApplicationRecord
  include ConcernsOnRails::Sequenceable

  sequenceable_by :sequence,      # integer column — source of truth
    into:      :number,           # string column for the formatted display value
    prefix:    "INV-",
    padding:   5,
    scope:     :account_id,       # independent counter per account
    reset:     :year              # restart each calendar year
end
```

The alias `ConcernsOnRails::Models::Sequenceable` is also valid; the two forms are identical.

## Database columns

`Sequenceable` reads and writes database columns directly. The required and optional columns are listed below.

| Column | Type | Required | Notes |
|---|---|---|---|
| `field` (e.g. `sequence`) | `integer` | Yes | Positional argument to `sequenceable_by`. The source of truth for ordering. |
| `into:` (e.g. `number`) | `string` | No | Persists the formatted representation. Must be a string column — integer columns drop leading zeros. |
| `scope:` column(s) | any | No | One or more columns that partition the counter (e.g. `account_id`). |
| `created_at` | `datetime` | Only when `reset:` is not `:never` | Used to derive the period token and scope the `MAX` query to the current period. |

```ruby
class CreateInvoices < ActiveRecord::Migration[7.1]
  def change
    create_table :invoices do |t|
      t.integer :sequence,   null: false
      t.string  :number                    # optional: formatted display value
      t.integer :account_id, null: false   # optional: scope column
      t.timestamps                         # required when reset: is used
    end

    # Recommended: enforce uniqueness at the DB level for concurrent safety.
    add_index :invoices, [:account_id, :sequence], unique: true
    add_index :invoices, [:account_id, :number],   unique: true
  end
end
```

## Configuration

`sequenceable_by` is the configuration macro. It may be called once per model (or multiple times with different `field` names). All options except the positional `field` argument are keyword arguments.

| Option | Type | Default | Description |
|---|---|---|---|
| `field` (positional) | Symbol | `:sequence` | The integer column that holds the raw sequence number and serves as the source of truth. |
| `into:` | Symbol / nil | `nil` | An optional string column where the formatted display value is persisted on create. When `nil`, the formatted value is computed on the fly by `formatted_<field>`. |
| `prefix:` | String | `""` | String prepended to the formatted value (e.g. `"INV-"`). |
| `padding:` | Integer | `0` | Zero-pad width for the numeric portion. `0` means no padding. `5` renders `1` as `"00001"`. |
| `separator:` | String | `"-"` | Joins the prefix, period token, and padded number in the default formatter. Has no effect when `template:` is set. |
| `start_at:` | Integer | `1` | The first value assigned when the scope/period has no rows yet. |
| `scope:` | Symbol / Array of Symbols / nil | `nil` | Column or array of columns that partition the counter. Each distinct combination of scope-column values maintains its own independent counter. |
| `reset:` | Symbol | `:never` | Restarts the counter at `start_at` each calendar period. Valid values: `:never`, `:year`, `:month`, `:day`. Any value other than `:never` requires a `created_at` column. |
| `template:` | Callable / nil | `nil` | A callable (e.g. a lambda) with signature `->(seq, record)` that returns the formatted string. When set, it completely overrides `prefix`, `padding`, `separator`, and the period token. Must respond to `#call`. |

### Default format by `reset:` value

| `reset:` | Example output | Format shape |
|---|---|---|
| `:never` | `INV-00001` | `prefix + padded` |
| `:year` | `INV-2026-00001` | `prefix + YYYY + separator + padded` |
| `:month` | `INV-202606-00001` | `prefix + YYYYMM + separator + padded` |
| `:day` | `INV-20260604-00001` | `prefix + YYYYMMDD + separator + padded` |

## Scopes

`Sequenceable` does not add any ActiveRecord query scopes to the model.

## Methods

### Instance methods

**`formatted_<field>`**

Returns the formatted display string for the configured field. When an `into:` column is configured and its value is present (i.e. already persisted), the stored value is returned directly. Otherwise the value is computed on the fly from the raw integer using the configured prefix, padding, separator, period, and template. Returns `nil` when the raw integer column is blank.

**`assign_sequenceable_value(field)`** *(called automatically via `before_create`)*

Computes and assigns the next sequence value and, when `into:` is configured, the formatted string. Skips assignment if the integer column already has a value (caller-supplied values are respected). If the computed candidate is already taken, the value is incremented until a free slot is found, up to `MAX_GENERATION_ATTEMPTS` (10) retries.

### Class methods

**`next_<field>(scope_attrs = {})`**

Returns the integer that would be assigned to the next record for the given scope, without creating a record. `scope_attrs` is a hash whose keys correspond to the configured `scope:` columns (e.g. `Invoice.next_sequence(account_id: 1)`). When no scope is configured, call with no arguments.

## Examples

**Basic invoice numbering with padding and a formatted display column:**

```ruby
class Invoice < ApplicationRecord
  include ConcernsOnRails::Sequenceable

  sequenceable_by :sequence, into: :number, prefix: "INV-", padding: 5
end

a = Invoice.create!
b = Invoice.create!

a.sequence          # => 1
a.number            # => "INV-00001"
a.formatted_sequence # => "INV-00001"

b.sequence          # => 2
b.number            # => "INV-00002"

Invoice.next_sequence # => 3
```

**Per-tenant counter with annual reset:**

```ruby
class Invoice < ApplicationRecord
  include ConcernsOnRails::Sequenceable

  sequenceable_by :sequence,
    into:    :number,
    prefix:  "INV-",
    padding: 4,
    scope:   :account_id,
    reset:   :year
end

# Account 1 in 2026
Invoice.create!(account_id: 1).number  # => "INV-2026-0001"
Invoice.create!(account_id: 1).number  # => "INV-2026-0002"

# Account 2 gets its own counter
Invoice.create!(account_id: 2).number  # => "INV-2026-0001"

# Peek next value without creating
Invoice.next_sequence(account_id: 1)   # => 3

# In 2027, the counter restarts for account 1
# (record created in 2027)
Invoice.create!(account_id: 1).number  # => "INV-2027-0001"
```

**Custom template overriding all built-in formatting:**

```ruby
class Ticket < ApplicationRecord
  include ConcernsOnRails::Sequenceable

  sequenceable_by :sequence,
    into:     :reference,
    start_at: 1000,
    template: ->(seq, record) { "TKT-#{record.department_code}-#{seq}" }
end

Ticket.create!(department_code: "ENG").reference  # => "TKT-ENG-1000"
Ticket.create!(department_code: "OPS").reference  # => "TKT-OPS-1001"
```

## Notes & gotchas

**Concurrency is best-effort.** The next value is determined by `MAX(field) + 1` within the scope/period. Two concurrent inserts can read the same `MAX` and both attempt to use the same value. The concern includes an increment-and-retry loop (up to 10 attempts, `MAX_GENERATION_ATTEMPTS`) that can resolve post-insert races, but the only reliable guarantee is a **scoped unique index** on the sequence column (and on the `into:` column, if used).

**Caller-supplied values are not overwritten.** Passing an explicit integer (e.g. `Invoice.create!(sequence: 99)`) bypasses auto-assignment entirely. The `into:` column is still populated from the supplied integer, so the formatted string is always consistent.

**`into:` requires a string column.** Integer columns in most databases strip leading zeros, so `"00001"` would be stored as `1`. Always use a `string`/`varchar` column for `into:`.

**`reset:` requires `created_at`.** Any value of `reset:` other than `:never` causes `sequenceable_by` to verify that the `created_at` column exists. If it does not, an `ArgumentError` is raised at class-load time. The period is derived from each row's own `created_at`, not from the current time at query time, so historical records land in the correct period bucket.

**`template:` completely overrides built-in formatting.** When `template:` is set, `prefix`, `padding`, `separator`, and the period token are all ignored. The lambda receives `(seq, record)` where `seq` is the raw integer and `record` is the model instance.

**`start_at:` applies per scope+period bucket.** When `scope:` and `reset:` are both configured, each combination of scope values *and* period starts fresh at `start_at` independently.

**Sequence queries bypass `default_scope`.** The `MAX` and existence-check queries run through `unscoped`, so soft-deleted records (or any other default-scoped-out rows) are still counted when computing the next value. This prevents gaps from soft-deleted records causing the counter to reuse numbers.

**Column validation runs at class load time.** `sequenceable_by` calls `ensure_columns!` for `field`, `into:`, all `scope:` columns, and `created_at` (when `reset:` is not `:never`). A missing column raises `ArgumentError` with the message `"does not exist in the database"` before any records are created.

**Valid `reset:` values are strictly enforced.** Passing an unrecognized symbol (e.g. `reset: :decade`) raises `ArgumentError` with the message `"unknown reset"`. Valid values are `:never`, `:year`, `:month`, and `:day`.

**`template:` must be callable.** Passing a non-callable value (e.g. a plain string) raises `ArgumentError` with the message `"template must be callable (respond to #call)"` at class-load time.

**`formatted_<field>` returns `nil` for unsaved or sequence-less records.** When the raw integer column is blank (e.g. on an unsaved record that has not gone through `before_create`), `formatted_<field>` returns `nil` rather than an empty string.
