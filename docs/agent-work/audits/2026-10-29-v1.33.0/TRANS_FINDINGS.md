# TRANS findings — v1.33.0

> Status: traced from the code by a read-only reviewer; repros in TRANS_spec.rb were run by the coordinator (see the run results at the end).

## Proven bugs

### TRANS-1 [HIGH] Storable stores a JSON string scalar, not an object, on a PG `jsonb` column or an `attribute :x, :json` column; `where_<key>` is broken there
- Where: lib/concerns_on_rails/models/storable.rb:451-460 (`storable_detect_native_hash`). Compare lib/concerns_on_rails/models/auditable.rb:235-246.
- What happens: native detection only accepts `columns_hash[name].type == :json` or a Serialized type.
  - A PG `jsonb` column has type `:jsonb`. An `attribute :settings, :json` over a text column has type `:text`. Both get `JSON.generate(hash)` assigned.
  - ActiveRecord's Json type casts that String as `deserialize(serialize(str))`, keeps it as a String, and stores the JSON *string* `"{\"theme\":\"dark\"}"`.
  - Reads still round-trip, because the decoder parses the String.
  - `where_theme("dark")` returns nothing, since `->>` / `json_extract` on a string scalar is NULL. `where_theme(nil)` returns every row (fails open).
  - Writing one key to an existing jsonb object row rewrites that row as a string scalar, which breaks any other SQL or jsonb consumer.
- Why: the jsonb case is missing. Auditable got exactly this fix in e098675 ("assigning the generated String stored a JSON string scalar"), and its comment claims it uses "the same detection Models::Storable uses". It does not. `storable_json_expression` (line 266) does know about `:jsonb`.
- Repro: `rspec TRANS_spec.rb -e "TRANS-1"` (SQLite via `attribute :settings, :json`). The jsonb path is reasoned, not run: PG `OID::Jsonb#type` is `:jsonb`, and the existing spec only covers `t.json`.
- Fix direction: treat the column as native when `type_for_attribute(name).type` is in `%i[json jsonb]`, or the type is an `ActiveRecord::Type::Json`, or it is Serialized. Share one helper with Auditable.
- Affects: PostgreSQL jsonb (the usual PG choice); any adapter with an `attribute :x, :json` override.

### TRANS-2 [HIGH] Normalizable's settle step re-normalizes Sanitizable `on: :write` output, so the stored value differs from the validated one, can be corrupted, or can contain markup
- Where: lib/concerns_on_rails/models/normalizable.rb:264-273 (`normalizable_settle`), run last by support/transform_backstop.rb:62-66. Sibling: models/sanitizable.rb:324-332.
- What happens (Normalizable included before Sanitizable on the same column, validated save):
  - Validation sees `S(N(x))`. At before_save, settle compares the value with what *Normalizable* produced (`N(x)`), sees a difference, and stores `N(S(N(x)))`.
  - `normalizable :title, with: :titleize` + `sanitizable :title, with: :strip, on: :write`, with input "a < b": validation sees "A &lt; B", but "A &Lt; B" is stored. `&Lt;` is the HTML5 entity ≪, and `sanitize_all!` later "repairs" it to a literal ≪.
  - With an entity-decoding rule (`->(v) { CGI.unescapeHTML(v) }`), the input `&amp;lt;img src=x onerror=alert(1)&amp;gt;<b></b>` is stored as `<img src=x onerror=alert(1)>`. That is live markup in a column whose contract is "can never become markup, even when rendered with raw".
  - Validations (format, uniqueness, NOT NULL vs `:nullify_blank`) run on a value that is not the one stored.
- Why: this is the documented "Normalizable gets the last word" design. normalizable_backstop_order_spec.rb:85-126 and normalizable_valid_then_save_spec.rb:98-153 compute their expected `plain` value through the same path, so they enshrine "Tom &Amp; Jerry" rather than catch it. The 1.33.0 fix only made the different save paths agree; it did not stop the corruption. It is also a conflict between CLAUDE.md's Sanitizable `:strip` contract and Normalizable's settle contract; I think the settle side is wrong.
- Repro: `rspec TRANS_spec.rb -e "TRANS-2"`.
- Fix direction: when a later TransformBackstop sibling rewrote the field, settle should compare against the after_validation snapshot, as the repeat-validation pass already does. Re-normalize only fields changed by non-transform code (e.g. a friendly_id slug). Alternatively, make Sanitizable's writer the final step of the dispatcher.

### TRANS-3 [MEDIUM] A save halted or rolled back after the before_save dispatcher, then retried on the same record, re-applies non-idempotent Normalizable / Sanitizable rules
- Where: models/normalizable.rb:264-266 and models/sanitizable.rb:324-326. Both clear their per-save record inside the dispatcher, before the save is known to succeed.
- What happens: after a failed *validation*, the record is kept and a re-save does not re-run the Proc (regression-tested). After a halt (a later `before_save` throws `:abort`) or a DB rollback (RecordNotUnique on INSERT/UPDATE), the record is already gone, while the attribute still holds the transformed value. The retry transforms it again: "Tom & Jerry" becomes "Tom &amp;amp; Jerry", and "a" becomes "a!!".
  - The gem itself supports retrying `save!` on the same record: GeneratedValues/Revertible, Sequenceable `assign_<field>!` with UniqueRetry, and Hashable/Tokenizable `regenerate_*!` retrying `update!` with pending changes.
  - This breaks the CLAUDE.md promise that "a Proc runs once per save".
- Repro: `rspec TRANS_spec.rb -e "TRANS-3"`. The control example is expected to pass.
- Fix direction: clear the records in `after_save`, or keep them on rollback. Even simpler: leave the record in place and let the next before_validation's `previous`/`validated` comparison decide, as it already does after a failed validation.

### TRANS-4 [LOW] Taggable with a multi-character delimiter mis-splits a tag that ends or starts with part of the delimiter
- Where: models/taggable.rb:79-81 (macro accepts any non-empty delimiter) and :190-196 (split/join).
- What happens: with `delimiter: "--"`, `tag_list = ["a-", "b"]` joins to "a---b", and `split("--")` gives `["a", "-b"]`. `tagged_with("a-")` never matches. The docs only promise that a tag cannot *contain* the delimiter, and "a-" does not.
- Repro: `rspec TRANS_spec.rb -e "TRANS-4"`.
- Fix direction: at the macro, refuse delimiters whose prefix can be a tag's suffix (or the reverse). Or, when cleaning, reject or split tags that end with a proper prefix of the delimiter or start with a proper suffix of it. Delimiters padded with whitespace (", ", " | ") are safe because tags are stripped.

## Suspected (unproven)

### S-1 [LOW] Searchable `ranked:` relation chained with `.distinct` / `.group` afterwards
- Where: models/searchable.rb:155-159.
- `Article.search(q, ranked: true).distinct` keeps `ORDER BY CASE …`. PG raises "for SELECT DISTINCT, ORDER BY expressions must appear in select list", and MySQL raises under ONLY_FULL_GROUP_BY. The guard only checks the relation at search time.
- Why unproven: needs PG or MySQL. Fix: document "chain distinct/group before search", or apply the rank lazily.

### S-2 [LOW] Taggable docs: "case-INsensitively on every adapter"
- Where: models/taggable.rb:33-37.
- Arel's MySQL visitor ignores `case_sensitive: false`. On a `_bin`/`_cs` collation column, `tagged_with("Ruby")` misses "ruby". Filterable's docs already state this exception.
- Why unproven: MySQL only.

### S-3 [LOW] Monetizable lets "oversized" input reach the column
- Where: support/money.rb:113-148.
- `MAX_EXPONENT = 24` lets e.g. `price = "1e18"` through as 1e20 cents. Saving then raises `ActiveModel::RangeError` (a 500) instead of the setter casting it to nil, as CLAUDE.md promises for "oversized input". A 4-byte `integer` cents column overflows at about $21.4M.
- Why unproven: not run. Fix: clamp against the attribute type's range, or add a validation.

### S-4 [LOW] Possibly quadratic edge-whitespace regexes
- Where: `EDGE_SPACE = /\A[[:space:]\0]+|[[:space:]\0]+\z/` (normalizable.rb:47, taggable.rb:62, searchable.rb:50) and `TRAILING_COMMENTS` (time_value.rb:57).
- On `"a" + " " * N + "b"`, every start position inside the run re-scans the run to fail `\z`, which is O(N²) unless Ruby 3.2's match cache spans gsub's start positions.
- Why unproven: needs a timing probe, e.g. `Benchmark.realtime { ("a" + " " * 200_000 + "b").gsub(ConcernsOnRails::Models::Normalizable::EDGE_SPACE, "") }`. This is reachable from `Model.search(params[:q])` and Normalizable `:strip`/`:email`.

## Improvement suggestions for this slice
1. Use one "native JSON column?" helper for Storable and Auditable (see TRANS-1), and add a PG `jsonb` example to storable_spec.
2. CLAUDE.md fixes. Normalizable's "settle" sentence should say that it also rewrites a sibling Sanitizable's output (TRANS-2), and "Proc runs once per save" should say "per successful save" until TRANS-3 is fixed.
3. Addressable: the default `required:` includes `:country`, so `default_country:` never satisfies presence and only matters when `country` isn't required. Document this, or let the default count as present. `validate_country_code` only flags 2-letter values, so "USA" or "Atlantis" pass silently when `normalize_country: false`.
4. Normalizable `:phone` drops a leading "+" and merges an extension's digits into the number ("555-1234 x56" becomes "555123456"). Consider an E.164-preserving preset.
5. Searchable / Taggable / Storable `where_*`: no NUL-byte policy, unlike Filterable's fail-closed `ScalarParam.nul_free?` (libpq truncates at NUL). Align them.
6. Monetizable: `subunit_to_unit: 2.5` is silently truncated to 2 (`.to_i`); raise instead. A money name that shadows an existing column reader (`monetizable :price_cents` on a table that also has `price`) is overwritten without warning.
7. Masker `:phone`/`:credit_card` with 5–8 digits reveals 4 of them (50–80% of the value). Consider requiring at least 8 digits before revealing the last 4.
8. Storable `where_<key>` ignores virtual defaults: an unset key with `default: "light"` matches `where_theme(nil)`, not `where_theme("light")`. Worth a doc line next to the nil-vs-unset note.

## Coordinator run results (2026-10-29, SQLite, default Gemfile = Rails 8.1)
`bundle exec rspec audit/TRANS_spec.rb` → 11 examples, 10 failures (the control example passed).
- TRANS-1 (4 examples): FAIL — raw column holds the JSON string `"{\"theme\":\"dark\"}"`, `read_attribute` is a String, `where_theme("dark")` → [], `where_theme(nil)` → the row → **PROVEN** (via `attribute :settings, :json`; PG jsonb reasoned).
- TRANS-2: FAIL — stored "A &Lt; B" (validated "A &lt; B"); stored `<img src=x onerror=alert(1)>` in a `:strip on: :write` column → **PROVEN**.
- TRANS-3 (3 examples): FAIL — "a!!", "Tom &amp;amp; Jerry", "a&amp;amp;b" after a halted/rolled-back save retried → **PROVEN**; control (failed validation) PASSED as expected.
- TRANS-4: FAIL — `["a-", "b"]` reads back as `["a", "-b"]` → **PROVEN**.
