# ConcernsOnRails — documentation site

The source for the documentation site published to **GitHub Pages**. It's a
self-contained static SPA: no build step, no framework, no runtime CDN
dependencies.

## Structure

```
docs/
├── index.html              # SPA shell (top bar, sidebar, content area)
├── .nojekyll               # tell GitHub Pages to serve files as-is
├── llms.txt                # AI/LLM index of every concern doc (llmstxt.org convention)
├── llms-full.txt           # all concern docs in one file — GENERATED at deploy, gitignored
├── assets/
│   ├── css/style.css       # design system (dark + light themes)
│   └── js/
│       ├── concerns.js     # manifest: every concern's metadata (drives nav/cards/search)
│       ├── app.js          # router, markdown rendering, search, theme toggle, TOC
│       └── vendor/         # pinned local copies of marked + highlight.js (+ theme)
└── concerns/
    └── <slug>.md           # one standalone Markdown doc per concern
```

The SPA fetches content with JavaScript, which AI agents and crawlers can't run —
`llms.txt` / `llms-full.txt` are the machine-readable front door. Both are built by
[`script/build_llms_docs.rb`](../script/build_llms_docs.rb) from the manifest + the
`concerns/*.md` files (it aborts on any manifest/docs drift). The Pages workflow
reruns it on every deploy, so the published copies never go stale; `llms.txt` is
also committed so it's browsable on GitHub.

Each concern gets its own Markdown file in `concerns/`. `app.js` fetches it on
demand (hash route `#/c/<slug>`), renders it with `marked`, highlights Ruby with
`highlight.js`, and builds an "on this page" table of contents.

## Preview locally

`fetch()` is blocked on the `file://` protocol, so serve the folder over HTTP:

```sh
cd docs
python3 -m http.server 8000
# open http://localhost:8000
```

## Deploy (GitHub Pages)

Deployment is automated by [`.github/workflows/pages.yml`](../.github/workflows/pages.yml),
which uploads `docs/` as the Pages artifact on every push to `master` that
touches `docs/`.

**One-time setup:** repo **Settings → Pages → Build and deployment → Source:
"GitHub Actions"**. After the first run the site is live at
`https://vsn2015.github.io/concerns_on_rails/`.

## Adding or editing a concern doc

1. Add/adjust the entry in `assets/js/concerns.js` (slug, name, category, icon,
   tagline, `include` path, `src` path, tags).
2. Write/edit `concerns/<slug>.md` — start with a one-paragraph overview (no
   `# H1`; the page title is rendered from the manifest), then use `##` sections.
3. Run `ruby script/build_llms_docs.rb` to refresh the committed `llms.txt`
   (the deploy regenerates it anyway, but keeping the committed copy current
   avoids confusing diffs later).
4. Commit. The Pages workflow redeploys automatically.
