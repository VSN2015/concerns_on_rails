Per-request locale selection for Rails controllers, driven by URL params and/or the `Accept-Language` request header. The concern wraps `I18n.with_locale` in an `around_action` so `I18n.locale` is set correctly for the entire action and automatically restored when the action completes. It eliminates the boilerplate `around_action :switch_locale` pattern that almost every internationalized Rails app reimplements, and it adds a safe allow-list guard so a malformed param or header value can never raise `I18n::InvalidLocale`.

## When to use it

- A publicly accessible Rails app that serves multiple languages and must honour the visitor's browser language preference via the `Accept-Language` header.
- An API that accepts an explicit locale parameter (e.g. `?locale=fr`) from a mobile or single-page application and must scope all translations and error messages to that locale for the duration of the request.
- A multi-tenant SaaS product where each tenant's subdomain or URL segment encodes the locale, and the locale must be resolved from a custom param name rather than the default `:locale`.
- An app that must be hardened against locale-injection attacks — `available:` acts as an explicit allow-list so arbitrary values from the query string or header are silently discarded rather than passed to I18n.
- Any controller hierarchy where you want locale resolution in `ApplicationController` once, with individual subcontrollers able to override `switch_locale` or `resolved_locale` for custom logic.

## Installation

Include the concern in `ApplicationController` (or any controller base class) and call the `localizable` macro to configure it:

```ruby
class ApplicationController < ActionController::Base
  include ConcernsOnRails::Controllers::Localizable

  localizable available: %i[en fr de], default: :en
end
```

To read locale from a custom param name and disable `Accept-Language` header parsing:

```ruby
class ApplicationController < ActionController::Base
  include ConcernsOnRails::Controllers::Localizable

  localizable available: %i[en fr de], default: :en, param: :lang, header: false
end
```

## Configuration

The `localizable` class macro accepts the following keyword options:

| Option | Type | Default | Description |
|---|---|---|---|
| `available:` | `Array<Symbol>` | `nil` | Allow-list of locales considered when matching a param value or `Accept-Language` header entry. Values are coerced to symbols. When `nil` (or blank), `I18n.available_locales` is used at request time. |
| `default:` | `Symbol` / `nil` | `nil` | Locale to use when neither the param nor the header produces a match. Coerced to a symbol. When `nil` and no match is found, falls back to `I18n.default_locale`. |
| `param:` | `Symbol` / `nil` | `:locale` | Name of the query/route parameter to inspect first. Coerced to a symbol. Pass `nil` to disable param-based resolution entirely. |
| `header:` | `Boolean` | `true` | When `true`, parses the `Accept-Language` request header as a fallback after param resolution fails. Set to `false` to skip header inspection. |
| `response_headers:` | `Boolean` | `true` | Emit `Content-Language: <resolved locale>` on every response (BCP 47 form, `pt_BR` → `pt-BR`) and, when `header:` is `true`, append `Accept-Language` to the `Vary` header (de-duplicated, never clobbering an existing `Vary`). Written before the action runs. Set `false` to emit neither. |

Calling `localizable` with no arguments is valid; all options take their defaults.

## Methods

### Instance methods

| Signature | Visibility | Description |
|---|---|---|
| `switch_locale(&block)` | public | `around_action` callback. Writes the response headers (`Content-Language`, and `Vary: Accept-Language` when the header is a source), then calls `I18n.with_locale(resolved_locale, &block)`, running the action block under the chosen locale and restoring the previous locale afterwards. Subclasses may override this method. |
| `resolved_locale` | public | Returns the `Symbol` locale chosen for the current request using the resolution order described below. Never returns a value absent from `I18n.available_locales`. |

### Class methods

| Signature | Description |
|---|---|
| `localizable(available:, default:, param:, header:, response_headers:)` | Configuration macro. Stores options in the inheritable `localizable_options` class attribute. Safe to call in subcontrollers to narrow or change the options for that subtree. |

## Examples

**Basic multi-language application controller**

```ruby
class ApplicationController < ActionController::Base
  include ConcernsOnRails::Controllers::Localizable

  # Accept English, French, and German; fall back to English.
  localizable available: %i[en fr de], default: :en
end

# GET /articles?locale=fr  → I18n.locale is :fr for the entire action
# GET /articles            → I18n.locale is :en (default)
# GET /articles?locale=es  → I18n.locale is :en (:es not in allow-list)
```

**API controller using a custom param, header disabled**

```ruby
class Api::V1::BaseController < ActionController::API
  include ConcernsOnRails::Controllers::Localizable

  localizable available: %i[en fr de], default: :en, param: :lang, header: false
end

# GET /api/v1/products?lang=de  → I18n.locale is :de
# Accept-Language: fr is ignored because header: false
```

**Inspecting the resolved locale inside an action**

```ruby
class PagesController < ApplicationController
  def show
    # resolved_locale is public — call it directly when you need the value
    # without the around_action wrapping.
    locale = resolved_locale   # => :fr, :de, :en, etc.
    @page = Page.find_by!(slug: params[:slug])
  end
end
```

## Notes & gotchas

- **`Content-Language` and `Vary` are on by default.** A localized JSON body is a different representation per locale; without `Vary: Accept-Language` a shared cache (CDN, `Rack::Cache`) would serve one client's French to another's English. The headers are written before the action, so they ride a rescued error too. If you localize only via a URL param, pass `header: false` and `Vary` is skipped (the URL already differs); `response_headers: false` disables both.

- **`rescue_from` handlers render under the resolved locale.** Rails runs them in `ActionController::Rescue#process_action`, after the `around_action` has already unwound and `I18n.with_locale` has restored the default — so a rescued error (ErrorHandleable's 404, CursorPaginatable's 400, your own handler) used to render English under `Content-Language: fr`. The locale `switch_locale` chose is re-entered for the handler's duration and the previous one is always restored afterwards, even when the handler raises, so nothing leaks into the next request on the thread. An exception raised before `switch_locale` ran (a `before_action` declared ahead of the include) is handled as before, in the default locale.

- **Rails' own `Vary: Accept` is preserved.** ActionController adds it during render, but only while the header is still blank, so writing `Vary` before the action would suppress it and lose a cache dimension on content-negotiated responses. The concern seeds `Accept` itself whenever Rails would have (`request.should_apply_vary_header?`), then appends `Accept-Language`. An existing `Vary: *` is left alone, and matching is case-insensitive.

**Resolution order.** The concern resolves locale in this priority sequence: `params[param]` → first matching language in `Accept-Language` → `default:` option → `I18n.default_locale`. Each step is attempted only if the previous one produced no match within the allow-list.

**Final validation against `I18n.available_locales`.** Even if a locale passes the `available:` allow-list, `resolved_locale` performs a final check against `I18n.available_locales` before returning. If the two lists fall out of sync (e.g. the `available:` option is set to `[:en, :fr]` but I18n is later reconfigured to only `[:en]`), the resolved `:fr` candidate is discarded and `I18n.default_locale` is returned instead. This means locale resolution is always safe to hand to `I18n.with_locale` without risk of `I18n::InvalidLocale`.

**`Accept-Language` parsing honours quality weights.** The header `es-MX,fr-CA;q=0.9,en;q=0.8` is split into tags, entries with `q=0` are dropped as "not acceptable", and the rest are ranked highest-q first; tags sharing a q-value keep their header order (the sort is explicitly stable — Ruby's `sort_by` is not, and used to shuffle ties once a header carried about eight tags). The `q` parameter name is case-insensitive (`Q=0` is refused too), and its value must be an RFC 9110 qvalue — `0` to `1` with at most three decimals (`0`, `0.5`, `1.000`). Anything else (`0x10`, `1_0`, `Infinity`, `2`, `0.1234`) is treated as `q=0` and the tag is dropped; `Float()` used to read those at face value, so a malformed weight outranked every real one. Each tag is matched case-insensitively against the allow-list — the full tag first (`fr-CA` matches an available `:"fr-CA"`), then its primary subtag (`fr`); the first match wins.

**`around_action` is registered at include time.** The `included` block calls `around_action :switch_locale` unconditionally. If `localizable` is never called, `localizable_options` is an empty hash, `available:` is `nil`, `default:` is `nil`, `param:` is `nil`, and `header:` is `nil` — so all resolution paths are effectively disabled and `resolved_locale` returns `I18n.default_locale` for every request.

**`switch_locale` is public and overridable.** Because `switch_locale` is a public instance method (not private), subcontrollers can override it to add logging, set thread-local variables alongside the locale, or wrap the block in additional context — call `super` to preserve the locale-switching behavior.

**No runtime dependencies.** The concern relies solely on `active_support/concern` and the standard `I18n` module that ships with Rails. No additional gems are required.

**Thread safety.** `I18n.with_locale` is thread-safe by design (it uses a thread-local variable internally). The `localizable_options` class attribute is set once at class-load time via `class_attribute` and is never mutated at runtime, so concurrent requests share it safely.

**Inheritance.** `class_attribute` inheritance means subcontrollers can call `localizable` again with different options (e.g. a narrower `available:` list) without affecting the parent class or sibling controllers.

## Changed in 1.22.0

- Regional tags match: `Accept-Language: fr-CA` tries the full tag before falling back to the primary subtag, so `available: [:"fr-CA"]` can now match.
- `resolved_locale` is memoized per request.
