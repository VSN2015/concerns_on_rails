# Review guide — upgrade-impact & anti-reinvention

Detailed methodology for **Workflow B** in `SKILL.md`. Load this when actually reviewing a diff
or PR. The cache (`.gem-docs-cache/`) must be fresh first (`check` → `sync`).

Two independent passes produce findings. Run both, then merge and rank.

---

## Inputs

- **The diff.** `git diff main...HEAD`, `git diff` (working tree), or `gh pr diff <n>` /
  `github` MCP `get_pull_request_files`. Note added vs removed lines per file.
- **The changed-gems list** from `gem_docs.rb check` (`diff.changed`, with `from`/`to`/`direction`).
- **The cache** — per gem: `README.md`, `CHANGELOG.md`, `api.txt`, `meta.json`. Get paths with
  `gem_docs.rb surface <gem>`; read CHANGELOG with `gem_docs.rb changelog <gem>`.

---

## Pass 1 — Gem-upgrade impact

Goal: when a gem's version changed, find where **this project's code** is affected by what
changed between the old and new version.

For each gem in `diff.changed` (prioritize ones whose `Gemfile.lock` line appears in the diff,
and major/minor bumps over patch bumps):

1. **Read the delta.** `gem_docs.rb changelog <gem>` prints the cached CHANGELOG. Read every
   entry **strictly between** `from` (exclusive) and `to` (inclusive). Extract items tagged or
   phrased as: *breaking / removed / deprecated / renamed / changed default / dropped support /
   required-Ruby-or-Rails bump*. Note the symbol/method/option each refers to.
2. **Semver sanity.** Map `from → to` against the gem's own conventions:
   - **Major** bump (`1.x → 2.0`): assume breaking; read the whole CHANGELOG section, not just headlines.
   - **Minor** (`1.4 → 1.5`): look for deprecations and new defaults.
   - **Patch** (`1.4.2 → 1.4.3`): usually safe; still scan for "fixed behavior" that code may rely on.
   - Rails-family gems move in lockstep — a Rails bump implies the whole `action*`/`active*` set.
3. **If the CHANGELOG is thin or absent** (`changelog` errors, or the file is a stub): fall back
   to `meta.json`'s `changelog_uri`/`source_uri` and fetch upstream notes via Context7 or
   `WebFetch`; or, if installed, `gem compare <gem> <from> <to>` for dependency/API/file deltas.
   Say explicitly when you couldn't find authoritative notes — don't guess at breaking changes.
4. **Map to project code.** For each affected symbol, grep the project (not the cache) for usage:
   `grep -rn "removed_method\|RenamedConst\|:deprecated_option" lib app` (scope to the project's
   real source dirs). Every hit is a candidate finding.
5. **Confirm against the new API.** Cross-check the symbol against the **new** version's
   `api.txt` — if a method named in a removal note is absent from `api.txt`, that strengthens the
   finding; if it's still present, it may be a soft-deprecation (lower severity).

A finding here = `file:line` in project code + the gem@version + the CHANGELOG line proving the
change + a concrete migration (the replacement API, from the new `README.md`/`api.txt`).

---

## Pass 2 — Anti-reinvention

Goal: find code in the diff that **reimplements what an installed gem already does**, and
recommend calling the gem instead. (This is the user's explicit priority: prefer gem code over
new custom functions.)

For each **added or substantially-changed** method/block in the diff:

1. **Name the intent** in a few words ("slugify a title", "mask an email", "retry on collision",
   "deep-merge a hash", "parse a duration", "constant-time string compare").
2. **Pick candidate gems.** Which installed gems plausibly own that concept? Use the bundle:
   `activesupport` (huge surface: `blank?`, `presence`, `squish`, `deep_merge`, `truncate`,
   `Time.current`, `delegate`, …), plus domain gems already present (`friendly_id` for slugs,
   `nokogiri`/`loofah`/`rails-html-sanitizer` for HTML, `faker` for fake data, etc.).
3. **Search the cache for an existing API:**
   ```sh
   grep -rin "<keyword>" .gem-docs-cache/gems/<gem>-*/README.md .gem-docs-cache/gems/<gem>-*/api.txt
   ```
   Search README first (it shows *documented* usage), then `api.txt` for the method index. A
   match in both — a documented method with that name — is a strong recommendation.
4. **Verify before recommending.** Open the gem's `README.md` to confirm the method's real
   signature and semantics actually match the custom code's behavior (edge cases, return type,
   nil handling). `api.txt` does not encode visibility, so confirm the method is public via the
   README. **Never recommend a method you haven't found in the cache** (or confirmed via Context7).
5. **Recommend** the swap: show the custom snippet, the gem method that replaces it, the
   gem@version, and the doc citation. If it's a near-match but not exact, say what differs.

> **Project-specific note (concerns_on_rails):** this *is* a gem of reusable ActiveSupport
> concerns. Watch for the project re-implementing helpers ActiveSupport/Rails already ships
> (string/array/hash/date helpers, `class_attribute`, `delegate`, `Module#delegate`,
> `ActiveSupport::Concern` machinery) — but also respect deliberate zero-/minimal-dependency
> choices: flag it as a *suggestion*, and note when avoiding the dependency is the point.

---

## Output format

Group by severity; within each, sort by file. Keep each finding tight and evidence-backed.

```
## Gem-aware review

Cache: 94 gems, refreshed <ts>. Changed this diff: friendly_id 5.6.0->5.7.0, rails 7.1.5->7.1.6.

### Breaking — must fix
- app/models/post.rb:42 — `friendly_id` 5.6.0->5.7.0
  Uses `Post.find(slug)` fallback removed in 5.7.0.
  Evidence: CHANGELOG 5.7.0 "Remove deprecated finder that fell back to id".
  Fix: use `Post.friendly.find(slug)` (README "Finding Records").

### Deprecation — fix soon
- lib/foo.rb:10 — `activesupport` 7.1.6
  `Time.zone.now` ... (changelog evidence + migration)

### Anti-reinvention — consider using the gem
- lib/utils.rb:5-18 — custom `blank_string?(s)` duplicates `ActiveSupport`'s `String#blank?`.
  Evidence: activesupport api.txt `Object#blank?`; README "Core Extensions".
  Suggest: `s.blank?`. (Note: keep custom version only if avoiding the AS dependency is intended.)

### Notes / couldn't verify
- <gem> bumped but no CHANGELOG entries between versions found in cache; upstream notes: <uri>.
```

Severity rubric:
- **Breaking** — removed/renamed API the project actually calls; will error or change behavior.
- **Deprecation** — still works but warns / scheduled for removal; or changed default the code depends on.
- **Anti-reinvention** — works fine, but a gem already does it; a quality suggestion, not a defect.
- **Note** — version changed with no project impact found, or a claim you could not verify.

---

## Pitfalls & false-positive guards

- **Stay inside the bundle.** Only recommend gems already in `Gemfile.lock` (in the cache).
  Don't suggest adding a new dependency unless the user asked.
- **Cite, don't hallucinate.** Every breaking-change and every suggested method must trace to a
  cached CHANGELOG line or `api.txt`/`README.md` entry (or an explicit Context7/WebFetch lookup).
  If you can't find it, downgrade to a Note and say so.
- **Grep the project, not the cache, for usage** — and scope to real source dirs (`lib`, `app`,
  `bin`), excluding `spec/test`, vendored code, and `.gem-docs-cache/` itself.
- **Match semantics, not just names.** A same-named gem method that behaves differently is not a
  valid anti-reinvention swap — note the difference instead of forcing the recommendation.
- **Respect intentional minimalism.** Re-implementations that exist to avoid a dependency (common
  in gems/libraries) are a trade-off, not a bug — present them as optional.
- **Patch bumps are usually noise.** Don't manufacture breaking-change findings for patch
  releases; scan, and if nothing substantive changed, say "no project impact found."
