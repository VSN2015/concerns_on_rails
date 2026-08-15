The `Permittable` concern adds **declarative, typed params contracts** to any controller — what strong parameters would be if it also knew types, bounds, defaults, and *why* a request was bad. `params.permit` (and Rails 8's `params.expect`) only answer "which keys may pass"; a Permittable contract additionally **casts** each field, **validates** it, applies **defaults**, and turns every failure into a machine-readable 422. Because the contract is class-level data rather than code inside the action, it is introspectable — and can be checked against a model's schema at boot (the **schema-drift guard**).

## When to use it

- A JSON API where `user.age` arriving as `"twelve"` should be a `422` with a field-level error code, not a silent `0` or a 500.
- Catching contract/schema drift: a migration drops a column but the controller still permits it — with `model:`, that fails **at deploy**, not in production traffic.
- Replacing hand-rolled `params[:page].to_i` coercion, presence checks, and per-action `rescue ActionController::ParameterMissing` boilerplate with one declaration.
- Auto-redacting sensitive params (`ssn`, `iban`) from logs without touching `config.filter_parameters` by hand.

## Installation

The fully-qualified path is `ConcernsOnRails::Controllers::Permittable`.

```ruby
class UsersController < ApplicationController
  include ConcernsOnRails::Controllers::Permittable

  permit_params :create, :update, root: :user, model: User do
    required :name,  :string,  length: 1..80, normalize: :squish
    required :email, :string,  format: URI::MailTo::EMAIL_REGEXP, normalize: :email
    optional :age,   :integer, in: 18..120
    optional :ssn,   :string,  sensitive: true          # auto-redacted from logs
    optional :plan,  :string,  in: %w[free pro], default: "free"
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

## Configuration

### `permit_params(*actions, root: false, model: nil, unknown: :ignore, enforce: false, &contract)`

Repeatable; rules are inherited by subclasses copy-on-write. **No positional actions = catch-all** for the whole controller, and **the last matching rule wins** (the Deprecatable convention — contracts are configuration overrides).

| Option | Default | Meaning |
|---|---|---|
| `*actions` | — | Actions the contract covers; **none = catch-all** |
| `root:` | `false` | Key to unwrap first (`require(:user)` equivalent); missing/non-hash root → **400** |
| `model:` | `nil` | Model class (or `true` to infer from `controller_name`) enabling the schema-drift guard |
| `unknown:` | `:ignore` | `:ignore` / `:log` / `:error` — undeclared keys, at every nesting level (`controller`/`action`/`format` exempt at top level) |
| `enforce:` | `false` | `false` = validate lazily on first `permitted_params` call; `true` = validate in a `before_action` |

### Field DSL

- `required :name, :type, **opts` / `optional :name, :type, **opts` — type defaults to `:string`; types: `:string`, `:integer`, `:float`, `:decimal`, `:boolean`, `:date`, `:datetime`.
- A block instead of a type declares a **nested hash** (`optional :address do … end`); violation paths are dotted (`user.address.zip`).
- `array :name, of: :type` (or a block for arrays of hashes) — `length:` constrains the element **count**, element failures carry the index (`items[1]`), `required: true` opts in.

Per-field options: `in:` (Range — bounds-checked with `cover?` — or Array), `format:` / `length:` / `normalize:` (`:squish`, `:strip`, `:downcase`, `:upcase`, `:email`, or a Proc; string fields only), `default:` (validated against the field's own contract **at class load**), `validate:` (Proc — falsy fails as `"invalid"`, a returned Symbol becomes the violation code, truthy passes), `virtual:` (skip the schema check), `sensitive:` (register with the gem-wide filter_parameters registry — the Encryptable pipe).

Every bad declaration (unknown option, unknown type, `required` + `default`, `format:` on an `:integer`, a `default:` violating its own rules, duplicate fields…) raises a teaching `ArgumentError` at class load.

## The schema-drift guard

With `model:`, every non-`virtual:` scalar field is checked against the model's columns through `Support::ColumnGuard` **when the macro runs** — i.e. at controller class load. Production eager-loads controllers, so a column dropped by a migration fails the deploy, not the request:

```
ConcernsOnRails::Controllers::Permittable: 'nickname' does not exist in the database
(table: users). Add it with: bin/rails generate migration AddNicknameToUsers nickname:string
If this parameter is not backed by a column, declare it with virtual: true.
```

Nested and array fields are implicitly virtual (they don't map one-to-one onto columns). When the schema is unreachable (`db:create`, `assets:precompile`, CI bootstrap) the check skips gracefully, exactly like the model concerns. In CI, one spec running `Rails.application.eager_load!` exercises every contract in the app.

## Methods

- `permitted_params(action = action_name)` — the cast/validated/defaulted `HashWithIndifferentAccess`. Absent optional fields are **omitted** (partial updates never nil-out columns). Memoized per action. Raises `InvalidParameters` on violation; raises `ArgumentError` when no contract covers the action (programmer error, not client error).
- `enforce_params_contract` — the `before_action` entry point (public so hosts can `skip_before_action` it); only validates rules declared with `enforce: true`.
- `render_invalid_parameters(error)` — the `rescue_from` target; renders via `Respondable#render_error` when included, the identical inline envelope otherwise.
- Class-side introspection: `permittable_contracts` (all rules with their field definitions) and `permit_rule_for(action)`.

## Semantics worth knowing

- **Coercion is strict** — deliberately not `ActiveModel::Type` (`"abc".to_i == 0`, `Boolean.cast("abc") == true` silently corrupt untrusted input). `"4.5"` is not an integer; booleans accept only `true/false/"true"/"false"/"1"/"0"/1/0`; unparseable dates are `invalid_type`. Zoneless datetime strings parse as **UTC**, deterministically across host timezones.
- **Type confusion is a violation, not a 500**: `?age[]=1` or `?age[x]=1` where a scalar is declared yields `invalid_type`.
- `nil` and `""` are both **absent**: absence of an optional field omits the key, absence of a required field violates (`missing`), `default:` fills absence. Boolean `false` is present.
- Every violation instruments `invalid_parameters.concerns_on_rails` (controller, action, details) for dashboards.
- Naming note: legacy InheritedResources controllers also define `permitted_params` — don't mix the two on one controller.
