# HTTP findings — v1.33.0

NOTE: written by a read-only reviewer that could not run rspec. Every item is
"reasoned, not run"; items with a repro become Proven once HTTP_spec.rb is run and
the example fails as described (move them up into "Proven bugs" then).

## Proven bugs
(none run yet; candidates with ready repros in HTTP_spec.rb: HTTP-1, HTTP-2, HTTP-3, HTTP-4)

## Suspected (unproven)

### HTTP-1 [MEDIUM] Authorizable `status: :not_found` still renders "Forbidden": existence oracle (incomplete fix of #145)
- Where: lib/concerns_on_rails/controllers/authorizable.rb:60 (default `message: "Forbidden"`), :89 (`require_role` same default), :237-245; vs lib/concerns_on_rails/controllers/error_handleable.rb:166 ("Resource not found")
- What happens: `authorize_by(status: :not_found) { ... }` without `message:` answers 404 `{"success":false,"error":{"message":"Forbidden","code":"not_found"}}`, while a genuinely missing record answers `{"success":false,"error":{"message":"Resource not found","code":"not_found"}}`. A client can still tell a concealed record from a missing one. CHANGELOG 1.33.0 (#145) and CLAUDE.md say the concealment rule renders "exactly" / "the same body as" ErrorHandleable's 404.
- Why (root cause): #145 derived only `code` from the status (DENIAL_CODES); `message` keeps the "Forbidden" default. spec/concerns/regressions/authorizable_denial_code_spec.rb:11 defaults its helper to `message: "Resource not found"`, so the regression spec never covers the default message.
- Repro: HTTP_spec.rb "HTTP-1 renders the same body as ErrorHandleable's missing-record 404 with the default message" (`rspec <path>/HTTP_spec.rb -e "HTTP-1"`)
- Fix direction: default `message:` to nil and derive it from the status (404 -> "Resource not found", the same constant ErrorHandleable uses; 401 -> "Unauthorized"; else "Forbidden"). Apply the same to `require_role`.

### HTTP-2 [MEDIUM] `require_role` with an Array argument denies every user
- Where: lib/concerns_on_rails/controllers/authorizable.rb:91-93 (`raise ... if roles.empty?`; `wanted = roles.map(&:to_s)`)
- What happens: `require_role %i[admin editor]` or `require_role ADMIN_ROLES` gives roles = [[:admin, :editor]], so wanted = ["[:admin, :editor]"], which no actor role ever equals, and every request gets 403. `require_role []` passes the "at least one role" guard ([[]] is non-empty) and also denies everyone. Fail-closed, but the endpoint is unusable.
- Why (root cause): no `flatten` on the splatted roles; the guard checks emptiness before flattening.
- Repro: HTTP_spec.rb "HTTP-2 admits an actor whose role is in an Array passed to require_role" (`-e "HTTP-2"`)
- Fix direction: `roles = roles.flatten` before the empty check and the map.

### HTTP-3 [MEDIUM] Timezoneable omits `Vary: Time-Zone` unless `response_header:` is on (default off)
- Where: lib/concerns_on_rails/controllers/timezoneable.rb:185-191 (Vary is appended only inside `apply_time_zone_response_header`, which returns early when `response_header` is nil, the default)
- What happens: with `timezoneable available: [...], default: "UTC"` (header source on by default), the action renders in the zone named by the client's `Time-Zone` request header, but the response carries no Vary. A CDN or shared cache stores the Tokyo-rendered body and serves it to a UTC client. The cookie source has the same issue (no `Vary: Cookie`). Localizable, by contrast, emits `Vary: Accept-Language` by default (`response_headers:` default true).
- Why (root cause): Vary is coupled to the optional X-Time-Zone response header instead of to the header source. The README option list documents this coupling ("`response_header:` ... `Vary: Time-Zone` is appended when the header source is on"), so this is a design flaw rather than a code/doc mismatch.
- Repro: HTTP_spec.rb "HTTP-3 advertises Vary: Time-Zone when the request header chose the zone (default response_header:)" (`-e "HTTP-3"`)
- Fix direction: append Vary whenever `opts[:header]` is on, gated by its own flag that defaults to true (mirroring Localizable's `response_headers:`), independent of `response_header:`.

### HTTP-4 [LOW] ErrorHandleable leaks the model class name and PK in the RecordNotDestroyed 422
- Where: lib/concerns_on_rails/controllers/error_handleable.rb:189-191 (`message: error.message`); activerecord-8.1.4 lib/active_record/persistence.rb:984 builds "Failed to destroy #{self.class} with #{key}=#{id}"
- What happens: a `destroy!` vetoed by a before_destroy `throw :abort` renders 422 with `"message":"Failed to destroy Admin::LegacyInvoice with id=42"`. The module comment (error_handleable.rb:36-38) promises raw messages carrying "model class names" never reach the client, and the RecordNotFound handler hides exactly this.
- Why (root cause): the handler forwards Rails' raw message, unlike the not_found / stale_object / record_not_unique handlers.
- Repro: HTTP_spec.rb "HTTP-4 does not leak the model class name / id in the 422 body" (`-e "HTTP-4"`)
- Fix direction: use a generic message ("Resource could not be deleted"), keeping `errors.full_messages` as details when present.

### HTTP-5 [LOW] Envelope-format 422s log a Rack deprecation warning on Rails 7.1–8.0 (Rack 3.2)
- Where: lib/concerns_on_rails/controllers/respondable.rb:150-159 (envelope branch passes the status symbol through unchanged); error_handleable.rb:66-72 (statuses `:unprocessable_entity`); support/error_envelope.rb:38 (inline path)
- What happens: on Rack >= 3.1 without Rails 8.1's own symbol rewrite, `render json:, status: :unprocessable_entity` goes through `Rack::Utils.status_code`, which warns "Status code :unprocessable_entity is deprecated" on every call. `problem_status_code` (respondable.rb:308-314) fixes this only for the :problem_details branch. gemfiles/rails_7.1/7.2/8.0 lockfiles resolve rack 3.2.7.
- Why unproven: the local default bundle is Rails 8.1.4, which rewrites the symbol itself; needs BUNDLE_GEMFILE=gemfiles/rails_8.0.gemfile to observe.
- Fix direction: normalize the status through RENAMED_STATUS_SYMBOLS (or an Integer) in render_error's envelope branch and in ErrorEnvelope's inline branch.
- Affects: Rails 7.1, 7.2, 8.0 with Rack >= 3.1.

### HTTP-6 [LOW] SecureHeadable `:hsts` overrides force_ssl's HSTS (shortens it, drops preload)
- Where: lib/concerns_on_rails/controllers/secure_headable.rb:81 and :199-215; actionpack lib/action_dispatch/middleware/ssl.rb:103-105 (`headers[STRICT_TRANSPORT_SECURITY] ||= @hsts_header`, default expires 2 years)
- What happens: the skip guard only sees headers present at controller time. The SSL middleware adds its own header later, and only when absent, so the controller's "max-age=31536000; includeSubDomains" wins over config.ssl_options. That shortens Rails' 2-year default to 1 year, drops `preload: true`, and adds includeSubDomains where the app chose `subdomains: false`. The guard's own comment (:196-198) says it exists to prevent exactly this.
- Why unproven: needs ActionDispatch::SSL in the stack; reasoned from source. The preset's doc line says force_ssl apps should not use it, so this is a misconfiguration trap.
- Fix direction: skip the `:hsts` preset when force_ssl is on (Rails.application.config.force_ssl), or raise at macro time.

### HTTP-7 [LOW] SecureHeadable HSTS guard is case-sensitive on the header name
- Where: lib/concerns_on_rails/controllers/secure_headable.rb:200 (`name == HSTS_HEADER`), :136 (custom keys kept as given)
- What happens: `secure_headers "strict-transport-security" => "max-age=..."` is sent over plain HTTP (RFC 6797 §7.2 forbids it) and overwrites an existing value. On Rails < 7.1 (case-sensitive headers), a lower-case custom pair alongside a preset (e.g. "x-frame-options" + :deny_frame) emits two conflicting headers.
- Why unproven: reasoned; no repro written.
- Fix direction: compare with casecmp? and canonicalize custom header names when merging.

## Improvement suggestions for this slice
1. Idempotentable: "first rule listing the action wins" (idempotentable.rb:217) means a subclass can never tighten an inherited rule (`required: true`, shorter ttl, `on_store_unavailable:`). Adopt WebhookVerifiable's most-derived-first ordering.
2. Deprecatable / Cacheable: "LAST matching rule wins, catch-all or not" (deprecatable.rb:221-224, cacheable.rb:365-367) lets a subclass catch-all silently drop a parent's action-specific `after_sunset: :gone` / `no_store: true`. WebhookVerifiable already moved to specificity-first for this reason; align both.
3. Public helper methods (`render_success`, `render_error`, `handle_*`, `on_handled_error`, `apply_secure_headers`, `secure_headable_skip?`, `secure_headable_plain_http?`, `enforce_*`, `switch_locale`, `switch_time_zone`, ...) become `action_methods` on a non-abstract ApplicationController. They are reachable through any wildcard route. Make the non-override-point ones private.
4. Authorizable: a 401 denial carries no `WWW-Authenticate` header (RFC 9110 §11.6.1 requires one); add an option. `on_authorization_denied` / the `|action, user|` block always read `current_user`, even for `require_role via: :current_admin`.
5. Localizable / Timezoneable: including the module without calling the macro leaves `param`/`header` lookup off (options default to {}), although the docs list `param: :locale` / `header: true` as defaults. Either apply defaults at include time or document "macro call required".
6. Throttleable: `by:` rejects a Symbol method name although `if:`/`unless:` accept one; accept it for consistency.
7. Support::Callable: a lambda with only required keywords (`->(controller:) {}`) is instance_exec'd with no arguments and raises ArgumentError per request. Reject it at macro time or pass `controller:`.
8. ErrorHandleable comment at error_handleable.rb:153 says the instance `rescue_with_handler` takes `object:, visited_exceptions:`. Those belong to the class method; the instance API takes only the exception.
9. Cacheable: `visibility: :public` is honoured on responses carrying `Set-Cookie` (an ActionController::Base session). Warn, or downgrade to private when Set-Cookie is present.

Coverage: every file in the slice was read in full. Throttleable, Idempotentable, WebhookVerifiable, Deprecatable, VaryHeader, ErrorEnvelope, Callable and the permittable bridge gave no defect I could tie to a concrete failing input.

## Coordinator run results (2026-10-29, SQLite, default Gemfile = Rails 8.1)
`bundle exec rspec audit/HTTP_spec.rb` → 4 examples, 4 failures.
- HTTP-1: FAIL — body `{"message":"Forbidden","code":"not_found"}` vs ErrorHandleable's `{"message":"Resource not found","code":"not_found"}` → **PROVEN** (incomplete #145).
- HTTP-2: FAIL — `require_role %i[admin editor]` answers 403 for an admin → **PROVEN**.
- HTTP-3: FAIL — Vary header empty while the body was rendered in the Time-Zone header's zone → **PROVEN** (documented coupling; design flaw).
- HTTP-4: FAIL — 422 body contains "Failed to destroy HttpAuditInvoice with id=1" → **PROVEN**.
- HTTP-5/6/7: reasoned only (other Rails lines / middleware), not run.
