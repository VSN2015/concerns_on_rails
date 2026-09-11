`ErrorHandleable` installs `rescue_from` handlers for the controller exceptions a JSON API meets in practice — not-found lookups, missing/unpermitted parameters, validation failures (ActiveRecord *and* plain ActiveModel form objects), callback-aborted saves and destroys, optimistic-locking conflicts, unique-index and foreign-key races, malformed bodies and unsupported formats — and renders each as a uniform JSON error envelope. Without it, unhandled exceptions propagate as 500s or Rails HTML error pages, breaking JSON API clients. Including this concern ensures every error surface returns `{ success: false, error: { message, code } }` automatically, with no per-action rescue boilerplate.

## When to use it

- A JSON API base controller needs consistent error responses without scattering `rescue_from` declarations across every controller.
- The app already uses `Respondable` and you want error envelopes to share the same shape as success envelopes.
- A resource endpoint calls `find!` or a bang save/create and you want 404/422 responses without extra code.
- Strong parameters are required and you want a descriptive 400 response that names the missing parameter.
- A subclass needs to customize one error message or response shape without re-registering `rescue_from`.
- Models use `lock_version` and a lost update should be a 409 the client can retry, not a 500.
- A unique index backs a uniqueness validation and the rare race should surface as a 409, not a 500 carrying the adapter's SQL error.
- Some exceptions should still reach the error tracker — `handle_errors except:` lets them propagate.

## Installation

Include the concern in a base controller. Pairing it with `Respondable` is optional but recommended — when both are included, error handlers delegate to `Respondable#render_error` so the envelope shape is managed in a single place.

```ruby
class Api::BaseController < ApplicationController
  include ConcernsOnRails::Controllers::Respondable      # optional, recommended
  include ConcernsOnRails::Controllers::ErrorHandleable
end
```

No configuration macro is required. Every handler in the table below is registered automatically in the `included` block; `handle_errors` (optional) trims the set.

## Configuration

**Handled exceptions.** The key doubles as the envelope `code`.

| Key (= `code`)               | Exception                                      | Status | `details`                    |
|------------------------------|------------------------------------------------|--------|------------------------------|
| `not_found`                  | `ActiveRecord::RecordNotFound`                 | 404    | —                            |
| `parameter_missing`          | `ActionController::ParameterMissing`           | 400    | —                            |
| `record_invalid`             | `ActiveRecord::RecordInvalid`                  | 422    | `errors.full_messages`       |
| `validation_error`           | `ActiveModel::ValidationError`                 | 422    | `model.errors.full_messages` |
| `record_not_saved`           | `ActiveRecord::RecordNotSaved`                 | 422    | record errors, if any        |
| `record_not_destroyed`       | `ActiveRecord::RecordNotDestroyed`             | 422    | record errors, if any        |
| `stale_object`               | `ActiveRecord::StaleObjectError`               | 409    | —                            |
| `record_not_unique`          | `ActiveRecord::RecordNotUnique`                | 409    | —                            |
| `foreign_key_violation`      | `ActiveRecord::InvalidForeignKey`              | 409    | —                            |
| `unpermitted_parameters`     | `ActionController::UnpermittedParameters`      | 400    | the parameter names          |
| `invalid_authenticity_token` | `ActionController::InvalidAuthenticityToken`   | 422    | —                            |
| `bad_request`                | `ActionController::BadRequest`                 | 400    | —                            |
| `parse_error`                | `ActionDispatch::Http::Parameters::ParseError` | 400    | —                            |
| `unknown_format`             | `ActionController::UnknownFormat`              | 406    | —                            |

Statuses follow Rails' own `rescue_responses` wherever Rails has an opinion; the two database-constraint races Rails leaves as 500s (`RecordNotUnique`, `InvalidForeignKey`) get the REST-conventional 409.

**`handle_errors(only: nil, except: nil)`** — class macro, optional. Trims the default map: `only:` keeps just the named keys, `except:` drops them; accepts a symbol or an array; calls accumulate. Only the concern's *own* registrations are removed (matched on exception name **and** handler method), so a `rescue_from` you declared for the same exception is untouched — and nothing is ever re-added, so your later declarations keep precedence. Unknown keys raise `ArgumentError` listing the valid ones; passing both `only:` and `except:` raises.

```ruby
handle_errors except: :stale_object                                # let lock conflicts reach the error tracker
handle_errors only: %i[not_found parameter_missing record_invalid] # the pre-expansion trio
```

**`error_handleable_keys`** — class attribute, read-only in practice: the keys still active on this controller after any `handle_errors` calls.

## Methods

### Instance methods

| Method | Signature | Description |
|---|---|---|
| `handle_record_not_found` | `(error)` | 404 `not_found`. The message is the generic `"Resource not found"` — the raw message would leak the model class and the queried attribute/value. |
| `handle_parameter_missing` | `(error)` | 400 `parameter_missing`; message `"Parameter missing: <param>"` from `error.param`. |
| `handle_record_invalid` | `(error)` | 422 `record_invalid`; `error.message`, `details` = `record.errors.full_messages`. |
| `handle_validation_error` | `(error)` | 422 `validation_error` for `validate!` on a plain `ActiveModel::Model`; `details` = `error.model.errors.full_messages`. |
| `handle_record_not_saved` | `(error)` | 422 `record_not_saved` (`save!` aborted by a callback); `details` only when the record carries errors. |
| `handle_record_not_destroyed` | `(error)` | 422 `record_not_destroyed`; `details` only when the record carries errors. |
| `handle_stale_object` | `(error)` | 409 `stale_object`; generic `"Resource was modified by another request; reload and retry"` (the raw message names the model class). |
| `handle_record_not_unique` | `(error)` | 409 `record_not_unique`; generic `"Resource already exists"` (the raw message is the adapter's SQL error). |
| `handle_invalid_foreign_key` | `(error)` | 409 `foreign_key_violation`; generic `"Resource is referenced by other records"`. |
| `handle_unpermitted_parameters` | `(error)` | 400 `unpermitted_parameters`; message lists the names, `details` = the names. |
| `handle_invalid_authenticity_token` | `(error)` | 422 `invalid_authenticity_token`. |
| `handle_bad_request` | `(error)` | 400 `bad_request`; generic `"Bad request"` — the raw message echoes the offending input. |
| `handle_parse_error` | `(error)` | 400 `parse_error`; generic `"Malformed request body"` — the raw message carries the parser's body excerpt. |
| `handle_unknown_format` | `(error)` | 406 `unknown_format`; `"Requested format is not supported"`. |

All handlers are **public**, which is intentional: subclasses can override any one without re-declaring `rescue_from`. Each renders through the private `render_handled_error(key, message:, errors:)`, which takes `code` and status from the table; an override that wants the standard envelope with different wording can call `render_error_envelope(message:, code:, status:, errors:)`.

**`on_handled_error(key, error, status:, message:)`** — public override point, called by the render funnel before each handled error is rendered. The default instruments `handled_error.concerns_on_rails` with `controller` (the controller path), `action`, `code` (the HANDLERS key), `status`, `message` (as rendered), `exception` and `exception_class`. `error` is the rescued exception — captured by an override of `rescue_with_handler`, so it is `nil` when a handler is called directly. Override it to report selectively (`Sentry.capture_exception(error) if key == :record_not_unique`); call `super` to keep the event, and rescue inside the override if the reporter itself can fail — it runs before the response is rendered.

The private helper `render_error_envelope` is not part of the public API and should not be called directly.

## Examples

**Standard JSON API base controller**

```ruby
class Api::BaseController < ApplicationController
  include ConcernsOnRails::Controllers::Respondable
  include ConcernsOnRails::Controllers::ErrorHandleable
end

class Api::UsersController < Api::BaseController
  def show
    user = User.find(params[:id])   # raises RecordNotFound → handled automatically
    render json: { success: true, data: user }
  end

  def create
    user = User.create!(user_params)   # raises RecordInvalid → handled automatically
    render json: { success: true, data: user }, status: :created
  end

  private

  def user_params
    params.require(:user).permit(:name, :email)  # raises ParameterMissing → handled automatically
  end
end
```

Response for a missing record (`GET /api/users/99`):
```json
{ "success": false, "error": { "message": "Resource not found", "code": "not_found" } }
```

Response for a validation failure (`POST /api/users` with invalid body):
```json
{ "success": false, "error": { "message": "Validation failed: Name can't be blank", "code": "record_invalid", "details": ["Name can't be blank"] } }
```

**Letting some exceptions propagate**

```ruby
class Api::BaseController < ApplicationController
  include ConcernsOnRails::Controllers::ErrorHandleable

  # Lock conflicts should page us, not turn into a quiet 409.
  handle_errors except: :stale_object
end

Api::BaseController.error_handleable_keys   # => every key but :stale_object
```

**Overriding a single handler in a subclass**

```ruby
class Api::BaseController < ApplicationController
  include ConcernsOnRails::Controllers::ErrorHandleable
end

class Api::LegacyController < Api::BaseController
  # Override the message wording without touching rescue_from
  def handle_record_not_found(error)
    render json: { success: false, error: { message: "Resource not found.", code: "not_found" } },
           status: :not_found
  end
end
```

**Without Respondable — inline envelope**

```ruby
class Api::BaseController < ApplicationController
  # Respondable is NOT included; render_error_envelope falls back to inline rendering
  include ConcernsOnRails::Controllers::ErrorHandleable
end
```

The JSON shape rendered is identical to the `Respondable` path:
```json
{ "success": false, "error": { "message": "...", "code": "..." } }
```
The `details` key is only present when there is something to list (validation messages, unpermitted parameter names).

**Reporting handled errors selectively**

```ruby
class Api::BaseController < ApplicationController
  include ConcernsOnRails::Controllers::Respondable
  include ConcernsOnRails::Controllers::ErrorHandleable

  REPORTABLE = %i[record_not_unique foreign_key_violation stale_object parse_error].freeze

  def on_handled_error(key, error, **)
    Sentry.capture_exception(error, tags: { handled_code: key }) if error && REPORTABLE.include?(key)
    super
  rescue StandardError => e
    Rails.logger.warn("[errors] reporter failed: #{e.message}")   # never let the reporter break the 4xx
  end
end

# config/initializers/handled_errors.rb — or subscribe instead of overriding:
ActiveSupport::Notifications.subscribe("handled_error.concerns_on_rails") do |event|
  StatsD.increment("api.handled_error", tags: ["code:#{event.payload[:code]}", "status:#{event.payload[:status]}"])
end
```

## Notes & gotchas

- **Exception strings, not classes.** `rescue_from` is registered with string names (`"ActiveRecord::RecordNotFound"`, etc.) rather than constant references. This means the handlers are safe to load before ActiveRecord/ActionController constants are resolved, and avoids autoload ordering issues.
- **Respondable detection at render time.** The concern checks `respond_to?(:render_error)` inside `render_error_envelope` each time an error occurs, not at include time. If `Respondable` is included after `ErrorHandleable`, delegation still works correctly.
- **`details` key is conditional.** `details` is added only when there is something to list: `errors.full_messages` of the record/model behind `RecordInvalid`, `ValidationError`, `RecordNotSaved` and `RecordNotDestroyed` (omitted when the object has no errors or none is attached), and the parameter names for `UnpermittedParameters`.
- **Generic messages by design.** Database- and parser-level exceptions (`StaleObjectError`, `RecordNotUnique`, `InvalidForeignKey`, `BadRequest`, `ParseError`) render fixed wording rather than `error.message`, which carries SQL fragments, table/column and model names or the offending input. Override the handler if a trusted environment wants the detail.
- **`UnpermittedParameters` needs `:raise`.** It is only raised with `config.action_controller.action_on_unpermitted_parameters = :raise` (the default logs or ignores).
- **Trimming never re-adds.** `handle_errors` only removes the concern's own `[exception, handler]` pairs from `rescue_handlers`; a host `rescue_from` for the same exception — declared before or after — is preserved and keeps its precedence.
- **Handler override pattern.** Because every handler is a public instance method, subclasses can override any one without re-declaring `rescue_from`. The `rescue_from` dispatch calls the method by name, so Ruby's normal method lookup finds the override automatically.
- **No model concerns, no DB columns.** This is a controller-only concern. It does not touch ActiveRecord models, add scopes, or require any schema changes.
- **`Respondable` include order.** When pairing with `Respondable`, include `Respondable` before `ErrorHandleable`. Both orderings work (see the delegation note above), but the conventional order communicates intent more clearly and matches the recommended pattern in the source comments.
- **Parameter name in 400 response.** The 400 message is always `"Parameter missing: <param>"` where `<param>` is `error.param` from `ActionController::ParameterMissing`. The exact symbol name of the missing parameter is always included, making it unambiguous for API clients.
