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

`sequenceable_by` is the configuration macro. Call it once per `field`; several fields may each have their own call. All options except the positional `field` argument are keyword arguments.

**Re-declaring a field.** A later `sequenceable_by` for the same field, on the same class or on an STI subclass, follows one of two rules:

- A call that passes **`assign:` and/or `time_zone:` and nothing else** keeps every other option at its current (inherited or earlier) value. So `sequenceable_by :sequence, assign: :manual` on a `Draft` subclass keeps the parent's `into:`, `prefix:`, `reset:` and `template:`. `time_zone: nil` resets the zone to the app default.
- Any other call restates the format: one that passes a format option (`prefix:`, `template:`, `padding:`, `reset:`, `scope:`, `into:`, `separator:`, `start_at:`), and a bare `sequenceable_by :sequence` with no options at all. Every option it omits takes its default, exactly as in a first declaration. A subclass that changes only the prefix must repeat `into:`, `reset:`, `padding:` and the rest if it wants them.

A partial format is never merged onto an inherited one, because the result would be a format nobody wrote down: a `prefix:` under an inherited `template:` (which ignores the prefix), or a subclass that adds only `scope:` but keeps rendering the parent's `INV-` numbers from a counter of its own.

**Declare the owner fully, including `time_zone:`, before its subclasses.** A subclass that calls `sequenceable_by` (for any field, `assign:`-only included) takes a copy of the configuration at that moment. A later re-declaration of the parent (a reopened class, a `to_prepare` block, an engine override) is not propagated to that subclass and is not re-checked against it: the subclass keeps the old options and the old zone, and the zone check never compares the two again.

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
| `time_zone:` | String / Symbol / `ActiveSupport::TimeZone` / nil | `nil` (app zone) | The zone `reset:` periods are cut in — for the `MAX` range and the period token alike. `nil` resolves at use time to the app's configured zone (`config.time_zone`, i.e. `Time.zone_default`), falling back to UTC. Never the per-request `Time.zone`. An unknown zone name raises `ArgumentError` at class-load time. Has no effect with `reset: :never`. |
| `template:` | Callable / nil | `nil` | A callable (e.g. a lambda) with signature `->(seq, record)` that returns the formatted string. When set, it completely overrides `prefix`, `padding`, `separator`, and the period token. Must respond to `#call`. |
| `assign:` | Symbol | `:create` | When the number is assigned. `:create` numbers the field in the concern's `before_create` callback (the default). `:manual` skips it — the column stays `NULL` until `assign_<field>!` is called, so a draft can exist without consuming a number and numbering follows finalization order. Any other value raises `ArgumentError`. |

### Default format by `reset:` value

| `reset:` | Example output | Format shape |
|---|---|---|
| `:never` | `INV-00001` | `prefix + padded` |
| `:year` | `INV-2026-00001` | `prefix + YYYY + separator + padded` |
| `:month` | `INV-202606-00001` | `prefix + YYYYMM + separator + padded` |
| `:day` | `INV-20260604-00001` | `prefix + YYYYMMDD + separator + padded` |

## Scopes

`Sequenceable` adds one scope per declared field, `pending_<field>`: the rows still awaiting a number (`WHERE <field> IS NULL`). It is described with the class methods below.

## Methods

### Instance methods

**`formatted_<field>`**

Returns the formatted display string for the configured field. When an `into:` column is configured and its value is present (i.e. already persisted), the stored value is returned directly. Otherwise the value is computed on the fly from the raw integer using the configured prefix, padding, separator, period, and template. Returns `nil` when the raw integer column is blank.

**Numbering on create** *(automatic, via one `before_create` per field)*

The concern registers one `before_create` per field, at the field's **first** `assign: :create` declaration in the class chain, and subclasses inherit it. Its position among your callbacks is that first declaration's position. A field whose first `:create` declaration is on a subclass, after the subclass's own `before_create`, is numbered after that callback. A field the subclass inherits as `:create` keeps the parent's position, even when the subclass re-declares it after its own `before_create`: that callback runs after the number is drawn, so it cannot set a `scope:` column for it. At create, the callback checks the receiving class's **current** declaration of the field and, when it is `assign: :create`, computes the next value and, when `into:` is configured, the formatted string. Assignment is skipped when the integer column already has a value (caller-supplied values are respected). Re-declaring a field never adds a second callback. The columns it wrote (the integer, the `into:` string, a pinned `created_at`) are then reported to the siblings that already ran (`Support::GeneratedValues`), whatever the include or declaration order: a [Sluggable](sluggable.md) slug sourced from the number is built (`sluggable_by :number` → `"inv-1"` on the first save, not `nil` until a later save backfills it), an [Auditable](auditable.md) creation entry includes a tracked `number`, and an [Encryptable](encryptable.md) blind index on it is fingerprinted.

Because the callback reads the configuration at run time, re-declaring a field changes its mode: `sequenceable_by :sequence, assign: :manual` on an STI subclass (or later on the same class) stops that class numbering at create, while the parent and any subclass that does not re-declare keep numbering. The last declaration wins.

**`assign_<field>!`**

Numbers the record now: computes the next value for its scope (and period), writes the integer and the `into:` string, and — when the record is persisted — `save!`s. On a new record the attributes are set and left for your own save. Returns `true` when a number was assigned and `false` when the record already had one (nothing is rewritten), so a "finalize" action can be retried safely. Available in both modes; it is the only way to number a record under `assign: :manual`.

The `save!` runs in its own savepoint, and when it fails — `ActiveRecord::RecordNotUnique` from a concurrent writer that took the same number, a failed validation — the integer and `into:` columns are put back before the error propagates. So `ConcernsOnRails::Support::UniqueRetry.with_retries { invoice.assign_sequence! }` retries with a freshly drawn number instead of finding the record "already numbered", and a failure inside your own transaction does not abort it on PostgreSQL.

**`sequenceable_period_time(field)`**

The instant that anchors this record's `reset:` period, expressed in the field's fixed zone. It is the same value the `MAX` range and the default period token use. Read it from a `template:` that renders a date: `created_at` comes back in the *request's* zone under time-zone-aware attributes, so a template built on it can print a period the counter did not use.

```ruby
sequenceable_by :sequence, into: :number, reset: :year,
  template: ->(seq, record) { "#{record.sequenceable_period_time(:sequence).year}/#{seq}" }
```

**`<field>_assigned?`**

`true` when the integer column has a value.

### Class methods

**`pending_<field>`**

Scope: records still awaiting a number (`WHERE <field> IS NULL`) — the drafts, under `assign: :manual`.

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

**Number when finalized, not when drafted**

```ruby
class Invoice < ApplicationRecord
  include ConcernsOnRails::Sequenceable

  sequenceable_by :sequence, into: :number, prefix: "INV-", padding: 5, scope: :account_id, assign: :manual

  def finalize!
    transaction do
      assign_sequence!          # => true the first time, false on a retry
      update!(state: "final")
    end
  end
end

draft = Invoice.create!(account_id: 1)   # sequence: nil, number: nil
Invoice.pending_sequence                 # => [draft]
draft.finalize!
draft.number                             # => "INV-00001"
```

**A draft STI subclass of a numbered parent**

Re-declare with **only** `assign:`. The subclass keeps every other option, including the parent's `template:` object, so it shares the parent's counter and finalizes into the same series:

```ruby
class Invoice < ApplicationRecord
  include ConcernsOnRails::Sequenceable

  sequenceable_by :sequence, into: :number, template: ->(seq, _r) { "INV/#{seq}" }
end

class DraftInvoice < Invoice
  sequenceable_by :sequence, assign: :manual   # right: same config, same counter
end
```

Do not repeat the parent's options. Repeating any format option restates the whole format, and a `template:` written again is a **new lambda**. Procs compare by identity, so `template: ->(seq, _r) { "INV/#{seq}" }` in the subclass does not match the parent's, and the subclass gets a separate series. That series renders the same strings from a counter of its own, so it reissues `INV/1`.

## Notes & gotchas

**Concurrency is best-effort.** The next value is `MAX(field) + 1` within the scope/period, read in one `SELECT` just before the `INSERT`. The concern has no retry loop of its own. Two concurrent creates can read the same `MAX` and both try to use the same value. The only reliable guarantee is a **scoped unique index** on the sequence column (and on the `into:` column, if used). With the index in place, the losing write raises `ActiveRecord::RecordNotUnique`, and `ConcernsOnRails::Support::UniqueRetry.with_retries` turns that into a fresh attempt:

```ruby
# Retries the whole create (3 attempts by default); each attempt draws a new MAX.
UniqueRetry.with_retries { Invoice.create!(attrs) }

# Inside your own transaction, give each attempt a savepoint so a rejected
# INSERT does not abort the transaction on PostgreSQL:
Invoice.transaction do
  UniqueRetry.with_retries(savepoint: Invoice) { Invoice.create!(attrs) }
end

# assign_<field>! already saves in its own savepoint and puts the number back
# on failure, so it can be retried directly:
UniqueRetry.with_retries { invoice.assign_sequence! }
```

The block must draw a fresh value on every attempt; re-saving a record whose number is already set just fails `limit` times. `RecordNotUnique` does not say which index was violated, so a clash on an unrelated unique index also triggers a retry. Those retries are wasted, but bounded by `limit:`.

**Caller-supplied values are not overwritten.** Passing an explicit integer (e.g. `Invoice.create!(sequence: 99)`) bypasses auto-assignment entirely. The `into:` column is still populated from the supplied integer, so the formatted string is always consistent.

**`into:` requires a string column.** Integer columns in most databases strip leading zeros, so `"00001"` would be stored as `1`. Always use a `string`/`varchar` column for `into:`.

**`reset:` requires `created_at`.** Any value of `reset:` other than `:never` causes `sequenceable_by` to verify that the `created_at` column exists. If it does not, an `ArgumentError` is raised at class-load time. The period is derived from each row's own `created_at`, not from the current time at query time, so historical records land in the correct period bucket.

**Periods are cut in a fixed zone, not the request's.** With `reset:`, the `MAX` range and the period token are computed from `created_at` in the field's `time_zone:` (default: `config.time_zone`, else UTC). The per-request `Time.zone` set by `Timezoneable` or `Time.use_zone` plays no part. If it did, a Tokyo request and a New York request would disagree on which day it is, read `MAX` over different ranges and issue the same number, and `formatted_<field>` without `into:` would render a different date depending on the reader's zone.

```ruby
sequenceable_by :sequence, into: :number, reset: :day, time_zone: "Asia/Tokyo"
# 2026-09-24 16:00 UTC is 2026-09-25 in Tokyo, whoever makes the request:
Invoice.create!.number   # => "20260925-0001"
```

Apps that never change `Time.zone` per request see no change, because the default is the zone they already run in. Apps that did change it per request may hold rows numbered under a request zone that now fall outside the matching fixed-zone period. With `into:` (and no `template:`) this is handled: the `MAX` also counts rows whose **stored** `into:` value starts with this period's `prefix + token + separator` (a LIKE with the prefix escaped), so the first fixed-zone number of that period continues after them. The cost is at most a gap, never a reissue. Without `into:` there is no stored token to read, so add a unique index before upgrading.

**`template:` completely overrides built-in formatting.** When `template:` is set, `prefix`, `padding`, `separator`, and the period token are all ignored. The lambda receives `(seq, record)` where `seq` is the raw integer and `record` is the model instance.

**`start_at:` applies per scope+period bucket.** When `scope:` and `reset:` are both configured, each combination of scope values *and* period starts fresh at `start_at` independently.

**Sequence queries bypass `default_scope`.** The `MAX` and existence-check queries run through `unscoped`, so soft-deleted records (or any other default-scoped-out rows) are still counted when computing the next value. This prevents gaps from soft-deleted records causing the counter to reuse numbers.

**With STI, the declaring class owns the counter.** The `MAX` is read over the class that called `sequenceable_by` (and its descendants):

- Declared on the STI **base** — every subclass draws from one table-wide counter, so `Credit` and `Debit` rows sharing a unique `sequence` column never collide.
- Declared on **each subclass** (`Invoice` with `prefix: "INV-"`, `CreditNote` with `prefix: "CN-"`) — each keeps its own gap-free sequence, INV-0001, INV-0002, CN-0001.
- A subclass that merely inherits a parent's declaration shares the parent's counter.
- A subclass that **re-declares** `sequenceable_by` with a format tuple no ancestor uses numbers its own series (with its descendants). The tuple is the full `prefix`, `template`, `padding`, `reset`, `scope`, `into`, `separator` and `start_at`, after the re-declaration rules above. The parent's `MAX` still spans every row of the table, so the parent series may show a **gap** after those rows — never a duplicate, even when a subclass starts declaring its own sequence after a deploy.
- **Rule: an identical format tuple shares the owner's counter.** A re-declaration whose tuple is identical to an inherited owner's keeps that owner's counter. The check walks up the chain (parent, then *its* inherited owner, …). So a `Draft < Invoice` with `sequenceable_by :sequence, assign: :manual` finalizes into the same `INV-` series without reissuing a number, and so does a subclass that went `CN-` and back to `INV-`. `assign:` and `time_zone:` are not part of the tuple.
- **The comparison is exact, not visual.** A tuple that differs only in `scope:`, `start_at:` or `into:`, or one that repeats a `template:` as a new lambda (Procs compare by identity), is a separate series even though it renders the same strings, so it **can reissue the parent's numbers**. Give such a series a distinct prefix, or use `scope: :type`. Sibling subclasses that each declare the same format with no declaring ancestor in common are not detected either.
- **One zone per shared counter.** A class that shares an owner's counter (with `reset:` enabled) must cut the same periods: both `time_zone:` omitted, or both explicit and the same zone. Aliases count as the same zone (`"Kolkata"` and `"Asia/Calcutta"`). Anything else raises `ArgumentError` at class-load time, because the two classes would cut the same "20260926" day at different instants over one counter and both could issue `20260926-1`. That includes an explicit zone against an omitted one that equals `config.time_zone` today: the omitted zone is resolved at use time, and `config.time_zone` may be applied after the model loads. A different zone with a different format is fine, because it is a separate series, and so are classes numbering over different tables under an abstract declarer.
- **Known limit: don't mix zones among classes that share a table.** The zone check compares a class with the owner the format walk finds. Take an STI base that re-declares a different format under an abstract declarer, with two leaves that restate the abstract declarer's format in different zones. Both leaves resolve to the abstract owner, which has no table of its own, so the check is skipped. Yet both number over the STI base's table with one `MAX`, cut days in different zones, and can issue the same `20260925-1`. Declare `time_zone:` on the class that first declares a format, and nowhere else.
- Declared on an **abstract** class, each concrete table (and its STI subtree) keeps its own counter.
- `scope: :type` on the base partitions one declaration per type.

For **independent per-type series without gaps**, declare once on the base with `scope: :type`.

**Index per type.** Per-subclass series (declared on each subclass, or re-declared with a different format) share one integer column, so their numbers overlap across types. Index `(type, <field>)` — or the scope columns plus the field — not the field alone.

**Upgrading from 1.29.0 or earlier:** a per-type series that used to number per subclass while *inheriting* a base declaration now shares the table-wide counter. Its next number jumps once to the table-wide MAX + 1, leaving a one-time gap. Declare `scope: :type` to keep per-type numbering.

**Upgrading from 1.30.0 or earlier:** a re-declaration that passes only `assign:` and/or `time_zone:` used to reset every other option to its default; it now keeps them. A subclass declared that way used to number its own series in the default format; it now uses the parent's format and counter. Rows it numbered before the upgrade have no `into:` value, so `formatted_<field>` renders them in the parent's format. Backfill their `into:` column first, or restate the subclass's old format explicitly. Re-declarations that pass any format option, and bare ones with no options, still start from the defaults, as before. The one change for them: a tuple identical to an inherited owner's now shares that owner's counter instead of numbering a subclass-only series that could reissue the owner's numbers.

`next_<field>` previews exactly what the receiving class's next `create!` gets in every one of these setups — under `scope: :type`, an omitted `type:` resolves to the receiver's own STI name (NULL for the base).

**Column validation runs at class load time.** `sequenceable_by` calls `ensure_columns!` for `field`, `into:`, all `scope:` columns, and `created_at` (when `reset:` is not `:never`). A missing column raises `ArgumentError` with the message `"does not exist in the database"` before any records are created.

**Valid `reset:` values are strictly enforced.** Passing an unrecognized symbol (e.g. `reset: :decade`) raises `ArgumentError` with the message `"unknown reset"`. Valid values are `:never`, `:year`, `:month`, and `:day`.

**`template:` must be callable.** Passing a non-callable value (e.g. a plain string) raises `ArgumentError` with the message `"template must be callable (respond to #call)"` at class-load time.

**`formatted_<field>` returns `nil` for unsaved or sequence-less records.** When the raw integer column is blank (e.g. on an unsaved record that has not gone through `before_create`), `formatted_<field>` returns `nil` rather than an empty string.

## Changed in 1.22.0

- With `reset:` enabled, `created_at` is pinned to the period-anchor instant during `before_create`, so a row can no longer be numbered for one period but timestamped into the next across a year/month/day boundary.
