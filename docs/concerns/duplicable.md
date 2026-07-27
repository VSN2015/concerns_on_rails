`Duplicable` adds a concern-aware deep copy to ActiveRecord models — the "clone this invoice / duplicate this template" feature. A bare `record.dup` copies identity-bearing columns (the slug, the API token, the invoice number, the audit trail, even `created_at`, which ActiveRecord preserves on save when present), so naive copies collide with unique indexes or lie about their history. Duplicable knows its sibling concerns, blanks exactly those columns, and lets each concern regenerate fresh values when the copy saves.

## When to use it

- **"Duplicate" buttons** — invoices, quotes, campaigns, survey templates, CMS pages.
- **Templates** — keep a library of template records and stamp out working copies with fresh identities.
- **Re-issuing documents** — copy last quarter's invoice with its line items, reset the number and dates, adjust, send.
- **Nested graphs** — an order with line items, or a survey with questions with options: each level declares its own copy rules.

## Installation

```ruby
class Invoice < ApplicationRecord
  include ConcernsOnRails::Models::Duplicable
  include ConcernsOnRails::Models::Sequenceable

  has_many :line_items
  sequenceable_by :sequence, into: :number, prefix: "INV-"

  duplicable_by associations: %i[line_items],
                reset: %i[issued_at],
                suffix: { title: " (copy)" }
end

copy = invoice.duplicate                # unsaved deep copy
copy = invoice.duplicate!(title: "Q3")  # saved, with overrides
```

The macro is optional — a bare `include` already gives you `duplicate`/`duplicate!` with the automatic identity resets. The top-level alias `ConcernsOnRails::Duplicable` is equivalent.

## Configuration

```ruby
duplicable_by(associations: [], reset: [], suffix: {})
```

| Option | Type | Default | Description |
|---|---|---|---|
| `associations:` | Array of Symbols | `[]` | Allow-list of associations to copy. Must be declared **before** the macro; validated at macro time. `has_many`/`has_one` children are deep-copied; `has_and_belongs_to_many` links the copy to the *same* records; `belongs_to` and `has_many :through` are rejected with an explanation. |
| `reset:` | Array of Symbols | `[]` | Columns blanked on the copy (business state: `published_at`, `approved_at`, …). Validated against the schema. |
| `suffix:` | Hash `{ field => text }` | `{}` | Appended to the copy's value when present (`title: " (copy)"`). Validated against the schema. |

### Automatic identity resets

These are blanked on every copy, no configuration needed — identity, not business state:

| Column | Why |
|---|---|
| `created_at` / `updated_at` | AR preserves a present `created_at` on save; a copy is new. |
| Sluggable slug | Regenerated (uniquely) from the source field on save. |
| Tokenizable / Hashable columns | Regenerated on create. |
| Sequenceable sequence + `into:` columns | Next number on create. |
| Auditable trail column | A copy inherits no history (its own creation is then audited normally). |
| SoftDeletable timestamp | A copy of trash is a live record. |
| Lockable `attempts` (→ 0) / `locked_at` (→ nil) | A copy starts unlocked. |

Business state (Publishable, Stateable, Activatable, Expirable, …) is a judgment call and is **not** auto-reset — list those columns in `reset:`.

## Methods

| Signature | Description |
|---|---|
| `duplicate(overrides = {})` | Returns an **unsaved** deep copy: `dup` + identity resets + `reset:` + `suffix:` + `overrides` (assigned through writers) + copied associations + the `on_duplicate` hook. |
| `duplicate!(overrides = {})` | `duplicate` then `save!` in one transaction — the copy and its copied children persist together via autosave. Returns the saved copy. |
| `on_duplicate(copy)` | Override point (no-op default) — receives the unsaved copy as the last step of `duplicate`. |

## Examples

**Nested graphs — each level declares its own rules:**

```ruby
class LineItem < ApplicationRecord
  include ConcernsOnRails::Models::Duplicable

  belongs_to :invoice
  duplicable_by reset: %i[fulfillment_batch_id]
end

class Invoice < ApplicationRecord
  include ConcernsOnRails::Models::Duplicable

  has_many :line_items
  duplicable_by associations: %i[line_items]
end

copy = invoice.duplicate!
copy.line_items.first.fulfillment_batch_id  # => nil (LineItem's own reset rule)
```

A child whose class includes Duplicable is copied via **its own** `duplicate` — its resets, its suffixes, its nested associations — so recursive graphs stay declarative.

**Templates with a hook:**

```ruby
class SurveyTemplate < ApplicationRecord
  include ConcernsOnRails::Models::Duplicable

  has_many :questions
  duplicable_by associations: %i[questions], suffix: { name: " (draft)" }

  def on_duplicate(copy)
    copy.status = "draft"
  end
end
```

## Notes & gotchas

- **Declare associations before the macro** (the CounterCacheable convention) — `duplicable_by` validates each name against `reflect_on_association` and raises at class-load time, not at request time.
- **`belongs_to` is deliberately rejected.** The copy keeps the foreign key from `dup`, so it *shares* its parents; copying a parent from the child side is almost always an accident.
- **`has_many :through` is deliberately rejected.** Duplicate the direct association — the through rows follow from it.
- **HABTM shares, it does not copy.** The join rows are recreated for the copy; the associated records themselves are not duplicated.
- **Uniqueness beyond the known concerns is yours.** A unique column the gem doesn't own (e.g. an external reference you manage by hand) belongs in `reset:` or `overrides`.
- **Copies of soft-deleted records come back live.** Duplicate the record, not its deletion.
