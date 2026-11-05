# DATA findings — v1.33.0
(All entries were reasoned from the code and Rails 6.0–8.1 gem sources by a read-only auditor. The repros in DATA_spec.rb have NOT been run yet by the auditor. Run them before treating anything as proven.)

## Proven bugs (pending a run of DATA_spec.rb)

### DATA-1 [MEDIUM] Lockable and Tokenizable `consume_` raise ArgumentError on composite primary keys (incomplete DATA-12 fix)
- Where: lib/concerns_on_rails/models/lockable.rb:229, 264, 556, 572, 601, 635; lib/concerns_on_rails/models/tokenizable.rb:174
- What happens: on a Rails 7.1+ model keyed by `[shop_id, id]`, these calls raise ArgumentError "Expected corresponding value for [...] to be an Array":
  - `register_failed_attempt!`, after the counter was already incremented
  - `lock_access!`
  - `unlock_by_token`
  - the lapsed-lock clear
  - `consume_<token>`
- Why: they build `where(primary_key => id)`. Rails' predicate_builder.rb:93-96 rejects that for an Array key. 1.33.0 added Support::PrimaryKey.condition for exactly this case. spec/concerns/regressions/composite_primary_keys_spec.rb covers only Encryptable, Anonymizable, Locking and Duplicable. `update_counters` itself is fine, because Rails 8.1 counter_cache.rb:143 wraps a composite id.
- Repro: "DATA-1a".."DATA-1d" (`rspec DATA_spec.rb -e DATA-1`)
- Fix direction: use `ConcernsOnRails::Support::PrimaryKey.condition(klass, id)` at every listed site. For the `select` at lockable.rb:601, use `PrimaryKey.columns`. Add Lockable and Tokenizable to the composite-key regression spec.
- Affects: Rails 7.1–8.1 with composite primary keys, all adapters.

### DATA-2 [MEDIUM] A per-field `key:` Proc that returns nil falls back to the global key
- Where: lib/concerns_on_rails/encryption.rb:117-123 (`resolve_material`); callers are encryptable.rb:485 and 495, plus `blind_fingerprints` at :209
- What happens: with `encryptable :ssn, key: -> { credentials.pii_key }`, a missing credential makes the Proc return nil. The value is then encrypted under the global key and stamped key_id 0.
  - Once the field key resolves, those rows raise DecryptionError, because the per-field path always decrypts with the field key and ignores the envelope.
  - `needs_reencryption` skips per-field fields, so the rows can never be found or rotated.
  - Under `on_missing_key: :passthrough` with no global key, they are stored as plaintext.
- Why: `resolve_material` treats "field key resolved to nil/empty" the same as "no field key declared". CLAUDE.md says "missing key raises at first use".
- Repro: "DATA-2a refuses…" and "DATA-2b … stays readable"
- Fix direction: when a field declares `key:`, a nil or empty resolution should raise MissingKeyError, or follow `on_missing_key`. It should never use the global key.
- Affects: all lines and adapters.

### DATA-3 [MEDIUM] A NUL byte in a token gives a 500 on PostgreSQL instead of nil
- Where: tokenizable.rb:151-153 and 175; lockable.rb:144-147
- What happens: `authenticate_by_api_token("a\u0000b")`, `consume_`, and `unlock_by_token` with a NUL (from `?token=%00`) bind the value. The pg driver refuses NUL in a bound text parameter, so the call raises instead of answering nil. Tokenizable's own comment promises nil "like a wrong token". Filterable fixed the same class in 1.33.0 (#152, `ScalarParam.nul_free?`).
- Repro: "DATA-3" (skipped unless on PostgreSQL). Not run: PG is not available locally.
- Fix direction: return nil unless `ScalarParam.nul_free?(value)` in `tokenizable_lookup_value?` and `unlock_by_token`.
- Affects: PostgreSQL (SQLite binds NUL without error).

### DATA-4 [LOW] `register_failed_attempt!` writes on a readonly record
- Where: lockable.rb:385 and 626-629
- What happens: on a `readonly!` record without a lapsed lock, `register_failed_attempt!` still increments the counter in SQL, through the class-level `update_counters`. At the threshold, `lock_access!` then raises ReadOnlyRecord, so the row is left at `max_attempts` and unlocked. The lapsed-lock clear and `lock_access!` both check `lockable_guard_writable!`; the increment does not. CLAUDE.md says the readonly/destroyed preconditions are replicated.
- Repro: "DATA-4"
- Fix direction: call `lockable_guard_writable!` at the start of `register_failed_attempt!`.

## Suspected (unproven)

### S-1 [MEDIUM] Encryptable on a PostgreSQL `bytea` column never decrypts
- Where: encryptable.rb:60-61 (doc says "text (or binary)") and 374-381
- What happens: `attribute field, EncryptedType` replaces the column's OID::Bytea type, so nothing calls `PG::Connection.unescape_bytea`. The PG adapter registers no result decoder for bytea, so `deserialize` receives "\x4151…" and strict Base64 fails, raising DecryptionError on every read.
- Why unproven: no PG here.
- Fix direction: deserialize through the column's original cast type first, or document text only.

### S-2 [LOW] A generated value survives a create halted inside a caller's transaction
- Where: generated_values.rb:56-69
- What happens: inside `Model.transaction { rec.save }`, a later `before_create` that throws :abort after a token or number was drawn makes `save` raise Rollback in a joined transaction. Rails swallows that Rollback, so `rolledback!` never runs and Revertible never restores the column. A retried `save` reuses a value that was never inserted. For Sequenceable, another row may have taken that number meanwhile.
- Why unproven: not run; the impact is mostly on Sequenceable, which is outside this slice.

## Improvement suggestions for this slice
1. Tokenizable token fields (api keys, invite codes) are not registered in FilterParameterRegistry, unlike Lockable's unlock_token. They land in request logs and `#inspect` unless they match Rails' default `:token` filter (`invite_code` does not).
2. `ConcernsOnRails.config.audit_actor=` rejects `->(record) { … }`, but the model-level `actor:` accepts it through Support::Callable. The error text "it is instance_exec'd" is outdated.
3. Hashable `type: :hex, length: n` yields 2n characters (`SecureRandom.hex(n)`), while Tokenizable's `:hex` yields exactly n. Document this or align the two.
4. Lockable uses `Time.zone.now` throughout; that is a NoMethodError with ActiveRecord outside Rails and no zone set. Tokenizable uses `Time.current`, which is safe.
5. `RandomValue.from_alphabet` returns ASCII-8BIT strings (`String.new(capacity:)`) for ASCII alphabets. Values then carry a binary encoding into JSON, comparisons and binds (SQLite quoting converts them; other paths may not).
6. Document that `insert_all`/`upsert_all` encrypt (they use `type_for_attribute`) but leave blind indexes and Auditable entries unset, the same as `update_columns`.
7. On Rails < 7.1, `changes_applied` adds one SELECT per save per model to resync ciphertext. Worth noting in the docs (perf).
8. Auditable's doc says a create records `"from" => nil`, but a column with a DB default records the default.
9. Hashable re-declared in a subclass with a different field keeps the parent's `regenerate_<old>!`, which then regenerates the new field.

## Coordinator run results (2026-10-29, SQLite, default Gemfile = Rails 8.1)
`bundle exec rspec audit/DATA_spec.rb` → 8 examples, 7 failures, 1 pending.
- DATA-1a/1b/1c/1d: FAIL with `ArgumentError: Expected corresponding value for ["shop_id", "id"] to be an Array` at lockable.rb (pluck/update_all `where(primary_key => id)`) and tokenizable.rb (consume) → **PROVEN**.
- DATA-2a: FAIL "expected MissingKeyError but nothing was raised" → **PROVEN** (encrypts under the global key).
- DATA-2b: FAIL with `DecryptionError: could not decrypt value` once the field key appears → **PROVEN** (rows written while the field key was nil become unreadable).
- DATA-3: PENDING (PostgreSQL only; not run locally).
- DATA-4: FAIL "expected 0, got 1" → **PROVEN** (readonly record's counter incremented in SQL).
