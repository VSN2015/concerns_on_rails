# STATE findings — v1.33.0

All repros live in `STATE_spec.rb` (same directory). Run one with:
`cd <root> && ASDF_RUBY_VERSION=3.2.2 bundle exec rspec <scratchpad>/audit/STATE_spec.rb -e "<example name>"`
Run locally on Rails 8.1.4 / SQLite. Each example asserts the CORRECT behaviour, so a failure is the bug.

Summary: 12 proven bugs. 0 CRITICAL, 2 HIGH (STATE-1, STATE-11), 5 MEDIUM (STATE-2, 3, 4, 5, 12), 5 LOW (STATE-6, 7, 8, 9, 10).
Full run of STATE_spec.rb: 24 examples, 18 failures. Every failure maps to a finding below. The 6 passing examples are
probes that confirmed correct behaviour: a vetoed publish! with lock_version (outside and inside a caller txn), forced-change
restore after a veto, a new-record veto outside a transaction, toggle_active! with unsaved changes, and the composite-key
relation destroy_all/purge.

## Proven bugs

### STATE-1 [HIGH] Expirable#time_until_expiry raises TypeError on a `date` expiry column with a future date
- Where: lib/concerns_on_rails/models/expirable.rb:240-248
- What happens: `token.time_until_expiry` on `expirable_by :expires_on` (a `date` column) with a future date raises `TypeError: expected numeric`. 1.33.0 explicitly supports `date` columns (README line 830, date_column_predicates_spec), so this crashes in a configuration the gem supports.
- Why (root cause): `(value - now)` computes `Date - ActiveSupport::TimeWithZone`. The past/today branch only works because `Date#<=>` coerces. This method never goes through `TimeValue.predicate_bound`, unlike the predicates fixed in 1.33.0, so it is an INCOMPLETE fix: date_column_predicates_spec covers `expired?` but not `time_until_expiry`.
- Repro: "time_until_expiry answers a Duration for a future date (does not crash)". Observed: `TypeError: expected numeric` at expirable.rb:247.
- Fix direction: on a date column, convert the value to the zone's start of day (`value.in_time_zone`) or to the end of the expiry day before subtracting. Also compare the value against `predicate_bound`, so it agrees with `expired?`.

### STATE-2 [MEDIUM] Expirable#expire! on a `date` column skips before_expire/after_expire when the process TZ is behind Time.zone
- Where: lib/concerns_on_rails/models/expirable.rb:269-270 (`time.to_time > Time.zone.now`)
- What happens: Setup is `ENV["TZ"]="America/Los_Angeles"`, `Time.zone="UTC"`, and the clock at 01:00 UTC. `token.expire!` writes today's date, and the record is `expired?` afterwards, but neither hook fires. It is treated as a future "schedule". Any `after_expire { revoke_access! }` silently does not run for several hours of every day.
- Why: `Date#to_time` gives midnight in the PROCESS zone (ENV TZ), not in Time.zone. CLAUDE.md says ENV["TZ"] must never decide anything. Today's date then reads as later than now whenever the system zone is behind the app zone. The same check also mis-decides `expire_in!` on a date column.
- Repro: "expire! (now) fires the expire hooks whatever the process TZ (ENV['TZ'] behind Time.zone)". Observed: `expected [:after_expire], got nil` (while `expired?` is true).
- Fix direction: decide "future" with the same check the predicate uses: `time > TimeValue.predicate_bound(klass, field, Time.zone.now)`. Equivalently, the hooks fire whenever the written value makes `expirable_expired?` true.

### STATE-3 [MEDIUM] SoftDeletable#really_delete! and #is_really_deleted? crash on a composite primary key (Rails 7.1+)
- Where: lib/concerns_on_rails/models/soft_deletable.rb:463 (`where(self.class.primary_key => id)`) and :479 (`exists?(id)`)
- What happens: On a model with `primary_key = %i[shop_id id]`, `order.really_delete!` raises `ArgumentError: Expected corresponding value for ["shop_id", "id"] to be an Array`. `order.is_really_deleted?` raises `ArgumentError: Unsupported argument type: 1 (Integer)`. Other paths work: soft_delete!/restore!, relation destroy_all, and the only_deleted purge.
- Why: these are the exact `where(primary_key => id)` and `exists?(id)` forms that Support::PrimaryKey was written to replace (#138). The 1.33.0 really_delete! fix (soft_deletable_really_delete_spec) touched this method but kept the old condition, so it is an incomplete fix of #138 / STATE-3.
- Repro: "really_delete! hard-deletes the row". Also "soft_delete!/restore!/is_really_deleted? work", which fails at is_really_deleted?.
- Fix direction: use `where(Support::PrimaryKey.condition(self.class, id))` in both methods. `is_really_deleted?` then becomes `!...where(condition).exists?`.
- Affects: Rails 7.1+ composite keys only.

### STATE-4 [MEDIUM] Association `destroy_all` leaves the association cache claiming "loaded, empty" when the soft-deleted rows are still members
- Where: lib/concerns_on_rails/support/contextual_destroy.rb:256-266 (`delete_or_destroy(...).tap { reset; loaded! }`). The same applies to Rails' `remove_records`, which runs `@target -= records`.
- What happens: Two cases fail. (a) On a `default_scope: false` model, `post.comments.destroy_all` soft-deletes 2 comments that are still members of `post.comments`, yet `post.comments.to_a` returns []. A fresh `Post.find(id).comments` returns 2. (b) On a `has_many :all_comments, -> { with_deleted }` association, `post.all_comments.destroy_all` soft-deletes the live row, which stays in `with_deleted`, yet the cached association reads []. Anything that later renders, counts (`size`), or saves through the stale proxy sees the wrong membership.
- Why: this copies ActiveRecord's post-destroy bookkeeping, `reset; loaded!` (the target is gone), but after a SOFT delete the rows remain whenever the association's scope does not hide the trash.
- Repro: "default_scope: false — the loaded association still lists the soft-deleted rows" fails with `expected: 2, got: 0`. "a with_deleted association — live rows soft-deleted stay in it" fails with `expected: 1, got: 0`.
- Fix direction: after the soft path, `reset` without `loaded!`, so the next read reloads. Alternatively keep only the records that are not still matched by the association scope (the purged ones and, under a hiding default scope, the soft-deleted ones).

### STATE-5 [MEDIUM] Publishable#unpublish! is not idempotent: re-fires before/after_unpublish on a draft or an already-unpublished record (incomplete #146 / STATE-6)
- Where: lib/concerns_on_rails/models/publishable.rb:315-317
- What happens: `post.unpublish!` on a draft (published_at NULL), or a second `unpublish!`, rewrites NULL and fires both hooks again. A "your post was taken down" notification is sent twice on a double submit. `unpublish_all` skips those rows, so the per-record verb and the batch verb disagree.
- Why: 1.33.0 (#146, regression publishable_activatable_idempotent_verbs_spec) made publish!/activate!/deactivate! no-ops in the target state but left unpublish! out. restore! is already idempotent.
- Repro: "is a no-op (no hooks), like publish!/activate!/deactivate!/restore!". Observed: `got: [:after_unpublish]`.
- Fix direction: mirror `publish!`. If the record is stored, the column has no unsaved change, and `!publishable_published? && !scheduled?` holds, then `has_changes_to_save? ? save : true`. A scheduled row must still be cleared.

### STATE-6 [LOW] Stateable: an event named `transition` makes `transition!` always raise ArgumentError
- Where: lib/concerns_on_rails/models/stateable.rb:689/691 (`stateable_event_hook(:"before_#{name}")`) and :697-699
- What happens: `transitions: { transition: {...} }` passes the collision guard, which does not check for it. Every `post.transition!` then raises `wrong number of arguments (given 0, expected 3)`, because the per-event hook `before_transition` resolves to the generic 3-arg `before_transition(event, from, to)`.
- Why: per-event hook names are not checked against the generic hooks. Likewise an event named `transition` with a suffix/prefix producing `before_transition` / `after_transition`.
- Repro: "fires transition! without an ArgumentError from the generic hook".
- Fix direction: refuse at macro time an event whose affixed name is `transition`, or skip the per-event hook when its name is the generic one.

### STATE-7 [LOW] Batch verbs and relation `destroy_all` crash on a relation with a partial `select` (per-record path only)
- Where: lib/concerns_on_rails/support/batch_ops.rb:189 (find_each keeps the relation's select) and lib/concerns_on_rails/support/contextual_destroy.rb:208. They surface in publishable.rb:395 and soft_deletable.rb:470.
- What happens: `Comment.select(:id).where(...).destroy_all` raises `MissingAttributeError: missing attribute 'deleted_at'`. ActiveRecord's own Relation#destroy_all works with `select(:id)`. `Post.select(:id, :title).publish_all` raises the same on the per-record path (model with a validator), while the fast path (no validator) succeeds. So the result depends on whether an unrelated validator exists.
- Why: each_record/find_each instantiates with the caller's select, and the verbs read the concern's column.
- Repro: "soft-deletes like Relation#destroy_all destroys" and "publish_all works as its fast path does".
- Fix direction: in each_record (or in BatchOps.run), `unscope(:select)` before loading. Records are reloaded by PK anyway.

### STATE-8 [LOW] Stateable#transition_all raises RecordInvalid, not the batch contract's RecordNotSaved, on a validation failure
- Where: lib/concerns_on_rails/models/stateable.rb:690 (`update!` inside the per-record path) and :193
- What happens: When a record fails validation during `transition_all`, `ActiveRecord::RecordInvalid` escapes. A caller following the documented `*_all` contract ("a failing record raises RecordNotSaved and rolls the batch back", BatchOps header) with `rescue ActiveRecord::RecordNotSaved` does not catch it. The rollback itself does happen.
- Repro: "raises RecordNotSaved (the batch contract) and rolls back". Observed: `RecordInvalid: Validation failed: Title can't be blank`.
- Fix direction: in stateable_batch_judge, rescue RecordInvalid and return false (BatchOps then raises RecordNotSaved with the record), or document the exception.

### STATE-11 [HIGH] HookedWrite: a vetoed verb on a NEW record inside a caller's transaction leaves it "persisted" with id nil, and the next save silently writes nothing (data loss)
- Where: lib/concerns_on_rails/support/hooked_write.rb:71-76 (`identity_snapshot` returns nil unless `record.persisted?`) and :78-90
- What happens: Inside `Model.transaction`, `post = Model.new(title: "a"); post.publish!` runs and an after_publish vetoes with ActiveRecord::Rollback. publish! returns false and the attributes are restored (id nil), but `post.new_record?` is now FALSE. A following `post.save`/`save!` issues `UPDATE ... WHERE id IS NULL` and returns TRUE, and no row ever exists. A retried `post.publish!` instead raises StaleObjectError when there is a lock_version column. The bug does not occur outside a caller transaction. It affects every HookedWrite verb that can run on a new record: publish!/unpublish!/publish_at!, activate!/deactivate!/toggle_active!, expire!/expire_in!, Stateable `<event>!`, and soft_delete!.
- Why (root cause): the INSERT ran inside HookedWrite's savepoint. Rolling back a savepoint does not restore `@new_record` on Rails 8.1, because the record's transaction state is only restored at level <= 1 / a full rollback. HookedWrite then puts the AttributeSet back (id nil) but snapshots and restores identity only for records that were persisted BEFORE the write. The module promises "the record's identity [is] put back" on any abort, but only implements the 6.0 duplicate-INSERT half.
- Repro: "is still a new record after the veto, so a later save! INSERTs it" fails with `expected new_record? to be truthy, got false`. "save! after the veto either INSERTs or fails, never reports a phantom success" fails with `got: [true, 0]`; the SQL log shows `UPDATE "st_articles" SET "title" = ? WHERE "st_articles"."id" IS NULL`. "the same inside a caller transaction" fails with StaleObjectError on a lock_version table.
- Fix direction: always snapshot `@new_record`, `@destroyed` and `@previously_new_record`, new records included, and restore them on abort. For a record that was new, also clear `@primary_key` changes.
- Affects: verified on Rails 8.1. On 6.0 the `sync_with_transaction_state` path differs (reasoned, not run).

### STATE-12 [MEDIUM] SoftDeletable soft_delete!/restore! decide "already done" from the UNSAVED in-memory stamp, so they return true while writing nothing (incomplete #146 "saved state" rule)
- Where: lib/concerns_on_rails/models/soft_deletable.rb:435 (`return true if deleted?`) and :447 (`return true unless deleted?`), with `deleted?` at :469-471
- What happens: `c.deleted_at = Time.current; c.soft_delete!` returns true, but the row stays LIVE: no write, no hooks, no cascade. In the reverse case, `c.deleted_at = nil; c.restore!` returns true while the row stays trashed and its cascade children stay trashed. This happens when a form or `assign_attributes(params)` touches the stamp before the verb runs, or when a vetoed write's state leaks. The caller is told the delete or restore happened.
- Why: 1.33.0 (#146) moved publish!/activate!/deactivate! (and expire!, #141) to the SAVED state: "a stored record, no unsaved change to the column". SoftDeletable's guards still read the in-memory attribute.
- Repro: "soft_delete! on a record whose stamp was assigned but not saved really soft-deletes it" fails with `expected: not nil, got: nil`. "restore! on a record whose stamp was cleared but not saved really restores it" fails because the stamp is still set.
- Fix direction: guard on the saved state, e.g. `!new_record? && !will_save_change_to_attribute?(field) && deleted?`. If not settled, write. If settled, save other pending changes, as the sibling verbs do.

### STATE-9 [LOW] Anonymizable: the write result is ignored, so `anonymize_all!` counts (and `anonymize_record!` reports) a row its UPDATE never reached
- Where: lib/concerns_on_rails/models/anonymizable.rb:387-391 (the block returns `true` regardless of `anonymizable_write!`) and :416-432 (`update_columns`/`update_all` both return whether a row was written)
- What happens: The row is deleted (or, under optimistic locking, the instance is otherwise unwritable) between load and UPDATE. `anonymize_all!` still counts it, even though the documented count is "records actually erased". `anonymize!` reaches `reload` and raises RecordNotFound instead of returning false. The after_anonymize hook also fires for an erasure that did not happen.
- Repro: "anonymize_all! does not count a row its UPDATE never reached". A before_anonymize hook deletes the row. Observed: `expected: 0, got: 1`.
- Fix direction: `next false unless anonymizable_write!(...)` inside the HookedWrite block. UniqueRetry already returns the block value.

### STATE-10 [LOW] Expirable#expire_in!(nil) raises TypeError instead of the concern's ArgumentError
- Where: lib/concerns_on_rails/models/expirable.rb:203-209
- What happens: `token.expire_in!(params[:ttl])` with the param absent raises `TypeError: can't convert NilClass into an exact number` from `Time.zone.now + nil`. The guard meant to produce the concern's ArgumentError accepts nil, because `nil.respond_to?(:to_i)` is true.
- Repro: "raises the concern's ArgumentError for nil, as for a String".
- Fix direction: accept only `ActiveSupport::Duration` or `Numeric` (`duration.is_a?(ActiveSupport::Duration) || duration.is_a?(Numeric)`).

## Suspected (unproven)
### STATE-S1 [MEDIUM] HookedWrite new-record identity on Rails 6.0/6.1/7.x
- Where: lib/concerns_on_rails/support/hooked_write.rb:71-90 and :153
- Why unproven: only Rails 8.1 is installed. STATE-11's mechanism (a savepoint rollback not restoring `@new_record`) depends on each line's `restore_transaction_record_state` level rule, and 6.0 adds the lazy `sync_with_transaction_state`. The STATE-11 repro should be run on the CI matrix.

## Improvement suggestions for this slice
- `Support::ContextualDestroy.hard?` (contextual_destroy.rb:130) is dead code: nothing calls it. Remove it or use it.
- `Expirable#expire_in!` / `expire!` on a `date` column truncate to the day: `expire_in!(1.hour)` writes today, which reads as expired immediately. Document it, or round up to the next day for a positive duration.
- Stateable's per-event hooks (`before_<event>`) are not collision-checked at macro time against existing instance methods (see STATE-6). A general check would catch other clashes.
- Re-declaring an affixing macro with a DIFFERENT prefix on the same class (`soft_deletable_by prefix: :trash` then `prefix: :bin`, the same for Publishable/Activatable/Expirable) leaves the first affixed scopes defined. Retire only covers the include-time captured names. The scopes are harmless but stale, and they still count for nothing in refuse_sibling_names!.
- `publish_at!(future)` and `publish_at!(nil)` fire before/after_publish (documented, README:499), while Expirable deliberately fires no hook for a future time (scheduling is not expiring). An `after_publish { notify_subscribers }` therefore fires on a schedule and on an unpublish-by-blank-param. Consider firing the publish hooks only when the written value makes the record published, or adding separate schedule hooks.
- SimpleCov in spec_helper always writes `coverage/` inside the repo, even for a single-file run. An env opt-out (`COVERAGE=0`) would help audits and parallel agents.
