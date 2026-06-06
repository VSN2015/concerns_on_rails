A declarative, block-only per-action authorization gate for Rails controllers. `Authorizable` registers predicate rules on the controller class and runs them as a `before_action` on every request. The first rule that applies to the current action and returns a falsey value halts the request immediately with an HTTP 403 (or a custom status), rendering a JSON error envelope. It solves the common problem of expressing "who can do what" at the action level without pulling in a full policy/ability framework.

## When to use it

- Requiring a signed-in user on every action of an API base controller while carving out exceptions for a small set of public endpoints.
- Restricting destructive actions (`update`, `destroy`, `publish`) to users with elevated roles without writing repetitive `before_action` guards.
- Layering coarse-grained auth rules in a base controller and fine-grained rules in child controllers — each controller inherits and extends its parent's rule list.
- Returning a configurable HTTP status code (e.g., `401 Unauthorized` for unauthenticated callers vs. `403 Forbidden` for authenticated-but-unprivileged callers) with a human-readable message.
- Prototyping access control quickly before deciding whether the complexity warrants Pundit or CanCanCan.

## Installation

Include the module in any controller class and call the configuration macros at the class level:

```ruby
class Api::BaseController < ApplicationController
  include ConcernsOnRails::Controllers::Authorizable

  # Require a logged-in user on every action
  authorize_by { current_user.present? }

  # Require admin or editor role for write actions
  authorize_by(only: %i[create update destroy]) do |_action, user|
    user.role.in?(%w[admin editor])
  end

  # Sugar form: require a specific role on a single action
  require_role :admin, only: :publish
end
```

## Configuration

### `authorize_by`

```
authorize_by(only: nil, except: nil, status: :forbidden, message: "Forbidden", &block)
```

| Option | Type | Default | Description |
|---|---|---|---|
| `only` | `Symbol`, `Array<Symbol>`, or `nil` | `nil` | Restricts the rule to the listed action names. Mutually exclusive with `except`. |
| `except` | `Symbol`, `Array<Symbol>`, or `nil` | `nil` | Skips the rule for the listed action names; applies to all others. Mutually exclusive with `only`. |
| `status` | `Symbol` or `Integer` | `:forbidden` | HTTP status code used in the denial response (e.g., `:unauthorized`, `422`). |
| `message` | `String` | `"Forbidden"` | Human-readable message included in the error envelope under `error.message`. |
| `&block` | `Proc` (required) | — | Predicate evaluated via `instance_exec` on the controller instance. Must return truthy to allow the request. Receives zero, one (`action_name`), or two (`action_name, current_user`) arguments — whichever matches the block's declared arity. |

A block is mandatory; calling `authorize_by` without one raises `ArgumentError`.

---

### `require_role`

```
require_role(*roles, via: :current_user, role_method: :role, only: nil, except: nil, status: :forbidden, message: "Forbidden")
```

| Option | Type | Default | Description |
|---|---|---|---|
| `*roles` | One or more `Symbol`/`String` (required) | — | The permitted role values. Comparison is performed after calling `.to_s` on both the configured role and the actor's role, so symbols and strings are interchangeable. |
| `via` | `Symbol` | `:current_user` | Name of the controller method that returns the current actor. |
| `role_method` | `Symbol` | `:role` | Name of the method called on the actor to read its role. |
| `only` | `Symbol`, `Array<Symbol>`, or `nil` | `nil` | Same semantics as `authorize_by`'s `only:`. |
| `except` | `Symbol`, `Array<Symbol>`, or `nil` | `nil` | Same semantics as `authorize_by`'s `except:`. |
| `status` | `Symbol` or `Integer` | `:forbidden` | HTTP status for the denial response. |
| `message` | `String` | `"Forbidden"` | Message in the error envelope. |

Calling `require_role` without at least one role argument raises `ArgumentError`.

## Methods

### Class methods

| Signature | Description |
|---|---|
| `authorize_by(only:, except:, status:, message:, &block)` | Registers a block predicate as an authorization rule. |
| `require_role(*roles, via:, role_method:, only:, except:, status:, message:)` | Registers a role-check rule as syntactic sugar over `authorize_by`. |

### Instance methods

| Signature | Description |
|---|---|
| `enforce_authorization` | `before_action` hook; iterates all declared rules in order and calls `authorization_denied` on the first failing one. Public so subclasses can override or call it explicitly. |
| `authorization_denied(status:, message:)` | Renders the error envelope. Delegates to `render_error` when `Respondable` is also included; otherwise renders inline JSON. Public override point. |

## Examples

**Layered rules on a base controller**

```ruby
class Api::BaseController < ApplicationController
  include ConcernsOnRails::Controllers::Authorizable

  # Every action: require authentication
  authorize_by(status: :unauthorized, message: "Authentication required") do
    current_user.present?
  end
end

class Api::PostsController < Api::BaseController
  # In addition to the inherited authentication check, restrict deletions to admins
  require_role :admin, only: :destroy, message: "Only admins may delete posts"

  def index  = render json: Post.all
  def destroy = Post.find(params[:id]).destroy && head(:no_content)
end
```

**Custom actor method and role attribute**

```ruby
class Api::AdminController < ApplicationController
  include ConcernsOnRails::Controllers::Authorizable

  # The actor comes from `current_admin` and its role lives in `access_level`
  require_role :superuser, :manager,
               via: :current_admin,
               role_method: :access_level,
               except: %i[index show]
end
```

**Arity-aware predicates**

```ruby
class Api::ProjectsController < ApplicationController
  include ConcernsOnRails::Controllers::Authorizable

  # Zero-arg block: only the controller context is used
  authorize_by { current_user&.active? }

  # One-arg block: receives the action name as a string
  authorize_by(only: %i[update destroy]) do |action|
    Rails.logger.info("Checking auth for #{action}")
    current_user&.admin?
  end

  # Two-arg block: receives action name and the value of current_user
  authorize_by(only: :transfer) do |_action, user|
    user&.role == "owner"
  end
end
```

## Notes & gotchas

- **Declaration order matters.** Rules are evaluated in the order they were declared. The first rule whose predicate returns falsey (and whose `only`/`except` filter applies to the current action) short-circuits evaluation and renders the denial. Later rules are never checked.
- **`only:` and `except:` are mutually exclusive.** Passing both to the same call raises `ArgumentError` at class-load time, not at request time.
- **`authorize_by` requires a block.** Omitting the block raises `ArgumentError` immediately.
- **`require_role` requires at least one role.** Calling it with no positional arguments raises `ArgumentError`.
- **Arity slicing is proc-based, not lambda-based.** The internal check is stored as a `proc` (never a `lambda`), which means Ruby's strict arity enforcement does not apply — a block written with any number of args from zero to two will work safely. Blocks with a splat or optional parameters receive all two args.
- **`current_user` resolution in `require_role`.** The method named by `via:` is called with `respond_to?` first; if the controller does not expose that method, `nil` is used as the actor, which causes the role check to fail and the request to be denied.
- **Respondable integration.** When `ConcernsOnRails::Controllers::Respondable` is also included in the controller, `authorization_denied` delegates to `render_error`, which produces a consistent `{ success: false, error: { message:, code: "forbidden" } }` envelope. Without Respondable the same shape is rendered inline directly.
- **`authorization_denied` is a no-op when `response` is nil or absent.** The method guards with `respond_to?(:response) && response` before attempting to render, so it will not raise in test harnesses or middleware-level stubs that lack a full response object.
- **Subclass inheritance.** `authorizable_rules` is a `class_attribute`. Each call to `add_authorization_rule` replaces it with `authorizable_rules + [rule]` (a new array), so subclasses that add rules do not mutate the parent's array and the parent's rules are preserved at the front of the child's list.
- **Not a policy framework.** There are no policy objects, resource inference, or ability DSL. For complex permission models, prefer [Pundit](https://github.com/varvet/pundit) or [CanCanCan](https://github.com/CanCanCommunity/cancancan).
