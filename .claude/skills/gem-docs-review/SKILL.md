---
name: gem-docs-review
description: >-
  Harvests offline documentation (README, CHANGELOG, public API) for every gem
  in a Ruby/Rails project's Gemfile.lock into a local cache, tracks gem versions
  in a manifest, and refreshes only gems whose version changed. Then reviews a
  git diff or pull request against that cache to surface (a) gem-upgrade impact —
  breaking changes, deprecations, and removed/renamed methods when a gem version
  bumps — and (b) anti-reinvention opportunities — project code that reimplements
  functionality an installed gem already provides. Use when reviewing a Rails/Ruby
  diff or PR, when a Gemfile/Gemfile.lock changes or gems are upgraded, or when
  asked to refresh or build the local gem-documentation cache.
---

# gem-docs-review

A self-contained, dependency-free skill (Ruby stdlib + Bundler only) for **gem-aware code
review**. It keeps a local cache of each gem's own docs and source-derived API, refreshes it
incrementally as versions change, and uses it to review diffs/PRs.

## The engine

All deterministic work lives in one script. Define a shorthand and run it **with the project's
bundler** so the locked gems resolve:

```sh
SCRIPT="${CLAUDE_SKILL_DIR}/scripts/gem_docs.rb"
bundle exec ruby "$SCRIPT" <command> [options]
```

> **This repo (concerns_on_rails):** prefix every invocation with `ASDF_RUBY_VERSION=3.2.2`,
> e.g. `ASDF_RUBY_VERSION=3.2.2 bundle exec ruby "$SCRIPT" check`. Other projects just use
> `bundle exec ruby`. If a project has no Gemfile.lock at the repo root, pass `--lockfile PATH`.

| Command | What it does | Output |
|---|---|---|
| `check` | Diff current `Gemfile.lock` vs the stored manifest. **Read-only.** | JSON: `up_to_date`, `added`/`removed`/`changed` (with upgrade/downgrade direction), `stale_cache` |
| `sync` | Harvest docs for gems that are added/changed/uncached, then rewrite the manifest. | JSON: `harvested`, `errors` |
| `sync --all` | Re-harvest every gem (use after changing the harvester or to rebuild). | JSON |
| `sync --prune` | Also delete cached dirs for gem-versions no longer in the lockfile. | JSON |
| `status` | Human-readable cache summary + pending changes. | text (add `--json` for JSON) |
| `surface NAME` | Print the absolute cache paths (readme/changelog/api/meta) for one gem. | JSON |
| `changelog NAME` | Print the cached CHANGELOG for one gem (for upgrade-impact). | text |

## Cache layout

Default location: `<project>/.gem-docs-cache/` (override with `--cache PATH` or `$GEM_DOCS_CACHE`).
**Add it to `.gitignore`** — it is a rebuildable, machine-local cache.

```
.gem-docs-cache/
  manifest.json                  # schema, ISO8601 generated_at, lockfile sha256, bundler/ruby
                                  # versions, and per-gem {version, platform, harvested, paths}
  gems/<name>-<version>/
    README.md                    # the gem's own README (capped at 300 KB)
    CHANGELOG.md                 # the gem's own CHANGELOG/History/NEWS (capped)
    api.txt                      # qualified public API index: "Klass#method", "Module.method"
    meta.json                    # summary, homepage, licenses, runtime deps, changelog_uri
```

The manifest is the **version file**: it records every locked gem's version. Change detection
compares the live lockfile to it (name + version), since this project's Bundler predates the
opt-in `CHECKSUMS` lockfile section.

---

## Workflow A — keep the cache fresh

1. `bundle exec ruby "$SCRIPT" check` — read the JSON.
2. If `up_to_date` is `false`, run `bundle exec ruby "$SCRIPT" sync`. It harvests **only** the
   gems in `added` + `changed` + `stale_cache`, so it's cheap after the first build.
3. Remember the `changed` list from step 1 — those gems are the focus of upgrade-impact review.

First-ever run harvests all gems (≈40s / ≈5 MB for a Rails app); later runs touch only deltas.

## Workflow B — review a diff or PR

> Read `reference/review-guide.md` for the full methodology, heuristics, and output format.
> Summary of the loop:

1. **Refresh** the cache (Workflow A). Note which gems `changed`.
2. **Get the diff.** Working tree / branch: `git diff` (or `git diff main...HEAD`). GitHub PR:
   `gh pr diff <number>` or the `github` MCP `get_pull_request_files`.
3. **Upgrade-impact pass** — for each gem whose version `changed` (especially those touched by a
   `Gemfile.lock` change in the diff):
   - `changelog <gem>` and read the entries between the old and new version; read `api.txt`.
   - Grep the **project** code for usages of any deprecated/removed/renamed API and flag each
     `file:line` with the changelog evidence and a concrete migration.
4. **Anti-reinvention pass** — for code **added/changed** in the diff:
   - Identify what each new helper/method does. Search the cached `README.md` + `api.txt` of
     relevant installed gems (e.g. `grep -ri <concept> .gem-docs-cache/gems/<gem>-*/`) for an
     existing method that already does it.
   - If found, recommend calling the gem's method instead, citing the gem + version + API entry.
5. **Report** findings grouped by severity, each with `file:line`, the gem+version, the cached
   doc citation, and a specific suggested change. Don't invent APIs — only cite entries that
   exist in the cache (or confirm via Context7, below).

## Notes

- **Portability.** The skill is generic — copy `.claude/skills/gem-docs-review/` into any
  Ruby/Rails repo. Only the `ASDF_RUBY_VERSION` prefix above is specific to this repo.
- **Context7 fallback (optional).** When a gem's cached README/CHANGELOG is thin or its
  `api.txt` is empty (e.g. C-extension gems with little Ruby in `lib/`), and a Context7 MCP
  server is available, resolve the library and fetch docs on demand rather than guessing.
  `meta.json` carries the gem's `changelog_uri`/`source_uri` for fetching upstream notes.
- **Optional power tools (not required, auto-detect).** If the bundle includes `gem-compare`
  (`gem compare NAME v1 v2`) or `next_rails` (`bundle_report compatibility`, `outdated --json`),
  use them to enrich the upgrade-impact pass with dependency/metadata diffs. The skill works
  fully without them.
- **`api.txt` caveat.** It is a parser-derived index of `def`/`class`/`module` names for
  fast "does this already exist?" lookup — it does **not** track method visibility, so treat the
  README's documented usage as the authority on what's truly public.
