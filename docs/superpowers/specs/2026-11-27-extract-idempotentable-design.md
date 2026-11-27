# Extract Idempotentable into a standalone gem — design

Approved 2026-11-27 ("ok làm luôn đi").

## Intent

Ship `ConcernsOnRails::Controllers::Idempotentable` as its own gem, `idempotentable`, the way
`permittable` was extracted. An app that only needs `Idempotency-Key` replay installs a small
actionpack-only gem instead of concerns_on_rails (activerecord, acts_as_list, friendly_id,
permittable). Existing `include ConcernsOnRails::Controllers::Idempotentable` code keeps working
unchanged.

## Goals / non-goals / anti-goals

- Goal: identical runtime behavior; every existing Idempotentable spec passes in the new repo.
- Goal: concerns_on_rails keeps the include path, `ConcernsOnRails.setup { |c| c.cache_store }`
  fallback and Respondable / `:problem_details` error rendering.
- Non-goal: new features, API renames, Throttleable/WebhookVerifiable extraction (later, if this works).
- Anti-goal: a host on Rails 6.0 losing Idempotentable (so the new gem's floor stays 6.0).

## Approaches

1. **Standalone gem + alias bridge (chosen)** — proven by permittable; one source of truth.
2. Copy into a new gem and keep the original here too — two copies drift; every audit fix twice.
3. Keep it here, only document it — doesn't give the actionpack-only install.

## Design

- **New repo** `../idempotentable` (GitHub `VSN2015/idempotentable`), gem `idempotentable` 0.1.0,
  top-level module `Idempotentable` (an `ActiveSupport::Concern`). Runtime deps `actionpack` and
  `activesupport` `>= 6.0, < 9`; Ruby `>= 3.2`. CI matrix Rails 6.0–8.1, layout mirroring
  `../permittable` (gemfiles/, .github/workflows/ci.yml, spec/support/).
- **Helpers** copied as private internals: `Idempotentable::ErrorEnvelope` (render through the
  controller's `render_error` when it has one, else the inline `{success:false,error:{…}}`
  envelope with `renderable_status`) and `Idempotentable::FreshRead`.
- **Global fallback store**: `Idempotentable.store` (a store or a Proc, resolved at use, like
  `ConcernsOnRails::Configuration#resolved_cache_store`). Lookup order unchanged: the controller's
  `idempotency_store`, then the global fallback, else the existing "no store configured" error.
- **Error message prefix** becomes `Idempotentable:` (was `ConcernsOnRails::Controllers::Idempotentable:`).
- **Specs** move with the code (controllers/idempotentable_spec + the three
  `regressions/idempotentable_*` specs) plus a copy of the FakeController / integration harness
  they need.
- **concerns_on_rails side**: `controllers/idempotentable.rb` becomes a bridge
  (`Idempotentable = ::Idempotentable`, and the gem's global fallback reads
  `ConcernsOnRails.config.resolved_cache_store`); gemspec gains
  `add_runtime_dependency "idempotentable", ">= 0.1", "< 1"`; a short compatibility spec covers the
  alias, the `ConcernsOnRails.setup` fallback and `render_error` delegation; the moved specs are
  deleted here. Released as 1.37.0 with an Upgrade note on the message prefix. CLAUDE.md, README
  and docs point to the new gem.
- **Release order**: idempotentable 0.1.0 on rubygems first, then concerns_on_rails 1.37.0.
  Until then concerns_on_rails' Gemfile uses `path: "../idempotentable"` for local work.

## Left to the builder

- How the bridge hands `ConcernsOnRails.config` to the gem (a Proc assigned to
  `Idempotentable.store` only when the app hasn't set one is fine).
- README for the new gem (from the concerns_on_rails Idempotentable section).

## Needs the user (outward-facing, ask at the time)

- Creating the GitHub repo, the first rubygems push (API key / trusted publisher), merging, releasing.
