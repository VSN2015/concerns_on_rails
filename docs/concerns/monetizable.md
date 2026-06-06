`Monetizable` adds float-free money accessors to any ActiveRecord model that stores monetary amounts as integer subunits (e.g. cents) in the database. Rather than reading and writing raw integers or tolerating binary-float rounding errors, the concern exposes a reader that returns a `BigDecimal`, a writer that accepts any numeric input and rounds it to whole subunits, and a display formatter — all derived automatically from the column name. No external money library is required.

## When to use it

- A product catalogue stores `price_cents` as an integer and you need human-readable accessors (`price`, `price=`, `formatted_price`) without pulling in a full money library.
- An e-commerce order model tracks multiple monetary fields (`subtotal_cents`, `tax_cents`, `total_cents`) and you want consistent, zero-drift arithmetic across all of them.
- An invoicing system must format amounts in different locales — e.g. `€1.999,99` for European display — using per-field delimiter and separator options.
- A multi-currency ledger uses a non-standard subunit ratio (e.g. Japanese yen, where `subunit_to_unit: 1`) and needs the formatter to reflect that.
- Any model where rounding money through floating-point arithmetic is unacceptable and explicit cent-level storage is preferred.

## Installation

```ruby
# app/models/product.rb
class Product < ApplicationRecord
  include ConcernsOnRails::Monetizable

  monetizable :price_cents
  monetizable :shipping_cents, as: :shipping
  monetizable :total_cents, unit: "€", delimiter: ".", separator: ","
end
```

The canonical, fully-qualified module is `ConcernsOnRails::Models::Monetizable`. `ConcernsOnRails::Monetizable` is a backwards-compatibility alias re-exported at the top-level namespace (`Monetizable = Models::Monetizable`); either form works and resolves to the same module.

## Database columns

Each call to `monetizable` targets one or more existing integer columns that store the monetary amount in subunits (cents by default). No additional columns are created by the concern itself.

| Column | Type | Required | Notes |
|--------|------|----------|-------|
| `price_cents` (or any name passed to `monetizable`) | `integer` | Yes | Must already exist in the schema; the concern validates presence at class-load time |

```ruby
# db/migrate/YYYYMMDDHHMMSS_add_money_columns_to_products.rb
class AddMoneyColumnsToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :price_cents,    :integer
    add_column :products, :shipping_cents, :integer
    add_column :products, :total_cents,    :integer
  end
end
```

## Configuration

The `monetizable` macro is called once per field (or once for a group of fields sharing the same formatting options). Multiple calls on the same model are cumulative.

```
monetizable(*fields, as:, unit:, precision:, delimiter:, separator:, subunit_to_unit:)
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `fields` (positional) | `Symbol` / `Symbol...` | — | One or more integer column names to wrap. At least one field is required. |
| `as:` | `Symbol` | derived from column name | Overrides the generated method base name. Required when the column name does not end in `_cents`. Cannot be combined with multiple positional fields. |
| `unit:` | `String` | `"$"` | Currency symbol prepended to the formatted string. |
| `precision:` | `Integer` | `2` | Number of decimal places in the formatted output. |
| `delimiter:` | `String` | `","` | Thousands separator used in the formatted string (e.g. `"."` for European format). |
| `separator:` | `String` | `"."` | Decimal separator used in the formatted string (e.g. `","` for European format). |
| `subunit_to_unit:` | `Integer` | `100` | Number of subunits per major unit. Use `1` for currencies with no fractional unit (e.g. JPY). |

## Methods

### Instance methods

All method names below use `price` as the example base name, derived from a column called `price_cents`.

| Signature | Returns | Description |
|-----------|---------|-------------|
| `price` | `BigDecimal` or `nil` | Divides the raw integer column value by `subunit_to_unit` using `BigDecimal` arithmetic. Returns `nil` when the column is `nil`. |
| `price=(amount)` | — | Multiplies `amount` by `subunit_to_unit`, rounds to the nearest whole subunit, and writes the result back to the integer column. Accepts any value coercible to `BigDecimal` (numeric, string). Assigns `nil` when `amount` is `nil`. |
| `formatted_price` | `String` or `nil` | Returns a human-readable string using the `unit`, `precision`, `delimiter`, and `separator` options configured at class load time. Negative values are rendered with a leading minus before the unit symbol (e.g. `"-$5.00"`). Returns `nil` when the column is `nil`. |

### Class methods

| Signature | Description |
|-----------|-------------|
| `monetizable(*fields, **options)` | Configuration macro. Validates that each field exists in the schema, then defines the three accessors for each field. Stores the field-to-name mapping in the class attribute `monetizable_rules`. |

The class attribute `monetizable_rules` (a `Hash`) maps each raw cents column name (as a `Symbol`) to the derived method base name (as a `Symbol`). It is not part of the public API but is accessible for introspection.

## Examples

**Basic usage — single price field**

```ruby
class Product < ApplicationRecord
  include ConcernsOnRails::Monetizable

  monetizable :price_cents
end

product = Product.new
product.price = 19.99
product.price_cents   # => 1999
product.price         # => #<BigDecimal '0.1999e2'>
product.formatted_price # => "$19.99"
```

**Explicit method name via `:as` for a non-standard column**

```ruby
class ShippingRate < ApplicationRecord
  include ConcernsOnRails::Monetizable

  # Column is :balance — does not end in _cents, so :as is mandatory
  monetizable :balance, as: :amount, unit: "£"
end

rate = ShippingRate.new
rate.amount = 4.5
rate.balance          # => 450
rate.formatted_amount # => "£4.50"
```

**European currency formatting**

```ruby
class Invoice < ApplicationRecord
  include ConcernsOnRails::Monetizable

  monetizable :total_cents, unit: "€", delimiter: ".", separator: ","
end

invoice = Invoice.new(total_cents: 199_999)
invoice.formatted_total # => "€1.999,99"
```

## Notes & gotchas

- **Column must exist at class-load time.** `monetizable` calls `ensure_columns!` immediately when the macro is evaluated. If the migration has not been run, an `ArgumentError` is raised with the message `"'<field>' does not exist in the database (table: <table_name>)"`. This means you cannot call `monetizable` in a model before running the corresponding migration.

- **Columns not ending in `_cents` require `:as`.** If the column name cannot be auto-derived (i.e. it does not end in `_cents`), `monetizable` raises `ArgumentError` with the message `"cannot derive a money method name from '<field>' (it does not end in '_cents'); pass \`as:\` to name it explicitly"`. Always pass `as:` for non-standard column names.

- **`:as` is incompatible with multiple fields.** Passing more than one positional field alongside `as:` raises `ArgumentError` (`":as cannot be combined with multiple fields"`). When grouping fields, omit `as:` and rely on the `_cents` suffix convention.

- **`nil` propagates through all three accessors.** Reading from a `nil` column returns `nil` (not `0`). Writing `nil` stores `nil` in the column. `formatted_price` also returns `nil` when the column is `nil`. Code that consumes these values must handle `nil` explicitly.

- **Rounding is half-up to the nearest whole subunit.** `BigDecimal#round` (Ruby's default banker-style rounding does not apply here; `BigDecimal#round` with no mode argument uses half-up). `product.price = 19.999` stores `price_cents = 2000`.

- **Writer accepts strings.** Because the setter calls `BigDecimal(amount.to_s)`, string inputs like `"5"` or `"19.99"` are valid and behave identically to their numeric equivalents.

- **Negative amounts are supported.** `formatted_price` renders negative values as `"-$5.00"` — the minus sign appears before the unit symbol.

- **`monetizable_rules` is a class attribute.** It is inherited by subclasses and merged (not mutated) on each `monetizable` call, so subclasses can add fields without affecting the parent class's mapping.

- **No ActiveRecord validations are added.** The concern defines no presence, numericality, or format validations. Add those to your model manually if required.

- **No scope or callback hooks are defined.** This concern is purely about accessor and formatting methods; it does not touch `default_scope`, `before_save`, or any other ActiveRecord callback.
