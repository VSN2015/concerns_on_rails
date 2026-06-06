`ErrorHandleable` installs `rescue_from` handlers for the three most common controller exceptions — `ActiveRecord::RecordNotFound`, `ActionController::ParameterMissing`, and `ActiveRecord::RecordInvalid` — and renders each as a uniform JSON error envelope. Without it, unhandled exceptions propagate as 500s or Rails HTML error pages, breaking JSON API clients. Including this concern ensures every error surface returns `{ success: false, error: { message, code } }` automatically, with no per-action rescue boilerplate.

## When to use it

- A JSON API base controller needs consistent error responses without scattering `rescue_from` declarations across every controller.
- The app already uses `Respondable` and you want error envelopes to share the same shape as success envelopes.
- A resource endpoint calls `find!` or a bang save/create and you want 404/422 responses without extra code.
- Strong parameters are required and you want a descriptive 400 response that names the missing parameter.
- A subclass needs to customize one error message or response shape without re-registering `rescue_from`.

## Installation

Include the concern in a base controller. Pairing it with `Respondable` is optional but recommended — when both are included, error handlers delegate to `Respondable#render_error` so the envelope shape is managed in a single place.

```ruby
class Api::BaseController < ApplicationController
  include ConcernsOnRails::Controllers::Respondable      # optional, recommended
  include ConcernsOnRails::Controllers::ErrorHandleable
end
```

No configuration macro is required. The three `rescue_from` handlers are registered automatically in the `included` block.

## Configuration

`ErrorHandleable` has no configuration macro. Behavior is determined entirely by which exceptions are raised and whether `Respondable` is present on the same controller. See "Methods" below for the handler signatures that can be overridden in subclasses.

## Methods

### Instance methods

| Method | Signature | Description |
|---|---|---|
| `handle_record_not_found` | `handle_record_not_found(error)` | Renders a 404 `not_found` envelope using `error.message` as the human-readable message. |
| `handle_parameter_missing` | `handle_parameter_missing(error)` | Renders a 400 `parameter_missing` envelope; the message is `"Parameter missing: <param>"` where `<param>` comes from `error.param`. |
| `handle_record_invalid` | `handle_record_invalid(error)` | Renders a 422 `record_invalid` envelope; `error.record.errors.full_messages` is attached as `details` when the record exposes an `errors` object. |

All three methods are **public**, which is intentional: subclasses can override any handler without re-declaring `rescue_from`.

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
{ "success": false, "error": { "message": "Couldn't find User with 'id'=99", "code": "not_found" } }
```

Response for a validation failure (`POST /api/users` with invalid body):
```json
{ "success": false, "error": { "message": "Validation failed: Name can't be blank", "code": "record_invalid", "details": ["Name can't be blank"] } }
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
The `details` key is only present when validation errors exist (`RecordInvalid`).

## Notes & gotchas

- **Exception strings, not classes.** `rescue_from` is registered with string names (`"ActiveRecord::RecordNotFound"`, etc.) rather than constant references. This means the handlers are safe to load before ActiveRecord/ActionController constants are resolved, and avoids autoload ordering issues.
- **Respondable detection at render time.** The concern checks `respond_to?(:render_error)` inside `render_error_envelope` each time an error occurs, not at include time. If `Respondable` is included after `ErrorHandleable`, delegation still works correctly.
- **`details` key is conditional.** The `details` array is only added to the error envelope when `RecordInvalid` is handled and the error object exposes a `record` with an `errors` object. If `error.record` is `nil` or does not respond to `errors`, `details` is omitted entirely from the JSON.
- **Handler override pattern.** Because all three handlers (`handle_record_not_found`, `handle_parameter_missing`, `handle_record_invalid`) are public instance methods, subclasses can override any one without re-declaring `rescue_from`. The `rescue_from` dispatch calls the method by name, so Ruby's normal method lookup finds the override automatically.
- **No model concerns, no DB columns.** This is a controller-only concern. It does not touch ActiveRecord models, add scopes, or require any schema changes.
- **`Respondable` include order.** When pairing with `Respondable`, include `Respondable` before `ErrorHandleable`. Both orderings work (see the delegation note above), but the conventional order communicates intent more clearly and matches the recommended pattern in the source comments.
- **Parameter name in 400 response.** The 400 message is always `"Parameter missing: <param>"` where `<param>` is `error.param` from `ActionController::ParameterMissing`. The exact symbol name of the missing parameter is always included, making it unambiguous for API clients.
