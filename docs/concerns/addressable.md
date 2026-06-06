`Addressable` is a model concern that wires up declarative normalization and format validation for a postal address stored across several database columns. A single `addressable_by` macro handles whitespace cleanup, postal-code pattern checking, ISO 3166-1 country-code validation, required-part presence enforcement, and exposes a `full_address` helper — all without any external geocoding dependency. Its scope is deliberately limited to structural correctness (shape and format), not real-world deliverability; a custom verifier callable can be plugged in for that.

## When to use it

- A `Location`, `Address`, or `Venue` model that stores a structured mailing address and needs consistent normalization before persistence.
- A multi-tenant SaaS application where different models (`UserProfile`, `Company`, `ShippingAddress`) each carry an address but may use different column names.
- Any model that collects international addresses and needs per-country postal-code format enforcement without adding a geocoding library.
- A checkout or registration flow where address input must be validated server-side and error messages fed back to the form without custom i18n setup.
- A model that receives address data from a third-party API (potentially using full country names or ISO alpha-3 codes) and needs those canonicalized to alpha-2 before storage.

## Installation

```ruby
# app/models/location.rb
class Location < ApplicationRecord
  include ConcernsOnRails::Addressable

  addressable_by  # uses default columns: line1, line2, city, state, postal_code, country
end
```

The module is defined at the fully-qualified path `ConcernsOnRails::Models::Addressable` (the namespaced form encouraged for new code); `ConcernsOnRails::Addressable` is a backwards-compatibility alias that points at it. Both are equivalent — use whichever you prefer (e.g. the fully-qualified form when disambiguating in a `describe` block).

A fully-configured example:

```ruby
class Place < ApplicationRecord
  include ConcernsOnRails::Addressable

  addressable_by line1:            :street,
                 postal_code:      :zip,
                 country:          :country_code,
                 required:         %i[line1 city postal_code country],
                 default_country:  "GB",
                 validate_state:   true,
                 lengths:          { line1: 100, city: 50, postal_code: 5..10 },
                 allow_blank:      %i[state],
                 normalize_country: true,
                 verify_with:      ->(rec) { Usps.verify(rec) },
                 if:               :on_addresses?
end
```

## Database columns

The concern reads and writes the columns listed below. Every column is a string. Columns whose names differ from the defaults are remapped via the `addressable_by` macro; columns that are absent from the schema are silently skipped (partial schemas are supported).

| Canonical part | Default column | Required by default |
|----------------|----------------|---------------------|
| `line1`        | `line1`        | yes                 |
| `line2`        | `line2`        | no                  |
| `city`         | `city`         | yes                 |
| `state`        | `state`        | no                  |
| `postal_code`  | `postal_code`  | yes                 |
| `country`      | `country`      | yes                 |

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_locations.rb
class CreateLocations < ActiveRecord::Migration[7.1]
  def change
    create_table :locations do |t|
      t.string :line1,       null: false
      t.string :line2
      t.string :city,        null: false
      t.string :state
      t.string :postal_code, null: false
      t.string :country,     null: false

      t.timestamps
    end
  end
end
```

To use custom column names, provide a minimal schema and map parts in `addressable_by`:

```ruby
# db/migrate/YYYYMMDDHHMMSS_create_places.rb
class CreatePlaces < ActiveRecord::Migration[7.1]
  def change
    create_table :places do |t|
      t.string :street
      t.string :city
      t.string :region
      t.string :zip
      t.string :country_code

      t.timestamps
    end
  end
end
```

## Configuration

The macro `addressable_by` accepts any combination of column-override keyword pairs (the canonical part name mapped to your actual column name) plus behavioral options. All arguments are optional; calling `addressable_by` with no arguments uses defaults.

| Option | Type | Default | Description |
|---|---|---|---|
| `line1:` | Symbol | `:line1` | Maps the `line1` canonical part to a real column. |
| `line2:` | Symbol | `:line2` | Maps the `line2` canonical part to a real column. |
| `city:` | Symbol | `:city` | Maps the `city` canonical part to a real column. |
| `state:` | Symbol | `:state` | Maps the `state` canonical part to a real column. |
| `postal_code:` | Symbol | `:postal_code` | Maps the `postal_code` canonical part to a real column. |
| `country:` | Symbol | `:country` | Maps the `country` canonical part to a real column. |
| `required:` | Array of Symbols | `%i[line1 city postal_code country]` | Canonical part names that must be present on save. Each listed part must resolve to a column that exists in the schema; otherwise an `ArgumentError` is raised at load time. Pass `[]` to make all parts optional. |
| `default_country:` | String | `"US"` | The ISO alpha-2 country code used for postal-code format selection when the `country` column is absent from the schema or blank on the record. A present-but-unrecognized country value (e.g. a full name without `normalize_country: true`) bypasses this default and falls back to the permissive postal pattern instead. |
| `validate_state:` | Boolean | `false` | When `true`, validates the `state` column against USPS state/territory codes for `US` and Canadian province/territory codes for `CA`. Has no effect for other countries. |
| `lengths:` | Hash | `{}` | Per-part length constraints keyed by canonical part name. An `Integer` value (e.g. `line1: 100`) sets a positive maximum with no minimum. A `Range` value (e.g. `city: 3..50`) sets both bounds; endless (`3..`) and beginless (`..50`) ranges are supported. Bounds must be non-negative integers; inverted, empty, or float ranges raise `ArgumentError` at load time. Length is measured on the normalized value. |
| `allow_blank:` | Boolean or Array of Symbols | `false` | Parts whose length check is skipped when the value is blank. `true` exempts all parts; an Array (e.g. `%i[state line2]`) exempts specific parts. Independent of `required:` — a required part that is blank still fails presence validation regardless of this setting. |
| `normalize_country:` | Boolean | `false` | When `true`, canonicalizes the country value to its ISO 3166-1 alpha-2 code during normalization: recognized English names (`"Canada"`, `"United States"`) and ISO alpha-3 codes (`"CAN"`, `"USA"`) are mapped to their alpha-2 equivalents. Unrecognized values are left unchanged. Also enables postal-code and state validation to recognize named countries. |
| `verify_with:` | Callable | `nil` | An optional callable (lambda or proc) that receives the record and performs real-world deliverability verification. Runs only after all structural validations pass. Return values are interpreted as described in the Examples section. |
| `if:` | Symbol, Proc, or Array | `nil` | Standard Rails validation condition. When present, address validations are skipped unless the condition holds. Normalization (`before_validation`) always runs unconditionally. |
| `unless:` | Symbol, Proc, or Array | `nil` | Standard Rails validation condition. When present, address validations are skipped when the condition holds. Normalization still runs unconditionally. |

## Methods

### Instance methods

| Signature | Description |
|---|---|
| `full_address(separator: ", ")` | Returns the present address parts joined into a single string in canonical order (`line1`, `line2`, `city`, `state`, `postal_code`, `country`). Blank parts are omitted. The separator is configurable. |
| `address_lines` | Returns an ordered Array of the present part values, suitable for multi-line rendering. Blank parts are excluded. |
| `address_present?` | Returns `true` if any configured part has a value. |
| `address_complete?` | Returns `true` if every `required:` part has a value (presence check only; no format validation). |
| `address_attributes` | Returns a Hash of `{ canonical_part => value }` for every present part. Useful for passing to serializers or external verifiers. |

### Class methods

The `addressable_by` macro is the sole class-level entry point. There are no additional public class methods.

## Examples

**Basic US address with default columns:**

```ruby
class Location < ApplicationRecord
  include ConcernsOnRails::Addressable

  addressable_by
end

loc = Location.new(
  line1:       "  1 Infinite  Loop ",
  city:        "Cupertino",
  state:       "ca",
  postal_code: "95014",
  country:     "us"
)

loc.valid?
# => true

loc.line1        # => "1 Infinite Loop"
loc.state        # => "CA"
loc.country      # => "US"
loc.full_address # => "1 Infinite Loop, Cupertino, CA, 95014, US"
loc.address_attributes
# => { line1: "1 Infinite Loop", city: "Cupertino", state: "CA",
#      postal_code: "95014", country: "US" }
```

**Custom column names, international address, and country normalization:**

```ruby
class Place < ApplicationRecord
  include ConcernsOnRails::Addressable

  addressable_by line1:             :street,
                 state:             :region,
                 postal_code:       :zip,
                 country:           :country_code,
                 required:          %i[line1 city postal_code country],
                 normalize_country: true,
                 validate_state:    true
end

place = Place.new(
  street:       "  10   Downing  St ",
  city:         "London",
  region:       "ENG",
  zip:          " sw1a 2aa ",
  country_code: "United Kingdom"
)

place.valid?
# => true

place.street       # => "10 Downing St"
place.zip          # => "SW1A 2AA"
place.country_code # => "GB"   (normalized from "United Kingdom")
```

**Conditional validation with an external verifier:**

```ruby
class ShippingAddress < ApplicationRecord
  include ConcernsOnRails::Addressable

  addressable_by required:    %i[line1 city postal_code country],
                 verify_with: ->(rec) {
                   result = SmartyStreets.verify(rec.address_attributes)
                   return true if result.deliverable?
                   result.errors  # Array of error strings added to :base
                 },
                 if: :shipping_address_required?

  def shipping_address_required?
    requires_delivery?
  end
end
```

The verifier callable may return:
- `true` or `nil` — success, no errors added
- `false` — adds `"address could not be verified"` to `:base`
- A `String` — added as a `:base` error
- An `Array` — each element added as a `:base` error
- Alternatively, the callable may call `record.errors.add(...)` directly and return any value

## Notes & gotchas

- **Verifier runs only after structural validation passes.** If `validate_address` adds any errors (presence, country code, postal code, state, or lengths), `verify_with:` is never called. This prevents wasted API calls on obviously malformed addresses.

- **Normalization is unconditional.** The `before_validation :normalize_address` callback registered in `included do` runs regardless of any `if:` or `unless:` condition on `addressable_by`. Only the validations are gated by those conditions.

- **`validate :validate_address` is registered only once.** Calling `addressable_by` a second time in the same class updates the configuration attributes but does not register a second validation callback. The `if:`/`unless:` condition from the first call is the one that sticks.

- **Country resolution for postal/state checks follows three-step logic.** When validating a postal code or state, the concern resolves the effective country as: (1) the record's country value if it is a recognized ISO alpha-2 code, (2) `default_country` if the country column is absent or blank, (3) `nil` (permissive fallback) if a country value is present but unrecognized. This means a full name like `"Canada"` stored without `normalize_country: true` will not trigger the CA-specific postal pattern — it falls back to the permissive pattern instead of incorrectly applying `default_country`'s rules.

- **`normalize_country: true` affects both normalization and validation.** With this option, country names and alpha-3 codes are rewritten to alpha-2 in `before_validation`, which means subsequent postal-code and state validation both see and validate against the canonical alpha-2 code.

- **Length is measured on the normalized value, after `before_validation` runs.** A CA postal code `"k1a0b1"` normalizes to `"K1A 0B1"` (7 characters, including the inserted space). A `lengths: { postal_code: 6 }` constraint will therefore reject it. Size your length bounds accordingly.

- **`allow_blank:` and `required:` are independent.** A part listed in `required:` that is blank will fail presence validation. If that same part also has a minimum-length constraint and is not in `allow_blank:`, it will additionally fail the length check — both errors appear. `allow_blank:` only suppresses the length error for a blank value; it does not suppress the presence error.

- **Partial schemas work automatically.** If a column (e.g. `line2`, `state`) does not exist in the table, that part is silently excluded from normalization, validation, and helper output. A length rule for an absent column is also silently skipped. However, listing an absent part in `required:` raises `ArgumentError` at class load time.

- **Unknown part names raise `ArgumentError` at load time.** Passing an unrecognized keyword to `addressable_by` (e.g. `unit: :line2`) raises `ArgumentError: ConcernsOnRails::Models::Addressable: unknown address part(s): unit`. The same applies to unknown part names in `lengths:` and `allow_blank:`.

- **All `lengths:` bounds are validated at load time.** Non-positive integers, float endpoints, non-integer range endpoints, inverted ranges (`8..3`), empty exclusive ranges (`3...3`), and negative bounds all raise `ArgumentError` immediately when the class is loaded, not at runtime.

- **Postal-code patterns are available for US, CA, GB, AU, DE, and FR.** Every other country uses a permissive fallback pattern (`/\A[A-Z0-9][A-Z0-9 -]{1,8}[A-Z0-9]\z/`). A blank postal code always passes format validation; presence is governed separately by `required:`.

- **State validation covers only US and CA.** When `validate_state: true`, the check is a no-op for any country other than `"US"` or `"CA"`. The USPS set includes DC, territories (AS, GU, MP, PR, VI); the Canadian set covers all 10 provinces and 3 territories.

- **Error messages are plain English strings without i18n lookup.** The concern does not use Rails' `I18n.t` for its messages, so no locale files are required. Messages mirror Rails' own length-error phrasing, including singular/plural: `"is too long (maximum is 1 character)"` vs `"is too long (maximum is 5 characters)"`.

- **The concern has no runtime gem dependencies beyond ActiveSupport.** `friendly_id` and `acts_as_list` are not used here. The only requirement is Rails 5.0+ (for `class_attribute` and `before_validation`).
