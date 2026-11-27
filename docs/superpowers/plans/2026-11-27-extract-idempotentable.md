# Extract Idempotentable Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `ConcernsOnRails::Controllers::Idempotentable` as the standalone gem `idempotentable` 0.1.0 (new local repo `../idempotentable`), and turn the concerns_on_rails file into an alias bridge with unchanged include path, `ConcernsOnRails.setup` fallback and Respondable error rendering.

**Architecture:** The concern body moves verbatim into the new gem as top-level `Idempotentable` (an `ActiveSupport::Concern`) with its two helpers copied as `Idempotentable::ErrorEnvelope` / `Idempotentable::FreshRead` and a global fallback store `Idempotentable.store`. concerns_on_rails keeps `lib/concerns_on_rails/controllers/idempotentable.rb` as a bridge (`Idempotentable = ::Idempotentable` plus a Proc that points the fallback at `ConcernsOnRails.config.resolved_cache_store`), the same pattern as the existing `permittable` bridge.

**Tech Stack:** Ruby >= 3.2 (local: `ASDF_RUBY_VERSION=3.2.2`), actionpack + activesupport `>= 6.0, < 9`, RSpec 3, RuboCop, GitHub Actions (written, not pushed).

**Spec:** `docs/superpowers/specs/2026-11-27-extract-idempotentable-design.md` (in the concerns_on_rails repo). Precedent to mirror: `/Users/sang/Projects/individual-projects/permittable` (gemspec, Gemfile, `.github/workflows/ci.yml`, `spec/support/`) and `lib/concerns_on_rails/controllers/permittable.rb`.

## Global Constraints

- New repo path: `/Users/sang/Projects/individual-projects/idempotentable` (`git init`, local only). **No** `gh repo create`, **no** `git push`, **no** `gem push`, **no** `git stash`. No version bump of concerns_on_rails (stays 1.36.3 in `version.rb` and the `Gemfile.lock` PATH pin); the CHANGELOG gets a `1.37.0 (unreleased)` draft only.
- Top-level module `Idempotentable`; gem `idempotentable`, version `0.1.0`; helpers `Idempotentable::ErrorEnvelope` / `Idempotentable::FreshRead`; global fallback `Idempotentable.store` (a store or a Proc, resolved at use).
- New gem runtime deps: `actionpack` and `activesupport`, both `>= 6.0, < 9`. `required_ruby_version >= 3.2.0`. CI matrix Rails 6.0 through 8.1. No activerecord / sqlite3 / railties in the new gem's Gemfile (proves it is actionpack-only).
- concerns_on_rails depends on `idempotentable >= 0.1, < 1` (gemspec `add_runtime_dependency "idempotentable", ">= 0.1", "< 1"`) and uses a `path: "../idempotentable"` source in its Gemfile and gemfiles for local work.
- Runtime behaviour identical. Moved specs get only mechanical renames (constant, message prefix, helper namespace); every deviation is listed in its task.
- Error-message prefix becomes `Idempotentable:` (was `ConcernsOnRails::Controllers::Idempotentable:`).
- Lookup order unchanged: controller `idempotency_store`, then the global fallback, else the "no store configured" `ArgumentError`.
- All test commands run as `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec ...` from the repo named in the task.
- Commit messages end with the trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Commit in the repo the task edits; one commit per task.
- Never plan or run a release: GitHub repo creation, rubygems push, tagging, merging are the user's later, separate step.

## Review Focus

Failure modes the spec implies but the moved specs do not exercise, most likely first. Each has a test in the owning task.

1. `require "idempotentable"` in a bare process (only `action_controller` loaded, no concerns_on_rails, no ActiveRecord, no pre-required ActiveSupport core_ext) must load and let a controller `include Idempotentable; idempotent_actions :create` (the old file leaned on concerns_on_rails having loaded `class_attribute` etc). Test in Task 3.
2. The fallback Proc returns nil (e.g. `ConcernsOnRails.config.cache_store` unset, or `-> { nil }`): the request must end in the "no store configured" `ArgumentError`, never `NoMethodError` on nil. A non-callable store object is used as is; the Proc is re-resolved on every request. Tests in Task 3 and Task 6.
3. Bridge precedence: a store already assigned to `Idempotentable.store` before the bridge loads is not overwritten, and a `ConcernsOnRails.setup` made AFTER the bridge loaded is still seen (resolved at use, not captured). Tests in Task 6.
4. Including the concern through both names (`ConcernsOnRails::Controllers::Idempotentable` and `::Idempotentable`) in one controller registers exactly one `around_action`. Test in Task 6.
5. A host's `render_error` that is private, or that does not accept `errors:`, still receives the error (the copied ErrorEnvelope keeps `respond_to?(..., true)` and the `accepts_errors?` reflection); and the Respondable `:problem_details` replay keeps its charset-free `Content-Type`. Tests in Task 2 (copied envelope spec) and Task 6 (real Respondable).

---

## File Structure

New repo `/Users/sang/Projects/individual-projects/idempotentable`:

| File | Responsibility |
|---|---|
| `idempotentable.gemspec`, `Gemfile`, `Rakefile`, `.rspec`, `.gitignore`, `.rubocop.yml`, `.ruby-version`, `LICENSE.txt` | packaging and tooling (mirror permittable; no committed `Gemfile.lock`, see Task 1) |
| `lib/idempotentable.rb` | loader + global fallback store (`Idempotentable.store`, `.resolved_store`) |
| `lib/idempotentable/version.rb` | `Idempotentable::VERSION = "0.1.0"` |
| `lib/idempotentable/controller.rb` | the concern body (copied from `controllers/idempotentable.rb`, renamed) |
| `lib/idempotentable/error_envelope.rb`, `lib/idempotentable/fresh_read.rb` | copied helpers |
| `spec/spec_helper.rb`, `spec/support/{fake_controller,integration_harness,local_cache_remote_store}.rb` | harness copies |
| `spec/{store_spec,error_envelope_spec,fresh_read_spec,standalone_load_spec,idempotentable_spec}.rb`, `spec/regressions/idempotentable_{fingerprint_hash_array,claim_token,local_cache}_spec.rb` | specs |
| `gemfiles/rails_{6.0,6.1,7.0,7.1,7.2,8.0,8.1}.gemfile`, `.github/workflows/ci.yml` | CI matrix |
| `README.md`, `CHANGELOG.md` | docs |

concerns_on_rails changes: `lib/concerns_on_rails/controllers/idempotentable.rb` (becomes the bridge), `concerns_on_rails.gemspec`, `Gemfile`, `Gemfile.lock`, `gemfiles/shared.rb`, `spec/concerns/controllers/idempotentable_bridge_spec.rb` (new), `spec/concerns/configuration_spec.rb`, four moved specs deleted, `CLAUDE.md`, `README.md`, `docs/concerns/idempotentable.md`, `CHANGELOG.md`.

Spec decisions per existing file (grep of `Idempotentable|idempotent_actions|idempotency_store` over `spec/`): `controllers/idempotentable_spec.rb` + three `regressions/idempotentable_*` MOVE; `direct_require_spec.rb` (the `"idempotentable"` controller entry) KEEP unchanged (it requires the bridge file alone and still works); `configuration_spec.rb` KEEP, two Idempotentable examples edited (Task 6); `regressions/webhook_replay_local_cache_spec.rb` KEEP (only a comment mentions Idempotentable; it still uses `spec/support/local_cache_remote_store.rb`, so that support file stays); `support/error_envelope_spec.rb` and `regressions/error_envelope_renamed_status_symbol_spec.rb` KEEP (the concerns_on_rails `Support::ErrorEnvelope` stays for the other six controller concerns); `integration/*`, respondable and problem_details specs do not reference Idempotentable: KEEP.

---

### Task 1: Scaffold the new gem repo and the global fallback store

**Files:**
- Create (all under `/Users/sang/Projects/individual-projects/idempotentable/`): `idempotentable.gemspec`, `Gemfile`, `Rakefile`, `.rspec`, `.gitignore`, `.rubocop.yml`, `.ruby-version`, `LICENSE.txt`, `lib/idempotentable.rb`, `lib/idempotentable/version.rb`, `spec/spec_helper.rb`, `spec/support/fake_controller.rb`, `spec/store_spec.rb`

**Interfaces:**
- Produces: `Idempotentable::VERSION == "0.1.0"`; `Idempotentable.store` / `Idempotentable.store=` (raw: store, Proc or nil, default nil); `Idempotentable.resolved_store` (calls the value when it `respond_to?(:call)`, else returns it; nil when unset). Constants `FakeController` / `FakeResponse` for specs.

- [ ] **Step 1: Create the repo skeleton.** `mkdir` the path, `git init -b master`. Copy `.rspec`, `Rakefile`, `.ruby-version` from `../permittable`; copy `LICENSE.txt` and `.rubocop.yml` from concerns_on_rails (drop its `docs/**/*` exclude). `.gitignore`: `/.bundle/ /coverage/ /pkg/ /tmp/ *.gem /gemfiles/*.lock Gemfile.lock .envrc` (planner call: no committed `Gemfile.lock`; CI resolves fresh).
  `idempotentable.gemspec`: modeled on permittable's (same author/email, MIT, `required_ruby_version >= 3.2.0`, `spec.files = Dir["lib/**/*", "README.md", "LICENSE.txt", "CHANGELOG.md"]`, homepage and `source_code_uri`/`changelog_uri` under `https://github.com/VSN2015/idempotentable`), summary "Idempotency-Key replay for mutating Rails controller actions", `add_runtime_dependency "actionpack", ">= 6.0", "< 9"` and `"activesupport", ">= 6.0", "< 9"`.
  `Gemfile`: `gemspec`, `rake`, `json "< 3"` (with permittable's comment trimmed: json 3 breaks `render json:` through ActiveSupport's encoder on every supported Rails), `rspec ~> 3.12`, `simplecov ~> 1.2`, `rubocop ~> 1.92` (dev/test, `require: false`). No activerecord, sqlite3 or railties.

- [ ] **Step 2: Write the failing test** `spec/store_spec.rb` (plus `spec/spec_helper.rb`: `bundler/setup`, simplecov filter `/spec/`, `require "idempotentable"`, `require_relative "support/fake_controller"`, `disable_monkey_patching!`, random order; and `spec/support/fake_controller.rb` = copy of concerns_on_rails `spec/support/controller_test_harness.rb` unchanged). Examples, each restoring `Idempotentable.store` in an `after`:
  - `it "has no fallback store by default"`: `expect(Idempotentable.store).to be_nil` and `resolved_store` nil.
  - `it "returns a plain store object as is"`: `Idempotentable.store = obj` -> `resolved_store` is `obj`.
  - `it "calls a Proc on every lookup"`: counter lambda, two `resolved_store` calls -> counter 2.
  - `it "resolves a Proc returning nil to nil"`.
  - `it "exposes the version"`: `Idempotentable::VERSION == "0.1.0"`.

- [ ] **Step 3: Run it and see it fail.** Run (in the new repo): `ASDF_RUBY_VERSION=3.2.2 bundle install && ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/store_spec.rb` -> FAIL (`cannot load such file -- idempotentable`).

- [ ] **Step 4: Implement** `lib/idempotentable/version.rb` and `lib/idempotentable.rb`: requires `idempotentable/version`, then `module Idempotentable; class << self; attr_accessor :store; def resolved_store; end; end; end` (`resolved_store` = `store.respond_to?(:call) ? store.call : store`, same as `Configuration#resolved_cache_store`). Leave a doc comment on `store` describing the Proc form. The helper/concern `require` lines are added by Tasks 2 and 3.

- [ ] **Step 5: Run it and see it pass.** `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec` -> all green. Also `ASDF_RUBY_VERSION=3.2.2 bundle exec rubocop` -> no offenses.

- [ ] **Step 6: Commit** (`git add -A; git commit -m "Scaffold idempotentable gem with global fallback store"` plus trailer).

---

### Task 2: Copy the two helpers (ErrorEnvelope, FreshRead) with their specs

**Files:**
- Create: `lib/idempotentable/error_envelope.rb`, `lib/idempotentable/fresh_read.rb`, `spec/error_envelope_spec.rb`, `spec/fresh_read_spec.rb`
- Modify: `lib/idempotentable.rb` (add the two requires)

**Interfaces:**
- Consumes: nothing from Task 1 beyond the loader.
- Produces: `Idempotentable::ErrorEnvelope.render(controller, message:, status:, code: nil, details: nil)`, `.renderable_status(status)`, `.accepts_errors?(controller)` (module_functions); `Idempotentable::FreshRead.read(store, key)`.

- [ ] **Step 1: Write the failing specs.**
  - `spec/error_envelope_spec.rb` = copy of concerns_on_rails `spec/concerns/support/error_envelope_spec.rb` with `ConcernsOnRails::Support::ErrorEnvelope` -> `Idempotentable::ErrorEnvelope` (the file has no other ConcernsOnRails references), plus the two `.renderable_status` examples from `spec/concerns/regressions/error_envelope_renamed_status_symbol_spec.rb` (lines 20-41: renames the Rack 3.1+ symbols, keeps the old symbol while the running Rack still lists it) and its "inline branch (no render_error)" example (line 59); drop the examples that include Respondable/ErrorHandleable/Authorizable.
  - `spec/fresh_read_spec.rb`: (a) a store without `with_local_cache` -> `read` returns `store.read(key)`; (b) a store that responds to `with_local_cache` -> the read happens INSIDE the `with_local_cache` block (stub records block entry, the inner `read` sees the flag set); (c) a missing key returns nil.

- [ ] **Step 2: Run and see them fail.** `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/error_envelope_spec.rb spec/fresh_read_spec.rb` -> FAIL (uninitialized constant `Idempotentable::ErrorEnvelope`).

- [ ] **Step 3: Copy the helpers.** `lib/idempotentable/fresh_read.rb` = `lib/concerns_on_rails/support/fresh_read.rb` with `module ConcernsOnRails; module Support` -> `module Idempotentable`. `lib/idempotentable/error_envelope.rb` = `lib/concerns_on_rails/support/error_envelope.rb` with the same namespace change and `NOT_FOUND_MESSAGE` removed (planner call: only ErrorHandleable/Authorizable use it, neither is in this gem); keep `RENAMED_STATUS_SYMBOLS`, `renderable_status`, `render`, `accepts_errors?` and their comments byte-for-byte. Add `require "idempotentable/error_envelope"` and `require "idempotentable/fresh_read"` to `lib/idempotentable.rb`.

- [ ] **Step 4: Run and see them pass.** Same command -> green; `bundle exec rubocop` clean.

- [ ] **Step 5: Commit** ("Copy ErrorEnvelope and FreshRead helpers").

---

### Task 3: Port the concern and move its four specs

**Files:**
- Create: `lib/idempotentable/controller.rb`, `spec/support/integration_harness.rb`, `spec/support/local_cache_remote_store.rb`, `spec/idempotentable_spec.rb`, `spec/regressions/idempotentable_fingerprint_hash_array_spec.rb`, `spec/regressions/idempotentable_claim_token_spec.rb`, `spec/regressions/idempotentable_local_cache_spec.rb`, `spec/standalone_load_spec.rb`
- Modify: `lib/idempotentable.rb` (require the controller file last), `spec/spec_helper.rb` (nothing beyond requiring the new support files lazily via the specs' own `require "support/..."`)

**Interfaces:**
- Consumes: `Idempotentable.resolved_store`, `Idempotentable::ErrorEnvelope.render`, `Idempotentable::FreshRead.read` (Tasks 1-2).
- Produces: the public concern API unchanged (`idempotent_actions`, `idempotency_store`, `idempotency_rules`, `enforce_idempotency`, `idempotency_key`, `idempotency_fingerprint`, `idempotency_scope`, `replay_idempotent_response`, `idempotency_error_response`, constants `DEFAULT_HEADER`, `MAX_KEY_LENGTH`, `DEFAULT_REPLAY_HEADERS`, `IGNORED_FINGERPRINT_KEYS`, `STORE_UNAVAILABLE_POLICIES`, `STORE_UNAVAILABLE_RETRY_AFTER`); `idempotency_store!` resolves `self.class.idempotency_store || Idempotentable.resolved_store`.

- [ ] **Step 1: Move the specs with mechanical renames (these are the failing tests).**
  - Copy `spec/concerns/controllers/idempotentable_spec.rb` -> `spec/idempotentable_spec.rb`; copy the three `spec/concerns/regressions/idempotentable_*_spec.rb` -> `spec/regressions/`. In all four: `ConcernsOnRails::Controllers::Idempotentable` -> `Idempotentable`; `ConcernsOnRails::Support::ErrorEnvelope` -> `Idempotentable::ErrorEnvelope`.
  - Copy `spec/support/local_cache_remote_store.rb` as is. Copy `spec/support/integration_harness.rb` keeping `Result`, `dispatch`, `build_controller` and dropping `dispatch_with_cookies` (unused here); keep `require "action_controller"` and `require "rack/mock"`.
  - The ONE non-mechanical edit: the example "replays an application/problem+json document with the exact original header" (`spec/idempotentable_spec.rb`, near the end) uses `ConcernsOnRails::Controllers::Respondable`, which this gem does not have. Replace the `include Respondable` / `respondable_by` lines and the action body with a stand-in: `def create = (render json: { type: "about:blank", title: "nope" }, status: 422, content_type: "application/problem+json"; response.charset = false)`. Assertions unchanged (replay header `application/problem+json` exactly, same body, `X-Idempotency-Replayed: true`). The real-Respondable version of this example moves to the concerns_on_rails bridge spec (Task 6).
  - Add to `spec/idempotentable_spec.rb` (new fallback examples, in a `describe "global fallback store"` with an `after` that restores `Idempotentable.store`):
    - `it "falls back to Idempotentable.store when the class sets none"`: `Idempotentable.store = store`; `controller.send(:idempotency_store!)` is `store`.
    - `it "re-resolves a Proc fallback on every request"`: two different stores returned by a lambda in sequence -> two calls return two stores.
    - `it "a class-level store wins over the fallback"`.
    - `it "raises the no-store ArgumentError when the fallback Proc returns nil"`: `Idempotentable.store = -> { nil }` -> `raise_error(ArgumentError, /Idempotentable: no store configured/)` (not NoMethodError).
    - `it "names the Idempotentable.store fallback in the no-store message"`: message matches `/Idempotentable\.store/`.
    - `it "prefixes validation errors with 'Idempotentable:'"`: `idempotent_actions` with no actions -> `/\AIdempotentable: pass at least one action/`; also `:ttl`, `:on_store_unavailable`, `:headers` messages start with `Idempotentable:` (the existing `/:required/`-style matchers keep passing).
  - `spec/standalone_load_spec.rb` (Review Focus 1): a subprocess via `Open3.capture2e(RbConfig.ruby, "-I", lib_dir, "-e", code)` where `code` is `require "action_controller"; require "idempotentable"; c = Class.new(ActionController::Base) { include Idempotentable; idempotent_actions :create }; abort "AR loaded" if defined?(ActiveRecord); abort "rules" unless c.idempotency_rules.size == 1; puts "ok"`. Expect output `ok` and success status. Also `it "has no concerns_on_rails dependency"`: `defined?(ConcernsOnRails)` is nil in that subprocess.

- [ ] **Step 2: Run and see them fail.** `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec` -> FAIL (uninitialized constant `Idempotentable::ClassMethods` / no `idempotent_actions`).

- [ ] **Step 3: Port the concern** to `lib/idempotentable/controller.rb`: copy `lib/concerns_on_rails/controllers/idempotentable.rb` and make exactly these changes:
  - Replace the `module ConcernsOnRails; module Controllers; module Idempotentable` nesting with `module Idempotentable` (reopening the loader's module; keep `extend ActiveSupport::Concern`); keep every comment, constant and method body.
  - Header requires: `active_support/concern`, `active_support/core_ext/class/attribute`, `digest`, `json`, `securerandom`, `idempotentable/error_envelope`, `idempotentable/fresh_read`. Remove `concerns_on_rails/core` and the two `concerns_on_rails/support/*` requires. If the standalone spec reveals another missing core_ext, add that require (do not add requires speculatively).
  - `ConcernsOnRails::Support::ErrorEnvelope.render` -> `ErrorEnvelope.render`; every `ConcernsOnRails::Support::FreshRead.read` call (4 sites: lines 246, 265, 284, 329 in the source) -> `FreshRead.read`.
  - In `validate_idempotent!`: `prefix = "Idempotentable"`.
  - `idempotency_store!`: `store = self.class.idempotency_store || Idempotentable.resolved_store`; the error becomes `"Idempotentable: no store configured. Set `self.idempotency_store = Rails.cache` on the controller, or the global fallback: Idempotentable.store = -> { Rails.cache } (must support #read, #write(expires_in:, unless_exist:) and #delete)."`.
  - Doc comment: replace the `include ConcernsOnRails::Controllers::Idempotentable` example with `include Idempotentable` and the `ConcernsOnRails.setup { |c| c.cache_store = ... }` sentence with `Idempotentable.store = -> { Rails.cache }`.
  - Add `require "idempotentable/controller"` as the last line of `lib/idempotentable.rb`.

- [ ] **Step 4: Run and see them pass.** `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec` -> all green (the moved files total 989 lines of specs; expect the pre-move example count of those four files plus ~9 new examples); `bundle exec rubocop` clean. Fix only mechanical rename slips; do not weaken a moved assertion.

- [ ] **Step 5: Commit** ("Port the Idempotentable concern and its specs").

---

### Task 4: Rails 6.0-8.1 matrix gemfiles and CI workflow

**Files:**
- Create: `gemfiles/rails_{6.0,6.1,7.0,7.1,7.2,8.0,8.1}.gemfile`, `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: the gemspec and the full spec suite from Tasks 1-3.
- Produces: `BUNDLE_GEMFILE=gemfiles/rails_X.gemfile bundle exec rspec` for every line; a CI definition (not run here).

- [ ] **Step 1: Write the gemfiles.** Each: `source "https://rubygems.org"`, `gemspec path: ".."`, `gem "actionpack"` and `gem "activesupport"` pinned like concerns_on_rails' `gemfiles/rails_X.gemfile` (`~> 6.0.6`, `~> 6.1.0`, `~> 7.0.0`, `~> 7.1.6`, `~> 7.2.0`, `~> 8.0.0`, `~> 8.1.0` — copy the exact pin each concerns_on_rails file uses), then the dev gems `rake`, `json "< 3"`, `rspec ~> 3.12`, `simplecov ~> 1.1`. For 6.0, 6.1 and 7.0 lines only the extras concerns_on_rails' `rails_6.0.gemfile` carries that are not AR-related: `concurrent-ruby < 1.3.5` (below 7.1) and the Ruby-gated `base64 bigdecimal drb mutex_m` (>= 3.4) and `benchmark logger` (>= 4.0) blocks (copy the comments too). No activerecord, sqlite3, railties.

- [ ] **Step 2: Run the matrix locally (the failing-first check is: this has never run).** For each of the seven files: `BUNDLE_GEMFILE=gemfiles/rails_X.gemfile ASDF_RUBY_VERSION=3.2.2 bundle install && BUNDLE_GEMFILE=gemfiles/rails_X.gemfile ASDF_RUBY_VERSION=3.2.2 bundle exec rspec` -> green for each. If a line fails, fix the cause in the gem or the gemfile (e.g. a missing `require` for older ActiveSupport), never skip the example; a genuinely version-gated feature may take `min_rails:`-style gating only with a code comment saying why.

- [ ] **Step 3: Write `.github/workflows/ci.yml`** from `../permittable/.github/workflows/ci.yml`: keep the `lint` job (RuboCop on Ruby 3.2) and the `publish` job (`needs: [lint, test]`, tag-gated, `rubygems/release-gem@v1`, the GitHub-release step) unchanged except gem names and drop `runtime-deps` from `needs`; the `test` job becomes `matrix.ruby: ['3.2','3.3','3.4','4.0']` x `matrix.rails: ['6.0','6.1','7.0','7.1','7.2','8.0','8.1']` with `BUNDLE_GEMFILE: gemfiles/rails_${{ matrix.rails }}.gemfile` and `include: { ruby: head, rails: '8.1' }` marked `continue-on-error`, copying concerns_on_rails' `ci.yml` structure and its explanatory comments (trim the database text). Validate the YAML: `ruby -ryaml -e 'YAML.load_file(".github/workflows/ci.yml")'` -> no error.

- [ ] **Step 4: Commit** ("Add Rails 6.0-8.1 matrix gemfiles and CI workflow").

---

### Task 5: Gem README, CHANGELOG and build check

**Files:**
- Create: `README.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: the finished public API (Tasks 1-3).
- Produces: a buildable gem `idempotentable-0.1.0.gem`.

- [ ] **Step 1: Write `README.md`** in permittable's layout (badges row: gem version, CI, Ruby >= 3.2, Rails 6.0 - 8.x, MIT; then quick start, lifecycle, options table, store contract, notes). Source text: `docs/concerns/idempotentable.md` and the README "Idempotentable" section in concerns_on_rails, adapted: `include Idempotentable`, `Idempotentable.store = -> { Rails.cache }` for the global fallback, error prefix `Idempotentable:`, `Idempotentable::FreshRead` instead of `Support::FreshRead`, the "rendering errors" paragraph says "uses the controller's `render_error` when it has one (any gem's, public or private), else a built-in `{ success: false, error: { message, code } }` envelope". Add an "Using it from concerns_on_rails" paragraph: `ConcernsOnRails::Controllers::Idempotentable` is an alias and `ConcernsOnRails.setup { |c| c.cache_store = ... }` still acts as the fallback. Keep every gotcha from the docs page ("Notes & gotchas": per-principal scope, halting filters first, `lock_ttl:`, multipart fingerprint, store outages). Do not copy the page's "Changed in ..." history.

- [ ] **Step 2: Write `CHANGELOG.md`** with the title marker the publish job reads and one entry: `## 0.1.0 (unreleased)` / `<!-- title: ... -->` per `../permittable/CHANGELOG.md`'s first section as the model; body one sentence ("Extracted from concerns_on_rails 1.36.3; behaviour unchanged") and an "Upgrade notes" bullet: error messages now start with `Idempotentable:`.

- [ ] **Step 3: Verify the package.** `ASDF_RUBY_VERSION=3.2.2 gem build idempotentable.gemspec` -> `Successfully built RubyGem ... idempotentable-0.1.0.gem` with no warnings about missing metadata; `gem spec idempotentable-0.1.0.gem files` lists `lib/idempotentable.rb`, `lib/idempotentable/{controller,error_envelope,fresh_read,version}.rb`, README, LICENSE, CHANGELOG and nothing from `spec/`. Then `rm idempotentable-0.1.0.gem` (`*.gem` is gitignored but leave no artifact).

- [ ] **Step 4: Commit** ("Add README and CHANGELOG for 0.1.0").

---

### Task 6: concerns_on_rails bridge, dependency wiring and compatibility spec

Work in `/Users/sang/Projects/individual-projects/concerns_on_rails` on the current branch `extract/idempotentable`.

**Files:**
- Modify: `lib/concerns_on_rails/controllers/idempotentable.rb` (replace all 489 lines), `concerns_on_rails.gemspec`, `Gemfile`, `Gemfile.lock`, `gemfiles/shared.rb`, `spec/concerns/configuration_spec.rb` (lines 98-119)
- Create: `spec/concerns/controllers/idempotentable_bridge_spec.rb`
- Delete: `spec/concerns/controllers/idempotentable_spec.rb`, `spec/concerns/regressions/idempotentable_{fingerprint_hash_array,claim_token,local_cache}_spec.rb`

**Interfaces:**
- Consumes: gem `idempotentable` (`Idempotentable`, `Idempotentable.store`, `Idempotentable.resolved_store`) via the local path source; `ConcernsOnRails.config.resolved_cache_store`.
- Produces: `ConcernsOnRails::Controllers::Idempotentable` (`equal?` to `::Idempotentable`); after the bridge loads, `Idempotentable.store` is the Proc `-> { ConcernsOnRails.config.resolved_cache_store }` unless the app already set one.

- [ ] **Step 1: Write the failing spec** `spec/concerns/controllers/idempotentable_bridge_spec.rb` (`require "spec_helper"`, `require "support/integration_harness"`). An `around` saves and restores `Idempotentable.store`, and an `after` resets `ConcernsOnRails.config.cache_store = nil`. Examples:
  - `it "is the standalone gem's module"`: `expect(ConcernsOnRails::Controllers::Idempotentable).to equal(::Idempotentable)`.
  - `it "registers one around_action when included under both names"` (Review Focus 4): `IntegrationHarness.build_controller { include ConcernsOnRails::Controllers::Idempotentable; include ::Idempotentable }`, then `controller._process_action_callbacks.count { |cb| cb.filter == :enforce_idempotency }` is 1.
  - `it "uses ConcernsOnRails.setup cache_store as the fallback store"`: build a `FakeController` subclass (stubbing `around_action` as the old spec did) including the concern; `ConcernsOnRails.setup { |c| c.cache_store = -> { store } }` AFTER the class is built; `send(:idempotency_store!)` is `store` (Review Focus 3: resolved at use).
  - `it "re-reads the setup Proc on every request"`: Proc returning a different store per call.
  - `it "raises the no-store ArgumentError when setup holds nothing"` (Review Focus 2): `/no store configured/`.
  - `it "lets an explicit Idempotentable.store win over ConcernsOnRails.setup"`: assign `Idempotentable.store = other`, then `setup` -> `idempotency_store!` is `other`.
  - `it "does not overwrite a store assigned before the bridge loads"` (:subprocess style, `Open3` as in `direct_require_spec.rb`): `ruby -I lib -e 'require "action_controller"; require "idempotentable"; Idempotentable.store = :mine; require "concerns_on_rails/controllers/idempotentable"; print Idempotentable.store'` prints `mine`.
  - `it "prefixes validation errors with 'Idempotentable:' through the alias"`: `ConcernsOnRails::Controllers::Idempotentable` included class calling `idempotent_actions` with no actions raises `ArgumentError` matching `/\AIdempotentable: pass at least one action/` (the pinned upgrade note).
  - `it "replays an RFC 9457 problem document from Respondable with the exact Content-Type"`: the example moved out of the old spec (real `ConcernsOnRails::Controllers::Respondable` + `respondable_by error_format: :problem_details`, `def create = render_error(message: "nope", status: 422, code: "declined")`, store = an `ActiveSupport::Cache::MemoryStore`, two `IntegrationHarness.dispatch` POSTs with `Idempotency-Key: k1`; first `Content-Type` is `application/problem+json`, replay carries `X-Idempotency-Replayed: true`, the same `Content-Type` and body). Also `it "renders its 409 through a Respondable render_error"`: a second in-flight claim (pre-write the claim record via the store) yields a Respondable-shaped error body with `code` `idempotency_conflict`.

- [ ] **Step 2: Run and see it fail.** `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/controllers/idempotentable_bridge_spec.rb` -> FAIL (it loads the 489-line original, so `equal(::Idempotentable)` and the `Idempotentable.store` examples fail; `::Idempotentable` is not even defined yet). Do this BEFORE editing the gemspec so the failure is visible.

- [ ] **Step 3: Wire the dependency.**
  - `concerns_on_rails.gemspec`: after the permittable line add `spec.add_runtime_dependency 'idempotentable', '>= 0.1', '< 1'` with a comment mirroring the permittable one ("Controllers::Idempotentable was extracted into its own gem; the constant here is an alias, see lib/concerns_on_rails/controllers/idempotentable.rb").
  - `Gemfile`: add `gem "idempotentable", path: "../idempotentable"` with the comment `# LOCAL-ONLY until idempotentable 0.1.0 is on rubygems.org; delete this line (and in gemfiles/shared.rb) before merging.`
  - `gemfiles/shared.rb` (eval'd by every `gemfiles/*.gemfile`, so one edit covers the matrix): same line with `path: File.expand_path("../../idempotentable", __dir__)` and the same LOCAL-ONLY comment; mention it in the "KEEP IN STEP WITH THE ROOT Gemfile" header.
  - `ASDF_RUBY_VERSION=3.2.2 bundle install --local` (drop `--local` if resolution needs the network). `Gemfile.lock` gains a `PATH remote: ../idempotentable` block and `idempotentable (>= 0.1, < 1)` under the concerns_on_rails PATH spec; the `concerns_on_rails (1.36.3)` pin is unchanged. Check `git diff Gemfile.lock` shows only those additions.

- [ ] **Step 4: Replace the concern with the bridge.** Overwrite `lib/concerns_on_rails/controllers/idempotentable.rb` with: `require "idempotentable"`, `require "concerns_on_rails/core"`; `module ConcernsOnRails; module Controllers; Idempotentable = ::Idempotentable; end; end` with a comment like the permittable bridge (alias, docs now in the gem README; the error-message prefix is the gem's); then `Idempotentable.store ||= -> { ConcernsOnRails.config.resolved_cache_store }` with a comment that this makes `ConcernsOnRails.setup { |c| c.cache_store = ... }` the fallback (resolved per request; an app that assigned `Idempotentable.store` first keeps its own). No change to the autoload line in `lib/concerns_on_rails.rb` (line 58). `lib/concerns_on_rails/support/{error_envelope,fresh_read}.rb` stay (other concerns use them).

- [ ] **Step 5: Delete the moved specs and adjust `configuration_spec.rb`.** `git rm` the four moved spec files. In `spec/concerns/configuration_spec.rb` the example "Idempotentable falls back to the gem-wide store, and raises with the setup hint when unset" now asserts `raise_error(ArgumentError, /no store configured/)` (the hint text now names `Idempotentable.store`; planner call) and keeps the `ConcernsOnRails.setup` half unchanged; the "a class-level store still wins" example is unchanged.

- [ ] **Step 6: Run and see it pass.** `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/controllers/idempotentable_bridge_spec.rb spec/concerns/configuration_spec.rb spec/concerns/direct_require_spec.rb` -> green (direct_require's `controllers/idempotentable` job proves the bridge loads alone and the `ConcernsOnRails.setup` store is used). Then the whole suite: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec` -> green with the example count equal to the previous total minus the moved examples plus the new bridge examples; `ASDF_RUBY_VERSION=3.2.2 bundle exec rubocop` -> clean.

- [ ] **Step 7: Run one older and one newer Rails line.** `BUNDLE_GEMFILE=gemfiles/rails_6.0.gemfile ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/controllers spec/concerns/configuration_spec.rb` and the same with `gemfiles/rails_8.1.gemfile` -> green.

- [ ] **Step 8: Commit** in concerns_on_rails ("Bridge Controllers::Idempotentable to the idempotentable gem"; include in the body that the `path:` lines are LOCAL-ONLY).

---

### Task 7: concerns_on_rails docs (CLAUDE.md, README, docs page, CHANGELOG draft)

**Files:**
- Modify: `CLAUDE.md`, `README.md`, `docs/concerns/idempotentable.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: Task 6's behaviour (alias, fallback, message prefix).
- Produces: docs that match it. No version number changes anywhere else (`version.rb`, `Gemfile.lock` PATH pin, README version pins, `docs/assets/js/concerns.js` version, `docs/llms.txt` stay as they are; `concerns.js` entry for idempotentable stays too since its `src` still names the bridge file).

- [ ] **Step 1: Verify the stale spots exist (the "failing test").** `grep -n "Idempotentable" CLAUDE.md README.md docs/concerns/idempotentable.md` lists the lines below; after the edits the same grep must show no description of the concern's internals in CLAUDE.md beyond the alias bullet.

- [ ] **Step 2: `CLAUDE.md`.**
  - Replace the whole `**Idempotentable**` controller bullet with a short bridge bullet modeled on the `**Permittable**` one: lives in the standalone `idempotentable` gem (runtime dependency `>= 0.1, < 1`, developed in the sibling repo `../idempotentable`, github.com/VSN2015/idempotentable); `ConcernsOnRails::Controllers::Idempotentable` is an alias for `::Idempotentable`; the bridge file points `Idempotentable.store` at `ConcernsOnRails.config.resolved_cache_store` unless the app set one first, so `ConcernsOnRails.setup { |c| c.cache_store }` still is the fallback; errors render through `Respondable#render_error` via the gem's own `ErrorEnvelope` copy; error messages start `Idempotentable:`; this repo's `spec/concerns/controllers/idempotentable_bridge_spec.rb` is the compatibility suite and the behavioural specs live in the gem. Do NOT paste the old bullet's behaviour text (it moves to the gem README); keep the callback-ordering / per-principal-scope warnings as one sentence each pointing to the gem README.
  - Runtime dependencies list: add `- idempotentable >= 0.1, < 1 (the extracted Idempotentable concern, resolved from rubygems.org; developed in ../idempotentable)` next to permittable.
  - Fix the two mentions that become wrong: Support modules `ErrorEnvelope` ("used by seven controller concerns" -> "used by the controller concerns except Idempotentable, which carries its own copy") and `FreshRead` ("Idempotentable's and WebhookVerifiable's ownership reads" -> "WebhookVerifiable's ownership reads; Idempotentable carries its own copy"). In the architecture paragraph keep "its `cache_store` ... fallback store for Throttleable/Idempotentable" (still true through the bridge).

- [ ] **Step 3: `README.md`.** In the `## 🔁 Idempotentable` section (line ~2610): add a lead sentence "Idempotentable ships as the standalone `idempotentable` gem (a runtime dependency, `>= 0.1, < 1`); `ConcernsOnRails::Controllers::Idempotentable` is an alias for `::Idempotentable`, so everything below works unchanged. Full reference: the gem README"; change the "no in-process default store" note to say the fallback is `Idempotentable.store` or, here, `ConcernsOnRails.setup`; add the line to the resources table at the bottom: `| 🔁 Idempotentable (extracted sibling gem) | [github.com/VSN2015/idempotentable](https://github.com/VSN2015/idempotentable) |` under the permittable row. The one-initializer block at line ~95-115 stays.

- [ ] **Step 4: `docs/concerns/idempotentable.md`.** Prepend a paragraph like `docs/concerns/permittable.md` line 3: the concern now ships in the standalone `idempotentable` gem, the include path below is an alias, the gem's README is canonical, and concerns_on_rails pins `idempotentable >= 0.1, < 1` (check `bundle info idempotentable`). Edit the `idempotency_store` section and the "No default store" note: the fallback is `Idempotentable.store`, and `ConcernsOnRails.setup { |c| c.cache_store = ... }` is bridged to it. Drop the stale "Changed (unreleased)" heading wording only if it is untrue now; leave the 1.22.0 history. Replace "(`Support::FreshRead`)" with "(`Idempotentable::FreshRead`)".

- [ ] **Step 5: `CHANGELOG.md`.** Insert above `## 1.36.3`, in the CLAUDE.md "Release process" format, one sentence plus:
  ```
  ## 1.37.0 (unreleased)

  Idempotentable now ships as the standalone `idempotentable` gem; the include path is unchanged.

  ### Upgrade notes

  - **Idempotentable:** ArgumentError messages now start with `Idempotentable:` instead of `ConcernsOnRails::Controllers::Idempotentable:`; update any spec or rescue that matches the old prefix.
  - **Idempotentable:** the "no store configured" message now names `Idempotentable.store`; `ConcernsOnRails.setup { |c| c.cache_store }` still works as the fallback.

  ### Changed

  - **Idempotentable:** extracted into the `idempotentable` gem (new runtime dependency, `>= 0.1, < 1`); `ConcernsOnRails::Controllers::Idempotentable` is an alias.
  ```

- [ ] **Step 6: Verify.** `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec` -> green (no spec reads these files, but run it); `git diff --stat` shows only the four doc files; `grep -n "seven controller concerns" CLAUDE.md` -> no match.

- [ ] **Step 7: Commit** ("Docs: point Idempotentable at the idempotentable gem; draft 1.37.0 changelog").

---

### Task 8: Cross-repo verification and hand-off checklist

**Files:** none changed unless a check fails.

- [ ] **Step 1: New repo, full gate.** In `/Users/sang/Projects/individual-projects/idempotentable`: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec` -> green; `bundle exec rubocop` -> clean; `git status --short` empty; `git log --oneline` shows the Task 1-5 commits.

- [ ] **Step 2: concerns_on_rails full gate.** `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec` -> green; `bundle exec rubocop` -> clean; `grep -rn "Controllers::Idempotentable" lib` -> only the bridge file and the autoload line; `grep -n "idempotentable" Gemfile.lock` shows the PATH block; `git diff master --stat -- lib/concerns_on_rails/version.rb` -> unchanged.

- [ ] **Step 3: Cross-check the two copies did not drift.** `diff <(sed -n '/module Idempotentable/,$p' lib/idempotentable/controller.rb) <(git -C ../concerns_on_rails show master:lib/concerns_on_rails/controllers/idempotentable.rb | sed -n '/module Idempotentable/,$p')` (run from the new repo) differs only in: header requires, the three-level nesting/indent, `ErrorEnvelope`/`FreshRead` qualifiers, `prefix =`, and `idempotency_store!` with its message and doc comments. Anything else is a behaviour change and must be reverted.

- [ ] **Step 4: Write the hand-off note into the final reply (do not execute).** Things the user must do before concerns_on_rails 1.37.0 can merge: create `VSN2015/idempotentable` on GitHub and push; configure rubygems trusted publishing for it; tag `v0.1.0` (CI publishes); then in concerns_on_rails delete the two `path: "../idempotentable"` lines (Gemfile, gemfiles/shared.rb), `bundle update idempotentable` so `Gemfile.lock` resolves from rubygems, bump version + PATH pin + README/docs version pins per the Release process, replace `(unreleased)` in the CHANGELOG with the date, merge, tag, attach the `.gem`. Until then do not push this branch for CI: the path source does not exist on the runner.

---

## Risks & rollback

- **Two copies of ErrorEnvelope/FreshRead** (one per repo) can drift; accepted by the design. Task 8 step 3 checks the concern itself; a future fix to either helper must be made in both.
- **CI on this branch is red by construction** until the gem is published and the two `path:` lines are removed (the runner has no `../idempotentable`). The plan never pushes the branch.
- **Behaviour change surface** is limited to the error-message prefix and the no-store message text, both in the Upgrade notes. Hosts that `rescue ArgumentError => e` and match the old string break.
- **Fallback wiring is Proc-based and set at bridge load.** An app that references only `::Idempotentable` (never the alias) never loads the bridge, so `ConcernsOnRails.setup` is not consulted for it; that is by design and stated in the gem README.
- **Rollback:** all work is local and uncommitted to any remote. concerns_on_rails: `git revert` the Task 6-7 commits (or drop the branch); the new repo can simply be deleted. Nothing outward-facing happens in this plan.

## Done when

### Automated
- `cd /Users/sang/Projects/individual-projects/idempotentable && ASDF_RUBY_VERSION=3.2.2 bundle exec rspec` -> 0 failures (store, helper, standalone-load, moved concern and regression specs).
- `cd /Users/sang/Projects/individual-projects/idempotentable && for v in 6.0 6.1 7.0 7.1 7.2 8.0 8.1; do BUNDLE_GEMFILE=gemfiles/rails_$v.gemfile ASDF_RUBY_VERSION=3.2.2 bundle exec rspec || echo FAIL $v; done` -> no `FAIL` lines.
- `cd /Users/sang/Projects/individual-projects/idempotentable && ASDF_RUBY_VERSION=3.2.2 bundle exec rubocop && ASDF_RUBY_VERSION=3.2.2 gem build idempotentable.gemspec` -> no offenses; gem builds (delete the artifact).
- `cd /Users/sang/Projects/individual-projects/concerns_on_rails && ASDF_RUBY_VERSION=3.2.2 bundle exec rspec` -> 0 failures, including `spec/concerns/controllers/idempotentable_bridge_spec.rb`, `configuration_spec.rb` and `direct_require_spec.rb`.
- `cd /Users/sang/Projects/individual-projects/concerns_on_rails && ASDF_RUBY_VERSION=3.2.2 bundle exec rubocop` -> no offenses.
- `BUNDLE_GEMFILE=gemfiles/rails_6.0.gemfile` and `gemfiles/rails_8.1.gemfile` runs of `spec/concerns/controllers spec/concerns/configuration_spec.rb` in concerns_on_rails -> 0 failures.
- `git -C /Users/sang/Projects/individual-projects/concerns_on_rails diff master -- lib/concerns_on_rails/version.rb` -> empty.

### Manual
- Read the new gem's README top to bottom: quick start, the global fallback and the "Using it from concerns_on_rails" paragraph are accurate and no ConcernsOnRails-only wording leaks in.
- Read the concerns_on_rails CHANGELOG draft: one line per item, the two Upgrade notes present.
- Do the outward-facing steps listed in Task 8 step 4 (repo, rubygems, tag, then remove the `path:` lines) yourself.
