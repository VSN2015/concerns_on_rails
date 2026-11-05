# PARAMS findings — v1.33.0

Slice: controllers/filterable.rb, support/numeric_operand.rb, support/scalar_param.rb, controllers/paginatable.rb,
controllers/cursor_paginatable.rb, controllers/sortable.rb (controller), controllers/includable.rb,
support/include_tree.rb, support/link_header.rb. Local env: Rails 8.1.4, SQLite, Ruby 3.2.2.

Evidence status: each "Proven" finding was seen in an exploratory probe run (rspec, SQLite, Rails 8.1.4)
by the reviewer; the observed output is quoted. The matching example in PARAMS_spec.rb is a
cleaned-up rewrite of that probe, run by the coordinator (see the run results at the end). Suspected items are reasoned, not run.

## Proven bugs

### PARAMS-1 [MEDIUM] Filterable on an `encryptable` column: `not`/`not_in` return the excluded row; equality/in/contains silently match nothing
- Where: lib/concerns_on_rails/controllers/filterable.rb:458-465 (apply_filter_equality), :477-479 (filterable_where), :616-627 (apply_filter_like); no Encryptable awareness anywhere in the file.
- What happens: model with `encryptable :ssn` and rows {match: "123"}, {other: "999"}. A controller has `filter_by :ssn, operators: true`. `?ssn_not=123` returns BOTH rows, including the one whose ssn is 123 (observed: `ssn_not: ["a"]` where "a" is the 123 row). `?ssn=123`, `?ssn_in=123` and `?ssn_contains=123` all return `[]` with a 200 (observed).
- Why: `where(ssn: "123")` serializes the operand through Encryptable's type, which produces a fresh random-IV ciphertext. That ciphertext never equals the stored one, so `=` and `IN` match nothing, and `!=` / `NOT IN` match every row. LIKE compares against ciphertext. Comparisons (`gt`…) compare ciphertext envelopes.
- Repro: `PARAMS audit PARAMS-1 ...` — `rspec <scratchpad>/audit/PARAMS_spec.rb -e "PARAMS-1"`
- Fix direction: in Filterable, detect an encryptable field (the same check `Support::EncryptedLookup` uses). Route equality/`in` through the blind index when one exists. Otherwise fail closed (`none`) for every operator, `not`/`not_in` included. Also add Filterable to CLAUDE.md's Encryptable guard list (it names searchable_by/taggable_by only).
- Affects: all Rails lines and adapters.

### PARAMS-2 [MEDIUM] Calling `paginate_by` / `includable` again in a subclass silently resets the parent's options
- Where: lib/concerns_on_rails/controllers/paginatable.rb:82-91; lib/concerns_on_rails/controllers/includable.rb:62-71.
- What happens: parent `paginate_by per_page: 10, max_per_page: 20, style: :jsonapi, link_header: false`, child `paginate_by per_page: 5`. The child gets `[max_per_page, page_param, link_header] == [200, ["page"], true]` (observed). The cap is loosened 10×: `?per_page=200` now returns 200 rows. JSON:API clients' `page[number]` is ignored, and Link headers come back on. Includable parent `includable :a, fields: {x: [:id]}, strategy: :preload, default: :a`, child `includable :a, :b` gives `[:includes, {}, []]` (observed): the sparse-fieldset allow-list is empty, the default include is gone, and the strategy changed.
- Why: every keyword has a literal default, so "omitted" and "reset to the default" look the same. CursorPaginatable fixed this exact bug class with an `UNSET` sentinel (cursor_paginatable.rb:73-75, 190-209; README line ~2071: "the rest, `signed:` included, are inherited"). Paginatable and Includable never got that fix.
- Repro: `rspec <scratchpad>/audit/PARAMS_spec.rb -e "PARAMS-2"`
- Fix direction: use the same UNSET-sentinel pattern in `paginate_by` and `includable`, so options that are not passed keep the inherited value. For `includable`, decide whether associations merge or replace, and document it.
- Affects: all.

### PARAMS-3 [MEDIUM] Paginatable 500s on a grouped relation whose HAVING references a select alias
- Where: lib/concerns_on_rails/controllers/paginatable.rb:261-264 (paginatable_plain_count: `except(:order, :limit, :offset, :select).count(:all)`), reached from :244-251.
- What happens: `Model.select("category, COUNT(*) AS n").group(:category).having("n > 1")` loads fine on its own, and `paginated(rel)` raises `ActiveRecord::StatementInvalid: SQLite3::SQLException: no such column: n` (observed SQL: `SELECT COUNT(*) AS "count_all", "pitems"."category" AS "pitems_category" FROM "pitems" GROUP BY ... HAVING n > 1`). This is the common "posts with more than N comments" pattern (`select("posts.*, COUNT(comments.id) AS c").joins(:comments).group(:id).having("c > 2")`).
- Why: stripping the SELECT list also strips the alias that HAVING depends on. SQLite and MySQL allow aliases in HAVING. PostgreSQL does not, so there the app's own query would already have failed.
- Repro: `rspec <scratchpad>/audit/PARAMS_spec.rb -e "PARAMS-3"`
- Fix direction: when `group_values` is present, count the groups as `SELECT COUNT(*) FROM (<relation minus order/limit/offset>.to_sql) sub`. That is the same subquery path the DISTINCT-select case already uses, and it keeps the select list.
- Affects: SQLite, MySQL/Trilogy (PostgreSQL rejects the alias in the app's own query).

### PARAMS-4 [MEDIUM] `predicate: :row` with mixed directions: page 1 mints a cursor, and every page-2 request 500s
- Where: lib/concerns_on_rails/controllers/cursor_paginatable.rb:872-883 (raise in cursor_row_predicate?), reached only from :316-318 / :846-853 when a cursor is present. The macro at :197-209 never checks.
- What happens: NOT NULL `score`/`created_at`, `cursor_paginate_by order: { score: :desc, created_at: :asc }, per_page: 2, predicate: :row`. Page 1 returns `["x1","x3"]` with an X-Next-Cursor. Following that cursor raises `ArgumentError: predicate: :row requires uniform order directions` (observed), which is a 500 on a server-minted token. With a nullable ordering column the same configuration silently falls back to OR-expansion, so whether it fails depends on the schema.
- Why: the uniform-direction check runs only when the keyset WHERE is built, and that only happens when a cursor is present.
- Repro: `rspec <scratchpad>/audit/PARAMS_spec.rb -e "PARAMS-4"`
- Fix direction: validate `predicate: :row` against `order:` / every preset at macro time (raise ArgumentError at class load). For a per-call `order:` override, check before the first page is served, or fall back to `:or` with a deprecation warning.
- Affects: all.

### PARAMS-5 [LOW] CursorPaginatable (SQLite): a cursor the gem minted itself is refused when the boundary string holds a NUL byte
- Where: lib/concerns_on_rails/controllers/cursor_paginatable.rb:667-672 (cursor_text_minted?).
- What happens: names `a b c "d\0x" e f` with `order: { name: :asc }, per_page: 2`. The walk returns `["a","b","c","d\u0000x"]`, then the next request raises InvalidCursor (observed), which is a 400. Rows `e` and `f` can never be reached. SQLite stored the NUL through a bound INSERT (`m.where(id: 4).pluck(:name) => ["x\u0000y"]` in an earlier probe).
- Why: the code comment assumes only MySQL can store a NUL in a text column, so a NUL boundary must be tampering. SQLite stores one fine through binds. The real limitation is that Arel inlines the boundary as a quoted literal, and SQLite cuts the statement text at the NUL.
- Repro: `rspec <scratchpad>/audit/PARAMS_spec.rb -e "PARAMS-5"`
- Fix direction: on SQLite, emit such a boundary as `CAST(X'<hex>' AS TEXT)` (or bind it) and accept it. At minimum, say in the README that a NUL-bearing ordering value ends the walk.
- Affects: SQLite only (PostgreSQL can't store NUL in text; MySQL is already accepted).

### PARAMS-6 [LOW] `?<field>_null=` with a non-boolean value is read as true (IS NULL)
- Where: lib/concerns_on_rails/controllers/filterable.rb:588-592 (apply_filter_null).
- What happens: `?deleted_at_null=maybe` runs `WHERE deleted_at IS NULL` (observed). Any typo (`ture`, `yes`, `no`, `nope`) is read as "true", except Rails' FALSE_VALUES list. The docs say `null (true/false)`, and the file header promises that "a comparison value the type cannot represent … matches nothing".
- Why: `ActiveModel::Type::Boolean#cast` returns true for any non-blank string not in FALSE_VALUES.
- Repro: `rspec <scratchpad>/audit/PARAMS_spec.rb -e "PARAMS-6"`
- Fix direction: accept only an explicit true/false set (`true/false/1/0/t/f`, case-insensitive, plus real booleans), and answer `none` (fail closed) or ignore the param for anything else.
- Affects: all.

### PARAMS-7 [LOW] `page`/`per_page` are read with String#to_i — `?per_page=1e3` is 1, `?page=2.9` is 2, `?per_page=10abc` is 10
- Where: lib/concerns_on_rails/support/scalar_param.rb:76-81 (to_i), used by :27-32 (per_page), paginatable.rb:379-389, cursor_paginatable.rb:449-454.
- What happens: `?per_page=1e3` on Paginatable gives `X-Per-Page: 1` (observed), so a client asking for 1000 (capped to 200) gets 1 row per page. This is the same lossy `to_i` reading the 1.33 Filterable/NumericOperand work removed.
- Why: `"1e3".to_i == 1`. `to_i` drops everything after the leading digits.
- Repro: `rspec <scratchpad>/audit/PARAMS_spec.rb -e "PARAMS-7"`
- Fix direction: read with `NumericOperand.classify(value, ActiveModel::Type::Integer.new, column_type: nil)`. Use the value only when it is `:exact` and a whole number; otherwise fall back to the default.
- Affects: all.

### PARAMS-8 [LOW] Float-column operands are rounded to the nearest double and treated as exact
- Where: lib/concerns_on_rails/support/numeric_operand.rb:161-168 (float_operand). Only the underflow-to-zero case (:177-180) is handled as inexact.
- What happens: score column holding 0.1. `?score_gt=0.1000000000000000000001` runs `score > 0.1` and drops the row (observed `[]`), even though the stored double 0.1000000000000000055… is greater than the operand. `?score=0.1000000000000000000001` matches the 0.1 row (observed). This breaks the file's "every operand read as an exact decimal… equals nothing" contract, which the underflow fix shows the author cares about.
- Why: `raw.strip.to_f` rounds. `to_f(raw).to_d != raw.to_d` is never checked.
- Repro: `rspec <scratchpad>/audit/PARAMS_spec.rb -e "PARAMS-8"`
- Fix direction: compare `BigDecimal(value, 0)` (the double's exact value) with the decimal operand. If they differ, return `:inexact` with `floor` = the largest double ≤ the operand (`value` or `value.prev_float`). Alternatively, document that float operands are read to the nearest double.
- Affects: all (float columns; only operands with more than ~17 significant digits).

## Suspected (unproven)

### PARAMS-S1 [MEDIUM] Controller Sortable never adds a primary-key tiebreaker, so `paginated(sorted(rel))` can repeat or skip rows across pages
- Where: lib/concerns_on_rails/controllers/sortable.rb:173-183 (`reorder` replaces default_scope's `order(:id)` too; observed SQL: `ORDER BY CASE … , "authors"."name" ASC`, no id).
- Why unproven: SQLite returns ties in a stable order. PostgreSQL and MySQL return ties in an unspecified order, so OFFSET pages over `?sort=status` can overlap. This needs PostgreSQL to show.
- Fix direction: append `primary_key ASC` (opt-out `tiebreaker: false`), as CursorPaginatable does.

### PARAMS-S2 [LOW] `paginated(rel.limit(n))` ignores the caller's LIMIT for both the count and the records
- Where: paginatable.rb:175 (`source.limit(per_page).offset(offset)` replaces the caller's limit) and :262 (count strips it).
- Why unproven: reasoned only; the README documents the stripped count but not the records. A "top 10, 3 per page" leaderboard would show `X-Total-Count` = the whole table, and page 4+ would return rows beyond the top 10.
- Fix direction: if `limit_value`/`offset_value` are set, paginate a subquery (`from(rel, table)`) or raise ArgumentError.

### PARAMS-S3 [LOW] CursorPaginatable rejects its own decimal boundary longer than 100 characters (PostgreSQL unconstrained `numeric`)
- Where: cursor_paginatable.rb:588 (`BigDecimal#to_s`) → :696-701 → numeric_operand.rb:46, :138 (MAX_LENGTH 100).
- Why unproven: PostgreSQL only; SQLite's decimal is REAL/INTEGER and can't produce such a value. A stored numeric with about 95 or more significant digits mints a cursor the next request rejects with a 400.

### PARAMS-S4 [LOW] `with:` lambdas with a non-numeric `type:` cast structured params: `?flag[]=0` under `type: :boolean` reaches the lambda as `true`; `type: :string` hands it `'["a"]'`
- Where: filterable.rb:216-246 (filterable_lambda_cast → type.cast of an Array/Parameters).
- Why unproven: reasoned from ActiveModel's Boolean/ImmutableString casts, not run. A non-scalar value should fail closed, as it already does for numeric `type:`.

## Improvement suggestions for this slice
- Validate `per_page <= max_per_page` in `paginate_by` / `cursor_paginate_by`. Today `paginate_by per_page: 500` silently serves 200, because `ScalarParam.per_page` clamps the default to the default cap.
- Filterable: guard `with:` lambdas that return nil or a non-relation (today it is a NoMethodError on the next filter), and give a clear error for a `scope:` that needs arguments (today it is an ArgumentError 500).
- Document that a direct-where boolean filter uses Rails' FALSE_VALUES (`?active=no` → `active = TRUE`, seen in a probe), or offer a strict boolean `type:`.
- Includable: optional strict mode (400) for unknown `?include=` / `fields[...]` entries. Today they are dropped silently, and `?include=bogus` returns no includes instead of the defaults.
- CLAUDE.md / README: add PARAMS-1 (Filterable × Encryptable) to the documented Encryptable guards; correct the cursor_text_minted? comment about which adapters store NUL; state that `predicate: :row` is validated only when page 2 is requested (until PARAMS-4 is fixed).
- Clean areas (probed, no bug found): a randomized CursorPaginatable property test with 40 rows, nullable/boolean/date/decimal/float/enum/string columns, 8 orderings × {:auto, :or} × per_page {1,3,7}, forward and bidirectional back-walks — all 48 configurations returned every row exactly once. Filterable bracket/suffix forms through real ActionController::Parameters (`stock[gte][]=`, `stock[in][][x]=`, `+5`, `.5`, `5.`, `0x10`, `1_000`, `%00`) all behaved as documented. Sortable params (Array/Hash/case/duplicates) and IncludeTree shapes (nested, duplicates, malformed paths, Hash/Array garbage) were correct. Link header (JSON:API nested page, UTF-8, nested arrays) was correctly encoded.

## Coordinator run results (2026-10-29, SQLite, default Gemfile = Rails 8.1)
`bundle exec rspec audit/PARAMS_spec.rb` → 12 examples, 12 failures.
- PARAMS-1 (2): FAIL — `?ssn_not=123` / `?ssn_not_in=123` return ["match", "other"] → **PROVEN**.
- PARAMS-2 (3): FAIL — child max_per_page 200 (parent 20), X-Per-Page "200", child includable_strategy :includes (parent :preload) → **PROVEN**.
- PARAMS-3: FAIL — `StatementInvalid: no such column: n` from the stripped-select COUNT → **PROVEN**.
- PARAMS-4: FAIL — page 2 raises `ArgumentError: predicate: :row requires uniform order directions` on a server-minted cursor → **PROVEN**.
- PARAMS-5: FAIL — `InvalidCursor` on the gem's own cursor after the NUL-bearing row → **PROVEN** (SQLite).
- PARAMS-6: FAIL — `?deleted_at_null=maybe` ran IS NULL (returned ["live"]) → **PROVEN**.
- PARAMS-7: FAIL — `?per_page=1e3` → X-Per-Page "1" → **PROVEN**.
- PARAMS-8 (2): FAIL — float operand rounded to the nearest double → **PROVEN** (edge case).
