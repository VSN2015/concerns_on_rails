`SecureHeadable` is a controller concern that sets modern HTTP security response headers and provides a thin, readable wrapper around Rails' native Content-Security-Policy DSL. It addresses the gap between Rails' default middleware headers and a comprehensive defense-in-depth posture: clickjacking via missing `X-Frame-Options`, MIME-type confusion via missing `X-Content-Type-Options`, referrer leakage, and the legacy XSS auditor being left enabled. It operates entirely through an `after_action` callback and introduces zero gem dependencies beyond Rails itself.

## When to use it

- You want a single `include` + macro call to lock down the standard security headers across all controllers without installing a third-party gem like `secure_headers`.
- You are rolling out a Content-Security-Policy incrementally and want to start in report-only mode before switching to enforcing mode, scoped to individual controllers.
- You need to layer per-controller CSP rules on top of the global initializer-level policy (e.g., a narrower policy for an admin namespace).
- You want to explicitly disable the legacy `X-XSS-Protection` auditor, which was itself exploitable and has been removed from all modern browsers.
- You need to add non-preset headers such as `Permissions-Policy` alongside preset headers in a single, consistent declaration point.

## Installation

Include the concern in `ApplicationController` (or any controller class) and call the configuration macros immediately after:

```ruby
class ApplicationController < ActionController::Base
  include ConcernsOnRails::Controllers::SecureHeadable

  # Mix preset symbols with custom "Header-Name" => "value" pairs freely:
  secure_headers :nosniff, :sameorigin_frame, :no_referrer_leak, :disable_legacy_xss
  secure_headers "Permissions-Policy" => "geolocation=()"

  # Delegates to Rails' native CSP DSL.
  # Roll out report-only first, then switch to enforcing:
  content_security_policy_for(report_only: true) do |policy|
    policy.default_src :self
    policy.script_src  :self
    policy.object_src  :none
  end
end
```

## Configuration

### `secure_headers(*presets, **custom)`

Registers one or more header preset symbols and/or arbitrary custom headers. Can be called multiple times; later declarations win on colliding header names. The merged result is stored in the `secure_headable_headers` class attribute and written to the response by `apply_secure_headers`.

**Preset symbols** (`*presets`):

| Preset | Header name | Value |
|---|---|---|
| `:nosniff` | `X-Content-Type-Options` | `nosniff` |
| `:sameorigin_frame` | `X-Frame-Options` | `SAMEORIGIN` |
| `:deny_frame` | `X-Frame-Options` | `DENY` |
| `:no_referrer_leak` | `Referrer-Policy` | `strict-origin-when-cross-origin` |
| `:no_cross_domain` | `X-Permitted-Cross-Domain-Policies` | `none` |
| `:disable_legacy_xss` | `X-XSS-Protection` | `0` |

**Custom headers** (`**custom`): any `"Header-Name" => "value"` keyword pairs. Keys are coerced to strings via `to_s`.

Passing an unrecognized symbol raises `ArgumentError` immediately at class load time.

---

### `content_security_policy_for(report_only: false, **action_opts, &block)`

A thin pass-through to Rails' native CSP class methods. It never reimplements CSP logic.

| Option | Type | Default | Description |
|---|---|---|---|
| `report_only` | Boolean | `false` | When `true`, delegates to `content_security_policy_report_only(true, ...)`. When `false`, delegates to `content_security_policy(...)`. |
| `only` | Symbol / Array | — | Forwarded to Rails as a per-action condition. |
| `except` | Symbol / Array | — | Forwarded to Rails as a per-action condition. |
| `if` | Symbol / Proc | — | Forwarded to Rails as a per-action condition. |
| `unless` | Symbol / Proc | — | Forwarded to Rails as a per-action condition. |

All `**action_opts` not listed above are forwarded unchanged to the underlying Rails method. The policy block receives the Rails `ActionDispatch::ContentSecurityPolicy` object.

Calling this method when `ActionController::ContentSecurityPolicy` is not available (i.e., Rails < 5.2 or a non-standard controller base) raises `ArgumentError`.

## Methods

### Instance methods

| Signature | Description |
|---|---|
| `apply_secure_headers` | Writes all registered headers to `response` via `set_header`. Registered as an `after_action` automatically on include. No-ops cleanly when `response` is `nil` or when the controller has no `response` method. Public so subclasses can override it. |

### Class methods

| Signature | Description |
|---|---|
| `secure_headers(*presets, **custom)` | Registers preset and/or custom headers. Merges into the inherited `secure_headable_headers` hash; later calls win on collision. |
| `content_security_policy_for(report_only: false, **action_opts, &block)` | Delegates to Rails' native `content_security_policy` or `content_security_policy_report_only` class methods with the supplied block and per-action options. |

## Examples

**Typical application controller setup**

```ruby
class ApplicationController < ActionController::Base
  include ConcernsOnRails::Controllers::SecureHeadable

  secure_headers :nosniff, :sameorigin_frame, :no_referrer_leak, :disable_legacy_xss
  secure_headers "Permissions-Policy" => "geolocation=()"
end
```

**Narrower CSP for an admin namespace, scoped to enforcing mode**

```ruby
class Admin::BaseController < ApplicationController
  # Override the app-wide report-only policy with an enforcing policy for admin:
  content_security_policy_for do |policy|
    policy.default_src :self
    policy.script_src  :self
    policy.img_src     :self, :data
    policy.object_src  :none
    policy.frame_ancestors :none
  end
end
```

**Overriding `X-Frame-Options` for an embeddable widget controller**

```ruby
class WidgetsController < ApplicationController
  # :sameorigin_frame was set in ApplicationController; :deny_frame wins here
  # because the second secure_headers call merges and later declarations win:
  secure_headers :deny_frame
end
```

## Notes & gotchas

- **`after_action`, not `before_action`:** Headers are written after the response is rendered. This means they can reinforce or override headers that Rails middleware or the render process set earlier. It also means the `response` object is available and populated when `apply_secure_headers` runs.
- **Later declarations win:** Each call to `secure_headers` merges into the accumulated class attribute hash. If `:sameorigin_frame` is declared first and `:deny_frame` is declared second (even in a separate call), `X-Frame-Options` resolves to `DENY`. This applies across inheritance: a subcontroller that calls `secure_headers :deny_frame` will override the parent's `:sameorigin_frame` for that header only, leaving all other inherited headers intact.
- **`:disable_legacy_xss` emits `"0"`, never `"1; mode=block"`:** The legacy XSS auditor was itself exploitable (information disclosure, bypass) and has been removed from Chrome, Firefox, and Edge. `"0"` explicitly disables any remaining auditor. This concern will never emit a non-zero value for this header.
- **`content_security_policy_for` requires Rails 5.2+:** The method checks `respond_to?(:content_security_policy)` and raises `ArgumentError` with a descriptive message if the host controller class does not expose that method. This check fires at class-definition time.
- **CSP nonce generation is out of scope:** `content_security_policy_nonce_generator` and `content_security_policy_nonce_directives` are app-wide initializer settings. This concern does not set or read them.
- **Per-controller CSP overrides the global initializer:** A `content_security_policy_for` call inside a controller class overrides the application-level CSP configured in `config/initializers/content_security_policy.rb` for requests handled by that controller, which is standard Rails behavior.
- **`apply_secure_headers` is a public method:** Subclasses can override it. The guard `respond_to?(:response) && response` ensures it no-ops safely in test contexts where `response` is `nil`.
- **No model columns, no migrations, no gem dependencies:** This is a pure controller concern. It depends only on `active_support/concern` and, for CSP delegation, on the Rails `ActionController::ContentSecurityPolicy` module available from Rails 5.2 onward.
