The `Permittable` concern adds **declarative, typed params contracts** to any controller — what strong parameters would be if it also knew types, bounds, defaults, and *why* a request was bad. `params.permit` (and Rails 8's `params.expect`) only answer "which keys may pass"; a Permittable contract additionally **casts** each field, **validates** it, applies **defaults**, optionally **reshapes** the output, and turns every failure into a machine-readable 422. Because the contract is class-level data rather than code inside the action, it has readers beyond the request validator: a boot-time **schema-drift guard**, an **OpenAPI 3.1** exporter, **RSpec matchers**, a **coverage audit**, a **draft generator**, and a standalone `Contract` that runs the same DSL on any Hash.

Permittable was developed in this repo and now ships as the standalone [`permittable` gem](https://github.com/VSN2015/permittable), a runtime dependency of concerns_on_rails. `ConcernsOnRails::Controllers::Permittable` is an alias for `::Permittable`, so the include path below and everything on this page work unchanged. This page is a summary written against permittable **0.10**; the gem's own [README](https://github.com/VSN2015/permittable#readme) and [CHANGELOG](https://github.com/VSN2015/permittable/blob/main/CHANGELOG.md) are the **canonical reference** and always describe the version you have installed. concerns_on_rails pins `permittable >= 0.8, < 1`, so your lockfile decides which 0.x you run — check with `bundle info permittable` before relying on a feature named here.

> **Heads up — two things to know before relying on this page**
>
> 1. **Your lockfile, not this page, decides which features you have.** The pin is `>= 0.8, < 1`, so everything up to 0.8 (monitor mode, `:json`, `nullable:`, `message:`, field groups, matchers, generator, OpenAPI) is guaranteed, and an app that locked 0.8 keeps it until `bundle update permittable`. permittable 0.9+ requires ActiveSupport >= 6.1, so on Rails 6.0 Bundler stops at permittable **0.8**. That version lacks `format:` presets, `Permittable.check_column_types` and the enum rule, `Permittable.error_format = :problem`, `permittable:audit`, `params.expect` scanning in the generator, and the 0.10 canonical-numeric tightening (`"1_8"` and `" 99 "` still cast there). Everything else on this page applies. To make the newer surface a hard requirement, pin `gem "permittable", ">= 0.10"` in the app's Gemfile.
> 2. **Two RFC 9457 switches exist — use one.** With [Respondable](respondable.md) included, Permittable's 422s render through `render_error`, so `respondable_by error_format: :problem_details` turns them into problem documents together with every other concern. The gem's own `Permittable.error_format = :problem` also renders RFC 9457 but deliberately **bypasses** `render_error`, so a controller with both set follows the gem's setting and ignores Respondable's envelope customisations.

## When to use it

- A JSON API where `user.age` arriving as `"twelve"` should be a `422` with a field-level error code, not a silent `0` or a 500.
- Catching contract/schema drift: a migration drops (or retypes) a column but the controller still permits it — with `model:`, that fails **at deploy**, not in production traffic.
- Replacing hand-rolled `params[:page].to_i` coercion, presence checks, and per-action `rescue ActionController::ParameterMissing` boilerplate with one declaration.
- Adopting validation on an API with live traffic: draft contracts from the schema, run them in **monitor mode** (report, don't reject), then enforce.
- API docs that cannot lie: export OpenAPI 3.1 from the same frozen data the server enforces.
- Auto-redacting sensitive params (`ssn`, `iban`) from logs without touching `config.filter_parameters` by hand — through the same registry Encryptable uses.

## Installation

The fully-qualified path is `ConcernsOnRails::Controllers::Permittable` (the same module as `::Permittable`).

```ruby
class UsersController < ApplicationController
  include ConcernsOnRails::Controllers::Permittable

  permit_params :create, :update, root: :user, model: User do
    required :name,  :string,  length: 1..80, normalize: :squish
    required :email, :string,  format: :email, normalize: :email
    optional :age,   :integer, in: 18..120
    optional :ssn,   :string,  sensitive: true          # auto-redacted from logs
    optional :plan,  :string,  in: %w[free pro], default: "free"
    optional :nickname, :string, nullable: true         # explicit null clears the column
    optional :metadata, :json, max_depth: 3, length: 0..32
    array    :tag_names, of: :string, length: 0..10
    optional :address do
      required :city, :string
      optional :zip,  :string, format: /\A\d{5}\z/
    end
  end

  def create
    user = User.create!(permitted_params)   # cast, validated, defaulted
  end
end
```

A violating request renders the shared error envelope:

```json
{ "success": false,
  "error": { "message": "Invalid parameters: user.age (inclusion)",
             "code": "invalid_parameters",
             "details": [{ "param": "user.age", "code": "inclusion" }] } }
```

### How a request flows

```
request params
   │
   ├─ 1  unwrap root:        params[:user]                missing or not a hash → 400
   ├─ 2  each field          normalize → absent? → cast → validate → transform
   ├─ 3  unknown-key check   at every nesting level       (unknown: :ignore | :log | :error)
   ├─ 4  finalize            only when nothing violated
   │
   └─ permitted_params  →  HashWithIndifferentAccess      or raises InvalidParameters → 422
```

Validation is **lazy by default** (first `permitted_params` call) and **memoized per action, outcome included** — a rejection is re-raised, never revalidated, so a contract runs and instruments exactly once per request. `enforce: true` moves it into a `before_action`.

## Configuration

### `permit_params(*actions, root: false, model: nil, unknown: :ignore, enforce: false, mode: nil, desc: nil, &contract)`

Repeatable; rules are inherited by subclasses copy-on-write (reassignment, never mutation). **No positional actions = catch-all** for the whole controller, and **the last matching rule wins** (the Deprecatable convention — contracts are configuration overrides).

| Option | Default | Meaning |
|---|---|---|
| `*actions` | — | Actions the contract covers; **none = catch-all** |
| `root:` | `false` | Key to unwrap first (`require(:user)` equivalent); missing/non-hash root → **400** |
| `model:` | `nil` | Model class (or `true` to infer from `controller_name`) enabling the schema-drift guard |
| `unknown:` | `:ignore` | `:ignore` / `:log` / `:error` — undeclared keys, at every nesting level |
| `enforce:` | `false` | `false` = validate lazily on first `permitted_params` call; `true` = validate in a `before_action` |
| `mode:` | `nil` | `nil` follows `Permittable.mode` (`:enforce`); `:monitor` reports violations instead of rejecting |
| `desc:` | `nil` | Documentation only — the operation description in exported OpenAPI |

### Field DSL

Three verbs. `required` / `optional` declare scalars (or, with a block, nested hashes); `array` declares a list.

- `required :name, :type, **opts` / `optional :name, :type, **opts` — type defaults to `:string`; types: `:string`, `:integer`, `:float`, `:decimal`, `:boolean`, `:date`, `:datetime`, `:json`.
- A block instead of a type declares a **nested hash** (`optional :address do … end`); violation paths are dotted (`user.address.zip`).
- `array :name, of: :type` (or a block for arrays of hashes) — `length:` constrains the element **count** and short-circuits (an oversized array is refused before any element is examined; there is **no default cap**, so declare `length:` on every array), element failures carry the index (`items[1].sku`), `required: true` opts in.
- `optional :metadata, :json, max_depth:, length:` — a **free-form hash** for `json`/`jsonb` columns: passed through uncast and unfiltered, `length:` caps the top-level key count, `max_depth:` caps container nesting (violation code `depth`), `unknown:` does not descend into it. Anything that is not a hash is `invalid_type`.

Per-field options (anything illegal for the field's kind raises at class load):

| Option | Applies to | Meaning |
|---|---|---|
| `in:` | scalar | A `Range` (bounds-checked with `cover?`) or a list (`Array`, `Set`, `Hash` keys — `in: Post.statuses` works — or any object answering `include?`). A list is cast with the field's type and **snapshotted** at class load |
| `format:` | string | A `Regexp`, or a preset: `:email` (exactly `URI::MailTo::EMAIL_REGEXP`), `:uuid`, `:url` (`http`/`https` shape, rejects `javascript:`), `:slug`, `:hostname`. Presets also export the JSON Schema `format` keyword |
| `length:` | string, array, `:json` | `Range` or `Integer` — characters, element count, or top-level key count |
| `normalize:` | string | `:squish`, `:strip`, `:downcase`, `:upcase`, `:email`, or a Proc. Runs **first**, before the absence rule, so `"   "` under `:squish` is absent |
| `default:` | scalar, array, `:json` | Used when absent; validated against the field's own contract **at class load**. Cast like a request value (`default: "18"` on an `:integer` is `18`) unless the field has a `transform:`, in which case it is handed out **as authored** |
| `validate:` | scalar, array, `:json` | Callable — falsy fails as `"invalid"`, a returned `Symbol` becomes the violation code |
| `transform:` | scalar, array, `:json` | Callable applied **after** cast and validation (see output reshaping) |
| `nullable:` | any | An explicitly-sent `null`/`""` yields `nil` instead of counting as absent (see explicit nulls) |
| `message:` | any | Human copy for violations: a String (every code) or a Hash of code → String |
| `virtual:` | any | Exempt from the schema-drift guard |
| `sensitive:` | any | Register for log redaction; cascades into nested blocks/arrays, `sensitive: false` opts a sub-field out |
| `desc:` / `example:` | any / scalar, array | Documentation for exported OpenAPI; `example:` is validated like `default:` |
| `of:` / `required:` / `max_depth:` | array / array / `:json` | Element type (default `:string`); arrays are optional unless `required: true`; nesting cap |

Checks run in a fixed order and the first failure is reported: `normalize → cast → length → in → format → validate`. `length:` deliberately precedes `format:` so a 5 MB string never reaches the regexp.

Every bad declaration (unknown option, unknown type or preset, `required` + `default`, `format:` on an `:integer`, a `default:` violating its own rules, an `in:` member the type can't cast, a bound no value could satisfy, duplicate fields, `finalize` in a nested block…) raises a teaching `ArgumentError` at class load.

### Types and strict coercion

Coercion is **deliberately strict** — not `ActiveModel::Type` (`"abc".to_i == 0`, `Boolean.cast("abc") == true` silently corrupt untrusted input). A value the type cannot faithfully represent is a violation, not a guess.

| Type | Accepts | Rejects (`invalid_type`) |
|---|---|---|
| `:string` | `String` (returned in the encoding it arrived in); `Numeric`/`true`/`false` stringified | Arrays, hashes, a String whose bytes are invalid in its own encoding |
| `:integer` | `Integer`; whole `Float`s (`4.0`); canonical numeric strings (`"-12"`, `"007"`) | `"4.5"`, `"abc"`, `"1_8"`, `" 99 "`, NaN/Infinity |
| `:float` / `:decimal` | `Numeric`; a canonical numeric string (`"1.5"`, `".5"`, `"-2e3"`) | Underscores, padding, non-finite values (`:decimal` additionally rejects the literal `"NaN"`/`"Infinity"`) |
| `:boolean` | `true`/`false`, `"true"`/`"false"`, `"1"`/`"0"`, `1`/`0` | `"yes"`, `"on"`, `2` |
| `:date` / `:datetime` | A string naming a **complete** date (any `Date.parse` format); `:datetime` also `Time`/`DateTime`/`TimeWithZone`/`Date` | Unparseable or **incomplete** strings (`"09/2026"`, `"10:30"`) — `Date.parse` would fill them in from *today* |
| `:json` | Any `Hash`, passed through uncast | Arrays, scalars |

Numeric strings must be **canonical** (sign, digits, optional fraction and exponent) — `Integer()`/`Float()`/`BigDecimal()` would read `"1_8"` as eighteen and `" 99 "` as ninety-nine, so both are refused. Zoneless datetime strings parse as **UTC**, deterministically across hosts; explicit offsets are honoured. Type confusion (`?age[]=1` against a scalar) is `invalid_type`, never a 500.

## Absence, defaults, and explicit nulls

`nil` and `""` are **both absent** (the query-parameter convention; `normalize:` runs first, so whitespace can't satisfy a `required` field by becoming `""`). Boolean `false` is present.

| The field is… | Result |
|---|---|
| absent and **optional** | omitted from the result, so partial updates never nil-out columns |
| absent and **required** | a `missing` violation |
| absent with a **`default:`** | the default — a defaulted field can never report `missing` |

That rule is right for `PATCH` and wrong for the request that means *clear this*. `nullable: true` splits it for one field: a key the client never sent is still absent (`default:` applies, `required` still violates), but a **present-but-empty** value (`null`, or the form-encoded `""`) yields `nil` — and an explicit null wins over `default:`, so `{ "plan": null }` clears the plan instead of silently resetting it. Nothing is cast or checked for an explicit null. `required` + `nullable` means "must be stated, `null` is a legal statement"; `default: nil` (nullable only) gives the `PUT` reading where absence also clears. On arrays and nested blocks it applies to the container, never its contents.

## Violations and error responses

Every failure raises `Permittable::InvalidParameters`, carrying `details` (`[{ param:, code: }]`, plus `message:` when the field declares one) and a `status`. Paths are fully qualified: `user.address.zip`, `line_items[1].sku`. `details` names **every** offender; the prose `message` is bounded (ten offenders, then a count) so a 50,000-key payload can't write a 1 MB log line.

| Code | Raised when |
|---|---|
| `missing` | A required field is absent, or the `root:` key is absent (**400**) |
| `invalid_type` | The value can't be faithfully cast — including a `root:` sent with the wrong shape (`{"user": "bob"}`, also **400**) |
| `inclusion` / `format` / `length` / `depth` | Outside `in:` / doesn't match `format:` / outside `length:` / deeper than `max_depth:` |
| `unknown` | An undeclared key under `unknown: :error` |
| `invalid` | A `validate:` callable returned a falsy value |
| *your symbol* | A `validate:` callable returned a `Symbol`, or `violate!` was called in `finalize` |

**Custom messages.** `message:` attaches human copy per field (written to read after the param name: `"is required"`); a Hash targets codes, including Symbol codes from `validate:`. App-wide copy per code comes from I18n under `permittable.errors.<code>` (`missing`, `invalid_type`, `inclusion`, `unknown`, your own symbols…). Resolution order: the field's `message:` → the translation → the bare `{ param:, code: }` shape.

**Rendering inside concerns_on_rails.** `render_invalid_parameters(error)` is the `rescue_from` target. When the controller also includes [Respondable](respondable.md), the envelope delegates to `render_error(message:, code:, status:, errors:)`, so Permittable's 422s take the same shape as every other concern's — and `respondable_by error_format: :problem_details` makes them RFC 9457 problem documents along with the rest of the app. Without Respondable, the identical inline envelope is rendered. The gem's own switch, `Permittable.error_format = :problem` (plus `Permittable.problem_base_uri`), renders RFC 9457 too but deliberately **bypasses** `render_error` delegation: pick one of the two switches, not both. Exported OpenAPI follows whichever error shape is configured.

### Unknown parameters

`unknown:` decides what happens to keys you never declared, at every nesting level: `:ignore` drops them silently (strong-parameters behaviour), `:log` drops them with a bounded `logger.warn`, `:error` makes each an `unknown` violation. At the top level, Rails' own keys are exempt — `controller`/`action`/`format`, the CSRF token (whatever `request_forgery_protection_token` names it), `_method`/`utf8`/`commit`, the route's **path parameters** (`id` on `PATCH /users/1`), and ParamsWrapper's copy of a JSON body under the controller's wrapper key. Inside a `root:` or a nested hash nothing is exempt, and a standalone `Contract` exempts nothing at all.

## Reusing fields (`Permittable.fields` and `use`)

A **field group** is a reusable field list — the same frozen data a contract's fields are, without the contract around them:

```ruby
AddressFields = Permittable.fields do
  required :city, :string, length: 1..80
  optional :zip,  :string, format: /\A\d{5}\z/
end

UserFields = Permittable.fields do
  required :name,  :string
  required :email, :string, format: :email
  optional :address do
    use AddressFields                    # groups compose
  end
end

permit_params :create, root: :user, model: User do
  use UserFields
end

permit_params :update, root: :user, model: User do
  use UserFields, optional: true         # the same fields, nothing mandatory — a complete PATCH contract
end
```

`use` splices the group in at the point of use, so the drift guard, `sensitive:` registration and the exported schema are identical to the inline spelling. `optional: true` relaxes the spliced fields (top level only — a nested block's own required sub-fields still hold once the block is sent); `only:`/`except:` select a subset, and naming a field the group doesn't declare raises at class load. A group has no `root:`/`unknown:`/`model:`/`mode:` and rejects `finalize`. A standalone `Contract` answers `#fields` too, so `use SomeContract` lets a webhook payload and a controller action share one definition.

## Output reshaping (`transform:` / `finalize`)

The safe replacement for params-mutating before_actions — both layers operate on the validated **copy**; the request's `params` is never touched.

- **`transform:`** (scalar, array and `:json` fields) — a callable applied **after** cast and validation, reshaping that field's output: `transform: ->(v) { v.split(",") }` turns a validated delimited String into an Array. It runs only on request-supplied values: absent fields stay absent, a `default:` on a transformed field is handed out **as authored** (so author it in the final shape — `transform: ->(v) { v.to_i }, default: 25`), and a partially-invalid array is never transformed. An array default's sub-fields' own `transform:` *does* run when the contract loads, so an omitted field and one sent with the default's value hand the action the same thing.
- **`finalize do |p| … end`** (once per contract, top level only) — runs after every field validated cleanly, receives the result hash, and must return the final Hash (forgetting to raises). It executes on a bare runner, **not** the controller (a `params` reference inside raises — contracts stay pure); its one extra verb is `violate!(param, code, message: nil)`, which records a violation and halts the block immediately, making finalize double as the cross-field validation seam.

```ruby
permit_params :create, root: :lease_addendum_form do
  required :resident_signatures, :string, transform: ->(v) { v.split("<<delimiter>>") }
  required :signer_names,        :string, transform: ->(v) { v.split(",") }

  finalize do |p|
    violate!("lease_addendum_form.signer_names", :length_mismatch) unless p[:signer_names].length == p[:resident_signatures].length
    p[:signatures] = p[:resident_signatures].zip(p[:signer_names]).map { |image, name| Signature.new(image:, full_name: name) }
    p.except(:resident_signatures, :signer_names)
  end
end
```

A mismatched pair of client arrays becomes a `422` with `{ param: "lease_addendum_form.signer_names", code: "length_mismatch" }` instead of silently building signatures with `nil` names.

## The schema-drift guard

With `model:`, every non-`virtual:` scalar (and `:json`) field is checked against the model's columns **when the macro runs** — i.e. at controller class load. Production eager-loads controllers, so a column dropped by a migration fails the deploy, not the request:

```
Permittable: 'nickname' does not exist in the database (table: users).
Add it with: bin/rails generate migration AddNicknameToUsers nickname:string
If this parameter is not backed by a column, declare it with virtual: true.
```

Nested and array fields are implicitly virtual. When the schema is unreachable (`db:create`, `assets:precompile`, CI bootstrap) the check skips gracefully, exactly like the model concerns' `ColumnGuard` (the gem carries its own copy). In CI, one spec running `Rails.application.eager_load!` exercises every contract in the app.

**Checking types too** is opt-in: `Permittable.check_column_types = true` (an initializer) additionally fails a field whose declared type is in a different family from its column — text (`string`/`text`/`citext`/`uuid`/`enum`/`char`), numeric (`integer`/`bigint`/`float`/`decimal`/**`boolean`**), temporal (`date`/`datetime`/`time`/`timestamp`). Column types outside those families (`json`, `binary`, `inet`…) are never checked. A Rails `enum` is compared by what clients send: `optional :status, :string, in: Order.statuses.keys` is the right contract for an integer-backed enum, and a text declaration on an enum **without** an `in:` (or with one listing a value the enum would refuse) fails at class load — otherwise `status: "bogus"` would pass the contract and raise on assignment.

## Sensitive parameters and log redaction

`sensitive: true` registers the field name for filtering. Inside concerns_on_rails the bridge file points `Permittable.filter_parameter_registry` at `ConcernsOnRails.filter_parameter_registry`, so Permittable params and [Encryptable](encryptable.md) attributes share **one** filter proc, appended to `config.filter_parameters` by the railtie (contracts declared through `::Permittable` before the bridge loaded stay filtered by the gem's own railtie). Matching mirrors Rails' symbol filters: case-insensitive substring on the key.

On a nested block or an array, `sensitive:` **cascades** to everything inside it (Rails' filter asks about leaf keys only, so registering `payment` alone would redact nothing under it); a sub-field opts out with an explicit `sensitive: false` — useful for generic names like `:id` that would otherwise redact every parameter containing them. A sensitive field's own `default:`/`example:` are omitted from the exported schema, which marks it `writeOnly`.

## Instrumentation

Every violation emits `invalid_parameters.permittable` — exactly once per action per request — with `controller`, `action`, `mode` (`:enforce`, or `:monitor` for a would-be rejection) and `details` in the payload.

## Adopting on a live API

1. **Draft** — `bin/rails permittable:generate` writes a first contract for every uncovered controller (`permittable:generate[UsersController]` for one). It infers the model from `controller_name` (columns give types, NOT NULL gives `required` — and splits into a `:create` rule and an all-optional `:update` rule when anything is required), reads the `params.require(…).permit(…)` and `params.expect(…)` calls already in the source (keys give the field list and the `root:`; comments are skipped via `Ripper`), drafts enums as `in: Model.statuses.keys`, and leaves everything it can't know as a visible TODO (`virtual: true` for non-column keys, `length:` reminders on arrays, STI `type`/`lock_version` omissions). Drafts come out in **monitor mode**, so pasting one changes nothing.
2. **Monitor** — `mode: :monitor` (per rule) or `Permittable.mode = :monitor` (app-wide; a rule's own `mode:` wins in both directions) runs the full pipeline but a violation is **reported, not rejected**: nothing raises or renders, the notification fires with `mode: :monitor`, the logger warns, `permitted_params` returns the raw pass-through (exactly what the client sent — a legacy action can keep reading `params`), and `permittable_violations` returns the recorded details. Monitor rules validate eagerly in the `before_action` regardless of `enforce:`, so telemetry never depends on the action calling `permitted_params`. Exported OpenAPI marks such operations `x-permittable-mode: "monitor"`.
3. **Audit** — `bin/rails permittable:audit` crosses the contract registry with the route set: every routed action with its effective mode, which **write actions accept a body with no contract**, which covered actions declare no `model:`, and which contracts are stale (declared for an action no route reaches, or one Rails would 404). `permittable:audit[strict]` exits 1 on any unguarded write action — a CI gate for "no new unguarded write endpoint".
4. **Enforce** — flip controllers to enforce one at a time; every 422 you now return is one you already counted.

## Beyond the controller

**RSpec matchers** (`require "permittable/rspec"`): `permit_param(:email).for_action(:create).as(:string).matching(:email).required` asserts the **declaration** (chains: `for_action`, `as`, `as_array(of:)`, `required`/`optional`, `within`, `matching`, `with_length`, `with_default`, `virtual`, `sensitive`, `nullable`; dotted paths walk nested and array blocks). The negated form asserts only "not declared" and refuses qualifiers. `accept_params(payload).for_action(:create).returning(hash)` and `reject_params(payload).with_violation("user.email", :format)` assert the **behaviour** — cast, defaulted, transformed output — still without dispatching a request. All work on a controller class, an instance, or a standalone `Contract`, and read the contract rather than the rollout mode.

**Standalone contracts** — the same DSL on any Hash (webhook payloads, job arguments, CSV rows):

```ruby
CreateUser = Permittable::Contract.define(root: :user) do
  required :email, :string, format: :email
  optional :plan,  :string, in: %w[free pro], default: "free"
end

result = CreateUser.call(payload)   # a Result: result.valid?, result.violations, result.params
CreateUser.call!(payload)           # params, or raises Permittable::InvalidParameters
CreateUser.json_schema              # JSON Schema (draft 2020-12)
```

A `Contract` always enforces (monitor mode is a request-rollout switch), exempts no router keys, and never memoizes. Client data never raises out of it; a non-Hash input or an exception from your own `validate:`/`transform:`/`finalize` code does.

**OpenAPI export** — `bin/rails permittable:openapi` (or `permittable:openapi[openapi/api.json]`; `OPENAPI_TITLE`/`OPENAPI_VERSION` override `info`) eager-loads the app, exercises the drift guard, and emits an **OpenAPI 3.1** document from the same frozen data the server enforces: request bodies as JSON Schema, shared 422/400 error components in whichever error shape is configured, templated path segments as `string` parameters, unique `operationId`s (only collisions are ever renamed). Anything JSON Schema cannot represent stays visible as an `x-permittable-*` extension (`x-permittable-pattern` for a non-ECMA regexp — including `^`/`$`, which anchor a *line* in Ruby; use `\A`/`\z` — `x-permittable-custom-validation`, `x-permittable-max-depth`, `x-permittable-normalize`, `x-permittable-mode`) rather than being mistranslated. Output is deterministic, so the file can be committed and reviewed as a diff. Programmatic fragments: `Permittable::JsonSchema.rule(rule)`, `Permittable::OpenAPI.request_body_for(controller, action)`, `.operations_for(controller)`, `.document(controllers:, info:)`.

## Methods

- `permitted_params(action = action_name)` — the cast/validated/defaulted `HashWithIndifferentAccess` (the raw pass-through in monitor mode). Absent optional fields are **omitted**. Memoized per action, outcome included. Raises `InvalidParameters` on violation; raises `ArgumentError` when no contract covers the action (programmer error, not client error).
- `permittable_violations(action = action_name)` — the violation details recorded for `action` (`[]` when clean); under enforce it swallows the raise, making "would this request fail?" a one-liner.
- `enforce_params_contract` — the `before_action` entry point (public so hosts can `skip_before_action` it); validates rules declared `enforce: true` and all monitor-mode rules.
- `render_invalid_parameters(error)` — the `rescue_from` target; renders via `Respondable#render_error` when defined, the identical inline envelope otherwise.
- Class-side introspection: `permittable_contracts` (every rule with its field definitions, frozen) and `permit_rule_for(action)` (the last matching rule, or `nil`).
- Module-level configuration: `Permittable.mode`, `Permittable.error_format` / `problem_base_uri`, `Permittable.check_column_types`, `Permittable.filter_parameter_registry` (already pointed at concerns_on_rails' registry by the bridge), `Permittable.fields`.

## Semantics worth knowing

- **Versions.** concerns_on_rails depends on `permittable >= 0.8, < 1`, so Bundler resolves the newest 0.x your Rails line allows, never older than 0.8. permittable 0.9+ requires Rails/ActiveSupport **>= 6.1**; on a Rails 6.0 host Bundler stops at permittable 0.8, which has everything above **except** `format:` presets, `Permittable.check_column_types` and the enum rule, `Permittable.error_format = :problem`, `permittable:audit`, `params.expect` scanning in the generator, and the 0.10 canonical-numeric-string tightening (`"1_8"`, `" 99 "` still cast there). Pin `gem "permittable", ">= 0.10"` in the app's Gemfile to make the newer surface a hard requirement.
- **Coercion is strict** and **`nil`/`""` are absent** — the two rules everything else follows; `nullable:` is the one deliberate exception.
- **Mistakes fail at class load**, never at request time: a malformed contract, a default that violates its own field, a column that no longer exists.
- **The request's `params` is never mutated.** Reshaping happens on the validated copy.
- **Combining with [Filterable](filterable.md):** Filterable fails closed (returns `none`) on an uncastable comparison value and never raises; when a malformed filter should be a 400/422, validate the query params with a Permittable contract first.
- Naming note: legacy InheritedResources controllers also define `permitted_params` — don't mix the two on one controller.
