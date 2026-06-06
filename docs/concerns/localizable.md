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

Calling `localizable` with no arguments is valid; all options take their defaults.

## Methods

### Instance methods

| Signature | Visibility | Description |
|---|---|---|
| `switch_locale(&block)` | public | `around_action` callback. Calls `I18n.with_locale(resolved_locale, &block)`, running the action block under the chosen locale and restoring the previous locale afterwards. Subclasses may override this method. |
| `resolved_locale` | public | Returns the `Symbol` locale chosen for the current request using the resolution order described below. Never returns a value absent from `I18n.available_locales`. |

### Class methods

| Signature | Description |
|---|---|
| `localizable(available:, default:, param:, header:)` | Configuration macro. Stores options in the inheritable `localizable_options` class attribute. Safe to call in subcontrollers to narrow or change the options for that subtree. |

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

**Resolution order.** The concern resolves locale in this priority sequence: `params[param]` → first matching language in `Accept-Language` → `default:` option → `I18n.default_locale`. Each step is attempted only if the previous one produced no match within the allow-list.

**Final validation against `I18n.available_locales`.** Even if a locale passes the `available:` allow-list, `resolved_locale` performs a final check against `I18n.available_locales` before returning. If the two lists fall out of sync (e.g. the `available:` option is set to `[:en, :fr]` but I18n is later reconfigured to only `[:en]`), the resolved `:fr` candidate is discarded and `I18n.default_locale` is returned instead. This means locale resolution is always safe to hand to `I18n.with_locale` without risk of `I18n::InvalidLocale`.

**`Accept-Language` parsing strips regions and quality weights.** The header `es-MX,fr-CA;q=0.9,en;q=0.8` is parsed left-to-right; each entry is split on `;` (dropping quality weights) and then on `-` (dropping region subtags). The primary language tag is matched case-insensitively against the allow-list. The first entry that matches is used; subsequent entries are ignored.

**`around_action` is registered at include time.** The `included` block calls `around_action :switch_locale` unconditionally. If `localizable` is never called, `localizable_options` is an empty hash, `available:` is `nil`, `default:` is `nil`, `param:` is `nil`, and `header:` is `nil` — so all resolution paths are effectively disabled and `resolved_locale` returns `I18n.default_locale` for every request.

**`switch_locale` is public and overridable.** Because `switch_locale` is a public instance method (not private), subcontrollers can override it to add logging, set thread-local variables alongside the locale, or wrap the block in additional context — call `super` to preserve the locale-switching behavior.

**No runtime dependencies.** The concern relies solely on `active_support/concern` and the standard `I18n` module that ships with Rails. No additional gems are required.

**Thread safety.** `I18n.with_locale` is thread-safe by design (it uses a thread-local variable internally). The `localizable_options` class attribute is set once at class-load time via `class_attribute` and is never mutated at runtime, so concurrent requests share it safely.

**Inheritance.** `class_attribute` inheritance means subcontrollers can call `localizable` again with different options (e.g. a narrower `available:` list) without affecting the parent class or sibling controllers.
