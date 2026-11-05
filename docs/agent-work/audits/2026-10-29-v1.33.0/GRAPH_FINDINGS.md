# GRAPH findings — v1.33.0

Status: COMPLETE — 6 proven (0 CRITICAL, 0 HIGH, 4 MEDIUM, 2 LOW). All 7 examples in GRAPH_spec.rb fail on master 033981a; each failure is the bug. Run: `cd <root> && ASDF_RUBY_VERSION=3.2.2 bundle exec rspec <scratchpad>/audit/GRAPH_spec.rb`
Local stack: Rails 8.1.4, acts_as_list 1.2.6, friendly_id 5.7.0, SQLite.

## Proven bugs

### GRAPH-1 [MEDIUM] Sequenceable: after switching to `period_column:`, pre-switch rows (NULL there) format in TODAY's period, so two rows print the same number
- Where: lib/concerns_on_rails/support/sequence_calculator.rb:113,125-127,181-190 (format_sequence → period_time → base_time); models/sequenceable.rb:134-140 (`formatted_<field>`), 386-388 (`sequenceable_period_time`)
- What happens: series `prefix: "INV-", reset: :year` (no `into:`) issued INV-2025-1 (created 2025-06-01) and INV-2026-1 (created 2026-02-01). After re-declaring with `assign: :manual, period_column: :finalized_at`, the 2025 row's `formatted_sequence` reads "INV-2026-1" — identical to the real 2026 #1. `sequenceable_period_time` likewise returns "now" for those rows.
- Why: `base_time(record, column)` reads only the period column and falls back to `Time.current` when it is NULL. The MAX range was taught (SCOPE-5 review MEDIUM-2, `sequence_legacy_rows?`/`sequence_unstamped_in_period`) that NULL-stamped rows sit in their period by `created_at`, but the display/token path was not — an INCOMPLETE fix: spec/concerns/regressions/sequenceable_period_column_spec.rb "switching an existing series to a period_column" only asserts the new draft's number, never a legacy row's formatted value.
- Repro: GRAPH_spec.rb "GRAPH-1 formats a pre-switch row in its created_at period, not today's" (`rspec <file> -e GRAPH-1`). Observed: `expected ["INV-2025-1","INV-2026-1"] got ["INV-2026-1","INV-2026-1"]`.
- Fix direction: in `base_time` (persisted record, field numbered, custom period column NULL, `created_at` column present) fall back to `record.created_at` before the memo/`Time.current`, mirroring `sequence_unstamped_in_period`.
- Affects: all Rails lines/adapters; only series without `into:` (with `into:` the stored string is shown).

### GRAPH-2 [MEDIUM] CounterCacheable: a composite foreign key (Rails 7.1+) is silently never counted, and `recount_counter_caches!` emits invalid SQL
- Where: lib/concerns_on_rails/models/counter_cacheable.rb:886-888 (`counter_cacheable_fk_value` → `self[Array]`), 715-720, 767-774 (`key_column` = `association_primary_key.to_s` on an Array), 518 / 598 (`where.not(fk => nil)` / `group(fk)` with an Array fk)
- What happens: `belongs_to :gr_order, foreign_key: %i[shop_id order_id]` + `counter_cacheable_by :gr_order` is accepted at the macro; `GrItem.create!(gr_order: order)` leaves `gr_items_count` at 0 (no error). `GrItem.recount_counter_caches!` raises `SQLite3::SQLException: near ")": ... WHERE NOT (()) GROUP BY "gr_items"."shop_id", "gr_items"."order_id"`.
- Why: every path treats `reflection.foreign_key` / `association_primary_key` as one column; `self[["shop_id","order_id"]]` reads nil, so `counter_cacheable_adjustment` returns nil (fk "absent"). `where.not(["shop_id","order_id"] => nil)` builds an empty NOT. Not covered by spec/concerns/regressions/composite_primary_keys_spec.rb (#138 fixed other callers only).
- Repro: GRAPH_spec.rb "GRAPH-2a counts a child on a composite-key parent" (observed `expected: 1 got: 0`), "GRAPH-2b recounts a composite-key parent" (observed StatementInvalid above).
- Fix direction: either refuse a composite `foreign_key` at the macro (ArgumentError, like polymorphic), or read/compare the fk as a tuple (`Array(fk).map { self[_1] }`, `PrimaryKey`-style condition hash for the UPDATE, `where.not` per column, `group(*fk)`).
- Affects: Rails 7.1+ (composite keys).

### GRAPH-3 [LOW] Sortable (model) `reposition!` crashes on a composite primary key
- Where: lib/concerns_on_rails/models/sortable.rb:137-139 (`Arel::Nodes::Case.new(arel_table[primary_key])`, `where(primary_key => ordered)`), 181-184 (`type_for_attribute(primary_key)`)
- What happens: `use_acts_as_list: false` model keyed `[shop_id, id]`; `reposition!([b.id, a.id])` raises `TypeError: can't quote Array`.
- Why: single-column PK assumed; not routed through Support::PrimaryKey.
- Repro: GRAPH_spec.rb "GRAPH-3 repositions rows".
- Fix direction: refuse composite keys with a clear ArgumentError, or build the CASE over a tuple / one UPDATE per row via `PrimaryKey.condition`.
- Affects: Rails 7.1+.

### GRAPH-4 [LOW] legacy_aliases: concurrent first reference prints "already initialized constant" (comment claims idempotent)
- Where: lib/concerns_on_rails/legacy_aliases.rb:20-26
- What happens: two threads that both miss `ConcernsOnRails::Maskable` both call `const_set` → Ruby warns "already initialized constant ConcernsOnRails::Maskable / previous definition was here". Simulated by calling `const_missing` twice.
- Why: `const_set` is unconditional; no `const_defined?(name, false)` re-check / mutex.
- Repro: GRAPH_spec.rb "GRAPH-4 does not warn ...".
- Fix direction: `return const_get(name, false) if const_defined?(name, false)` before `const_set` (or a Mutex).

### GRAPH-5 [MEDIUM] Sluggable: moving a record to another `scope:` keeps a slug that another record's friendly_id HISTORY holds there → RecordNotUnique on save
- Where: lib/concerns_on_rails/models/sluggable.rb:348-363 (`sluggable_scope_changed?` → `sluggable_slug_taken_in_scope?` checks only the live slug column)
- What happens: `sluggable_by :title, history: true, scope: :account_id`. B (account 2) was "foo", renamed to "bar" (history keeps "foo"/account_id:2). A ("foo", account 1) `update!(account_id: 2)` raises `ActiveRecord::RecordNotUnique: UNIQUE constraint failed: friendly_id_slugs.slug, friendly_id_slugs.sluggable_type, friendly_id_slugs.scope`. Without the unique index the move succeeds and B's old URL in account 2 silently resolves to A.
- Why: the override replaced friendly_id's `:scoped` rule (regenerate on any scope change, through a generator whose scope joins the history table) with "rebuild only if the new scope's LIVE slug column already holds it". friendly_id History's after_save `create_slug` then inserts (foo, GrPage, "account_id:2"), which B's history row already owns. The 1.33.0 scope-move fix (#157 neighbourhood, sluggable_multi_column_scope_spec / sluggable spec) never exercises `history:` together with `scope:`.
- Repro: GRAPH_spec.rb "GRAPH-5 moves a record into a scope where another record's history holds its slug" (`-e GRAPH-5`).
- Fix direction: when `config.uses?(:history)`, also treat the slug as taken if `FriendlyId::Slug.where(slug:, sluggable_type: base_class.to_s, scope: serialized_scope).where.not(sluggable_id: id)` exists (or reuse friendly_id's `scope_for_slug_generator.exists_by_friendly_id?`).
- Affects: all lines; `history: true` + `scope:` only.

### GRAPH-6 [MEDIUM] Duplicable: a child the loaded association has `marked_for_destruction?` is copied as a live child
- Where: lib/concerns_on_rails/models/duplicable.rb:269-306 (`duplicable_source_records` returns `association.target` / merges loaded records by id; `duplicable_live` filters only the soft-delete column)
- What happens: "save as copy" flow — `list.assign_attributes(gr_entries_attributes: [{ id: x, _destroy: "1" }])` then `list.duplicate!`: the copy carries the entry the user just removed ("keep","drop" instead of "keep").
- Why: the module promises "an already-loaded association keeps its in-memory edits", but the `_destroy` mark (nested attributes / `mark_for_destruction`) is the one in-memory edit ignored; the target still contains the record.
- Repro: GRAPH_spec.rb "GRAPH-6 leaves out a child marked _destroy ..." (`-e GRAPH-6`). Observed `expected ["keep"] got ["keep", "drop"]`.
- Same gap for a loaded has_one whose target is marked for destruction (same code path, not separately run).
- Fix direction: reject `record.marked_for_destruction?` in `duplicable_live` (loaded targets) and in `duplicable_merge_loaded` (drop the row whose loaded twin is marked); same for a has_one target.
- Affects: all lines.

## Suspected (unproven)
(none open)

## Improvement suggestions
- (ranked) CounterCacheable / Sortable#reposition! / Sluggable scope-taken check should go through Support::PrimaryKey or refuse composite keys at the macro — GRAPH-2/3 show the composite-key sweep of #138 stopped short of this slice. (Sluggable's `where.not(primary_key => id)` at sluggable.rb:362 has the same shape, but friendly_id's own slug generator already fails on composite keys, so it is not a separate finding.)
- Duplicable: listing an Aliasable alias AND its source in `associations:` copies every child twice (both names resolve to one association); dedupe by `reflect_on_association(name)` source or raise at the macro.
- Sequenceable `template:` is called with exactly `(seq, record)`; a one-argument lambda raises ArgumentError at format time. Use `Support::Callable.invoke`-style arity dispatch like the other callable options.
- Sortable `reposition!` called on the CLASS of a `scope:`d list renumbers every list into one global run (order kept, positions no longer 1-based per list); consider refusing when `sortable_scope_columns` is non-empty and the relation does not constrain them.
- Schedulable `schedulable_by` assigns the class attributes BEFORE raising (both nil / missing column), unlike Sluggable's "validate before assigning" rule.
- ColumnGuard migration hint camelizes a schema-qualified table name ("reporting.users" → "Reporting.users"), which is not a valid migration class name.

## Checked and found OK (no finding)
- Rails 6.0 branch of AssociationScope (`Arel.fetch_attribute` in 6.0 handles only Equality/NotEqual/comparison/In/Between): every gem hiding predicate on 6.0 is one of those (SoftDeletable's `DefaultScopePredicate < Equality`, Publishable's `<> FALSE` / `lteq`), so the by-node peel works there. Reasoned from activerecord-6.0.6.1/lib/arel.rb:49, not run.
- `touch_attributes_with_time`, `Relation#update_counters` and `destroy_row` (CounterCacheable) all exist on 6.0.6.1.
- Aliasable: query side, nested attributes, counter_cache, deprecated:, alias_foreign_key: — the existing spec covers the matrix; no new defect found.
- acts_as_list callbacks are Symbol filters, so a re-declared `sortable_by` does not stack them.
- Duplicable resets created_on/updated_on (Rails' own initialize_dup clears every timestamp).
- CounterCacheable MirrorUndo: rolled-back savepoint, joinable:false outer rollback, released savepoint + commit all leave the parent saveable.
- Sequenceable create-time "now" memo does not leak into a later manual assignment (created_at is stamped by Timestamp before before_create).
- Schedulable predicates accept String/Date like the scopes.
- Every lib file is reachable through the autoload loader.
