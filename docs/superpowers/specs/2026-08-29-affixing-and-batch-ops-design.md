# Scope affixing + batch operations

**Date:** 2026-08-29
**Target release:** 1.27.0
**Status:** approved design, not yet implemented

Sub-project 1 of a four-part "deepen the existing concerns" wave. The remaining
three (controller-side polish, Encryptable key rotation, Rails-native bridges)
each get their own spec and release; see *Wave context* at the end.

## Problem

Two gaps in the shipped model concerns, both traceable to the 1.22 review
backlog.

**Scope-name collisions have no escape hatch on three concerns.** SoftDeletable,
Publishable and Schedulable define their scopes in `included do`, with hard-coded
names. Activatable, Expirable, Lockable, Stateable and Anonymizable define theirs
inside their macro and accept `prefix:`/`suffix:` to rename them. So a model that
includes SoftDeletable (`.active`) alongside Activatable (`.active`) or Expirable
(`.active`) gets a silent clobber — whichever concern is included last wins.
Activatable's own source comments the problem and offers no way out:

    # Note: SoftDeletable also defines a `.active` scope (alias of `.without_deleted`).
    # If both concerns are included on the same model, the later one wins.

**Batch verbs exist on two concerns and are missing on five.** SoftDeletable has
`soft_delete_all`/`restore_all` and Anonymizable has `anonymize_all!`, both built
on a deliberate contract (relation-respecting, Integer count, transactional,
DB-side filtering, single-UPDATE fast path). Publishable, Expirable, Activatable,
Lockable and Stateable have per-record bang methods only, so the equivalent bulk
operation is a hand-rolled `find_each` in application code with none of those
properties.

A third, smaller problem sits underneath both: the affix-name computation is
duplicated six times, and `prefix: true` ("use the field name") is honoured by
Stateable alone.

## Non-goals

- Encryptable key rotation, controller-concern polish, Rails-native bridges — the
  other three sub-projects of the wave.
- Any new concern.
- Renaming Sequenceable's or Searchable's `prefix:` (see *Naming hazard*).
- Adding affixing to concerns that generate no scopes.
- New columns, migrations, or dependencies. This release adds none of the three.

## Part 1 — `Support::Affix`

A new support module, autoloaded from `lib/concerns_on_rails.rb`, with two
methods:

```ruby
ConcernsOnRails::Support::Affix.normalize(option, default:)
# nil / false        -> nil
# true               -> default.to_s      (the configured field name)
# String / Symbol    -> option.to_s

ConcernsOnRails::Support::Affix.name(base, prefix:, suffix:)
# -> [prefix, base, suffix].compact.join("_").to_sym
```

`name` replaces six copies of the same expression: the identical private
`activatable_scope_name` / `expirable_scope_name` / `lockable_scope_name`
methods, Anonymizable's `affixed` lambda, Stateable's `stateable_method_name`,
and Storable's inline join in `storable_normalize_spec`.

`normalize` generalizes Stateable's `stateable_affix` — today Stateable is the
only concern where `prefix: true` means "use the field name"; after this change
every affixing concern accepts it. That is a pure addition: no currently valid
call changes meaning.

Each refactored call site keeps its existing public behaviour exactly; the
concerns' current specs are the regression guard for the extraction.

### Naming hazard (documented, not fixed)

`prefix:` already carries three unrelated meanings in this gem:

| Concern | `prefix:` means |
|---|---|
| Activatable, Expirable, Lockable, Stateable, Anonymizable, + the three added here | affix on generated **scope names** |
| Storable | affix on generated **accessor names** |
| Sequenceable | a literal string prepended to the **generated value** (`"INV-"`) |

Searchable additionally uses `match: :prefix` for a LIKE mode. Renaming any of
these is a breaking change with no functional gain, so the README gains a short
note distinguishing them. The design does not pretend they are uniform.

## Part 2 — affixing Publishable, SoftDeletable, Schedulable

### Strategy: additive by default, opt-in removal

Chosen over two alternatives (recorded in *Decisions* below).

1. `included do` keeps defining the default-named scopes exactly as it does
   today. A model that only includes the concern, never calling the macro, is
   completely unaffected — this is a supported and documented usage today, since
   each concern defaults its field in `included do`.
2. The scope bodies move out of `included do` into a private
   `define_<concern>_scopes(prefix, suffix)` class method — the pattern
   Expirable already uses. `included do` calls it with `nil, nil`.
3. The macro gains `prefix:`/`suffix:`. When either is present it calls
   `define_<concern>_scopes` again with the affixes, then retires the
   default-named scopes it previously defined.

### Retirement rules

At include time each concern records, in a `class_attribute` (e.g.
`publishable_default_scopes`), a name => `UnboundMethod` map: the scope names it
defined, each paired with the `singleton_class.instance_method(name)` captured
immediately after definition. A name is removed only when **all three** hold:

- it is in that recorded map (never a name the concern did not create);
- `singleton_class.instance_method(name).owner == singleton_class` — the scope is
  owned by *this* class's own singleton, not inherited; and
- the currently bound `UnboundMethod` `==` the one recorded at definition time —
  the scope is still the concern's own, not something the model redefined.

Verified mechanics (probe, 2026-08-29): `scope` defines a method on the class's
own singleton; the owner check returns `true` on the defining class and `false`
when viewed from a subclass; `remove_method` on the singleton removes the scope
from the class and its subclasses; affixed scopes chain normally afterwards.

Consequences of the three guards:

- **User override preserved.** If the model redefined `.published` itself, the
  first two conditions still hold (same name, same singleton) but the third
  fails — the bound method is no longer the one the concern recorded — so the
  override is left alone and nothing is removed.
- **Parent scopes are never removed from a subclass.** Covered by the owner
  check, which is `false` for inherited scopes.

### STI subclass raises

Calling the macro with an affix on a subclass whose parent owns the scopes raises
`ArgumentError`, naming the parent class and telling the caller to affix there.

Rationale: the alternative — skipping silently — leaves the parent's colliding
scope in place and returns an escape hatch that does not work. A teaching
`ArgumentError` matches how this gem already handles misconfiguration
(ColumnGuard's migration hints, Sortable's unknown-option and invalid-direction
raises from 1.26).

### The failure mode this must not ship

Affixing breaks any scope body that references another scope **by literal name**.
Every such reference must resolve through the stored affixed name (kept in a
`class_attribute` and invoked with `public_send`), not a hard-coded symbol:

| Concern | Reference |
|---|---|
| SoftDeletable | `default_scope { soft_delete_default_scope ? without_deleted : all }` |
| SoftDeletable | `only_deleted` delegates to `soft_deleted` |
| SoftDeletable | `deleted_within(duration)` builds on `soft_deleted` |
| Publishable | `enable_published_default_scope` calls `default_scope { published }` |
| Schedulable | `current` calls `active_at(Time.zone.now)` |

A missed reference produces a `NoMethodError` at query time, or — worse, for the
`default_scope` cases — a model whose default scope silently stops filtering.
These get dedicated specs (see *Testing*).

### Macro option validation

Sortable and Stateable raise on unknown macro options as of 1.26. `prefix:` and
`suffix:` must be added to the relevant `OPTIONS` lists, or last release's
hardening rejects the new keywords.

## Part 3 — batch operations

### The contract (already established, not invented here)

Every batch verb, matching `soft_delete_all` / `restore_all` / `anonymize_all!`:

- is a class method on `ClassMethods`, operating on `all` — it respects the
  current relation, so `Post.draft.publish_all` works;
- returns the **Integer count** of records transitioned;
- runs inside a `transaction`; a record that fails to save raises
  `ActiveRecord::RecordNotSaved` (message prefixed with the concern's label) and
  rolls the entire batch back;
- filters already-transitioned rows **DB-side**, making it idempotent — a second
  call returns 0 and issues no per-record work;
- collapses to a **single `UPDATE`** when the fast path applies;
- otherwise streams with `find_each` (memory-bounded; forward-by-PK pagination is
  safe even as updated rows leave the filtered set).

### `Support::BatchOps`

`soft_delete_batch_fast_path?` generalizes to:

```ruby
ConcernsOnRails::Support::BatchOps.fast_path?(klass, owner, *methods)
# true when every named instance method is still owned by `owner`
# (i.e. the host model overrode none of the concern's hooks or bang methods)
```

SoftDeletable is refactored onto it — keeping its extra `return false if
soft_delete_touch` guard at the call site — so the rule has one definition rather
than six. Its existing specs guard the move. Autoloaded alongside `Support::Affix`.

### Verbs

| Concern | Verb(s) | Target rows | Fast path | Notes |
|---|---|---|---|---|
| Publishable | `publish_all`, `unpublish_all` | not currently published / currently published | when `before/after_publish`, `before/after_unpublish`, `publish!`, `unpublish!` are unoverridden | branches boolean vs timestamp column, like every other Publishable scope |
| Expirable | `expire_all` | currently active | when `expire!` is unoverridden | Expirable defines no hooks, so only an overridden bang method forces the slow path |
| Activatable | `activate_all`, `deactivate_all` | inactive / active | when the bang method is unoverridden | Activatable defines no hooks; `toggle_active!`'s row lock has no batch analogue |
| Lockable | `unlock_expired` | locked rows whose `locked_at + unlock_in` has passed | when `before/after_unlock` and `unlock_access!` are unoverridden | must also reset failed attempts, mirroring `unlock_access!`; matches nothing when `unlock_in` is nil |
| Stateable | `transition_all(event)` | rows in a state the event can leave, minus rows already in the target state | **never** | the per-record path uses `update!`, which runs validations, while every fast path uses `update_all`, which does not — collapsing would silently skip them. Guard membership is still filtered DB-side; records failing `may_<event>?` are **skipped, not errors** |

### `publish_all` and scheduled rows

`publish_all` targets rows that are not currently published, which includes
*scheduled* rows — overwriting a future `published_at` with now. Because batch
verbs respect the relation, the narrow case is expressible without a special
case: `Post.draft.publish_all`. Documented in the Publishable section of the
README; not special-cased in code.

### No bangs on the new verbs

The shipped precedent is inconsistent: `soft_delete_all` and `really_destroy_all`
carry no bang, `anonymize_all!` does; the instance methods (`soft_delete!`,
`activate!`) all do. The new verbs follow the majority and take no bang.
`anonymize_all!` keeps its name — renaming it would break users — and is
documented as the irreversible-erasure exception.

## Testing

Per affixed concern (Publishable, SoftDeletable, Schedulable):

- default scope names unchanged when the macro is called with no affix;
- default scope names unchanged when the macro is never called at all;
- affixed names defined, and default names **gone**, when an affix is passed;
- `default_scope` still filters correctly under an affix (SoftDeletable,
  Publishable);
- inter-scope references resolve under an affix (`only_deleted`,
  `deleted_within`, `current`);
- a user's own redefinition of a default-named scope survives the macro;
- affixing on an STI subclass whose parent owns the scopes raises `ArgumentError`.

Integration (does not exist today, and is the scenario that motivates the whole
part): one model including SoftDeletable + Activatable + Expirable, each affixed,
asserting all scopes coexist and each returns the right rows.

Per batch verb:

- returns the Integer count;
- a failing record raises `RecordNotSaved` and rolls the batch back;
- idempotent — a second call returns 0;
- respects the relation;
- fast path issues exactly one `UPDATE` (SQL statement-count assertions, the
  style introduced in 1.26 for CounterCacheable and Sequenceable);
- slow path runs the concern's hooks once per record;
- Stateable: guarded records are skipped, and the guarded event never takes the
  fast path.

Unit specs for `Support::Affix` (including `normalize(true, default:)`) and
`Support::BatchOps`.

## Compatibility and rollout

Fully backward compatible. Passing no affix leaves every scope name, default
scope and query byte-identical; the six `Support::Affix` refactors are
behaviour-preserving; batch verbs are pure additions. No new columns, migrations,
gemspec changes or dependencies.

Ships as **1.27.0**, a minor release. Per the project release process, bump
together: `lib/concerns_on_rails/version.rb`, the `Gemfile.lock` PATH pin,
`CHANGELOG.md`, `README.md` (TOC row, concern sections, version pins) and
`docs/assets/js/concerns.js`. Then create the GitHub Release with the built
`.gem` attached — the `v*` tag triggers CI's trusted-publishing job, which pushes
to RubyGems. Never `gem push` locally.

## Decisions

**Affixing strategy — additive with opt-in removal.** Rejected: (a) moving all
scope definitions into the macro behind a deprecation runway — uniform, but fires
a deprecation at every include-only user for a collision they do not have, and
defers the clean state to 2.0; (b) additive aliases with no removal — zero risk,
but the unaffixed scope still clobbers, so the escape hatch would not work. The
chosen approach confines all new behaviour to models that opt in, and leaves the
code routed through `define_*_scopes` helpers so 2.0 can reach the uniform end
state by deleting the include-time calls.

**Raise rather than no-op on STI subclass affixing.** A no-op returns a
non-functional escape hatch; the raise names the fix.

**Document the three meanings of `prefix:` rather than unify them.** Renaming
Sequenceable's or Searchable's is breaking, for no functional gain.

## Wave context

1. **1.27 — this spec:** affixing + batch ops.
2. **1.28 — controller-side polish:** Respondable `render_collection` + RFC 8288
   Link headers + problem+json, Cacheable ETag `extras:` + auto-Vary, Filterable
   `type:`/operator coercion, Idempotentable header capture on replay,
   ErrorHandleable expanded exception map. 1.26 audited only the model concerns.
3. **1.29 — Encryptable key rotation:** multi-key registry keyed by the envelope's
   already-reserved `key_id` byte, decrypt-with-any / encrypt-with-current,
   `reencrypt_all!`, blind-index rehash.
4. **2.0 — Rails-native bridges:** Normalizable to `normalizes`, Throttleable to
   Rails 8 `rate_limit`, Tokenizable to `generates_token_for`, Stateable
   inclusion validation — cheaper after 2.0 moves the Rails floor to >= 6.1.
