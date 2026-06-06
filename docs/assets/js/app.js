/* ============================================================
   concerns_on_rails docs — SPA controller
   Landing page (home route) + per-concern docs (doc route).
   Vanilla JS. Hash routing, markdown render, search, theme.
   ============================================================ */
(function () {
  "use strict";

  var CONCERNS = window.CONCERNS || [];
  var META = window.COR_META || { version: "", repo: "#", branch: "master" };
  var BY_SLUG = {};
  CONCERNS.forEach(function (c) { BY_SLUG[c.slug] = c; });
  var MODELS = CONCERNS.filter(function (c) { return c.category === "model"; });
  var CTRLS = CONCERNS.filter(function (c) { return c.category === "controller"; });

  var view = document.getElementById("view");
  var sidebar = document.getElementById("sidebar");
  var searchInput = document.getElementById("search");
  var toastEl = document.getElementById("toast");
  var mdCache = {};
  var tocObserver = null;
  var toastTimer = null;

  /* ---------- helpers ---------- */
  function esc(s) { return String(s).replace(/[&<>"']/g, function (m) { return ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[m]; }); }
  function slugify(s) { return String(s).toLowerCase().trim().replace(/[`*_~]/g, "").replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, ""); }
  function srcUrl(c) { return META.repo + "/blob/" + (META.branch || "master") + "/" + c.src; }

  var GH_SVG = '<svg width="17" height="17" viewBox="0 0 16 16" fill="currentColor" aria-hidden="true"><path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.01 8.01 0 0 0 16 8c0-4.42-3.58-8-8-8Z"/></svg>';
  var COPY_ICON = '⧉';

  /* a dark "terminal" window with mac dots + filename + copy button */
  function term(file, src) {
    return '<div class="term">' +
      '<div class="term-bar"><span class="dot r"></span><span class="dot y"></span><span class="dot g"></span>' +
        '<span class="term-file">' + esc(file) + '</span>' +
        '<button class="copybtn" type="button">' + COPY_ICON + ' copy</button></div>' +
      '<pre><code class="language-ruby">' + esc(src) + '</code></pre></div>';
  }
  /* inline single-line command bar */
  function copybar(innerHtml, copyText) {
    return '<div class="copybar"><span class="mono">' + innerHtml + '</span>' +
      '<button class="copybtn" type="button" data-copy="' + esc(copyText) + '">' + COPY_ICON + '</button></div>';
  }

  /* ---------- copy + toast (event-delegated) ---------- */
  function showToast() {
    if (!toastEl) return;
    toastEl.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { toastEl.classList.remove("show"); }, 1600);
  }
  document.addEventListener("click", function (e) {
    var btn = e.target.closest ? e.target.closest(".copybtn") : null;
    if (!btn) return;
    var text = btn.getAttribute("data-copy");
    if (text == null) {
      var box = btn.closest(".term, .code-wrap");
      var pre = box && box.querySelector("pre");
      text = pre ? pre.innerText : "";
    }
    var write = navigator.clipboard && navigator.clipboard.writeText
      ? navigator.clipboard.writeText(text)
      : (function () { var ta = document.createElement("textarea"); ta.value = text; document.body.appendChild(ta); ta.select(); try { document.execCommand("copy"); } catch (x) {} document.body.removeChild(ta); return Promise.resolve(); })();
    write.then(showToast, showToast);
  });

  /* ---------- sidebar (doc route) ---------- */
  function buildSidebar() {
    var html = '<a class="home-link" href="#/" data-home>🏠 <span>Overview</span></a>';
    [{ key: "model", label: "Model concerns", items: MODELS }, { key: "controller", label: "Controller concerns", items: CTRLS }].forEach(function (g) {
      html += '<div class="nav-group" data-group="' + g.key + '">';
      html += '<div class="label">' + g.label + '<span class="count">' + g.items.length + '</span></div>';
      g.items.forEach(function (c) {
        html += '<a class="nav-item" data-slug="' + c.slug + '" href="#/c/' + c.slug + '"><span class="ico">' + c.icon + '</span><span class="nm">' + esc(c.name) + '</span></a>';
      });
      html += '</div>';
    });
    html += '<div class="no-results" hidden>No concerns match.</div>';
    sidebar.innerHTML = html;
  }
  function setActiveNav(slug) {
    sidebar.querySelectorAll(".nav-item").forEach(function (a) { a.classList.toggle("active", a.getAttribute("data-slug") === slug); });
    var home = sidebar.querySelector(".home-link");
    if (home) home.classList.toggle("active", !slug);
  }

  /* ---------- search (sidebar nav + home cards/chips) ---------- */
  function matches(c, q) {
    if (!q) return true;
    var hay = (c.name + " " + c.tagline + " " + c.include + " " + (c.tags || []).join(" ")).toLowerCase();
    return q.split(/\s+/).every(function (t) { return hay.indexOf(t) !== -1; });
  }
  function applySearch() {
    var q = (searchInput.value || "").toLowerCase().trim();
    // sidebar
    var anyNav = false;
    sidebar.querySelectorAll(".nav-item").forEach(function (a) {
      var ok = matches(BY_SLUG[a.getAttribute("data-slug")], q);
      a.classList.toggle("hidden", !ok); if (ok) anyNav = true;
    });
    sidebar.querySelectorAll(".nav-group").forEach(function (grp) {
      grp.style.display = grp.querySelectorAll(".nav-item:not(.hidden)").length ? "" : "none";
    });
    var nr = sidebar.querySelector(".no-results"); if (nr) nr.hidden = anyNav;
    // home grids + chips
    view.querySelectorAll(".card.concern[data-slug]").forEach(function (card) {
      card.style.display = matches(BY_SLUG[card.getAttribute("data-slug")], q) ? "" : "none";
    });
    view.querySelectorAll("[data-cardgrid]").forEach(function (grid) {
      var vis = Array.prototype.filter.call(grid.children, function (ch) { return ch.style.display !== "none"; }).length;
      grid.style.display = vis ? "" : "none";
      var head = grid.previousElementSibling;
      if (head && head.classList.contains("subhead")) head.style.display = vis ? "" : "none";
    });
    view.querySelectorAll("a.chip[data-slug]").forEach(function (chip) {
      chip.style.display = matches(BY_SLUG[chip.getAttribute("data-slug")], q) ? "" : "none";
    });
  }

  /* ============================================================
     HOME / LANDING
     ============================================================ */
  function renderHome() {
    teardownToc();
    document.body.className = "route-home";
    setActiveNav(null);
    document.title = "concerns_on_rails — plug-and-play ActiveSupport concerns for Rails";

    var heroCode =
      "class Article < ApplicationRecord\n" +
      "  include ConcernsOnRails::Sluggable\n" +
      "  include ConcernsOnRails::SoftDeletable\n" +
      "  include ConcernsOnRails::Searchable\n\n" +
      "  sluggable_by  :title\n" +
      "  searchable_by :title, :body\n" +
      "end\n\n" +
      "# everything below now just works\n" +
      'article.slug              # => "hello-world"\n' +
      'Article.search("rails")   # LIKE/ILIKE across :title, :body\n' +
      "article.destroy           # soft-delete: sets deleted_at, hides it";

    var modelsCode =
      "class Product < ApplicationRecord\n" +
      "  include ConcernsOnRails::Sluggable\n" +
      "  include ConcernsOnRails::SoftDeletable\n" +
      "  include ConcernsOnRails::Sortable\n\n" +
      "  sluggable_by :name\n" +
      "  sortable_by  :position\n" +
      "end\n\n" +
      "Product.without_deleted   # excludes soft-deleted\n" +
      "product.move_higher       # reorder via acts_as_list";

    var ctrlCode =
      "class ArticlesController < ApplicationController\n" +
      "  include ConcernsOnRails::Controllers::Paginatable\n" +
      "  include ConcernsOnRails::Controllers::Filterable\n\n" +
      "  filter_by    :status, :category\n" +
      "  paginate_by  per_page: 25\n\n" +
      "  def index\n" +
      "    render json: paginated(filtered(Article.all))\n" +
      "  end\n" +
      "end";

    var secCode =
      "class Api::BaseController < ApplicationController\n" +
      "  include ConcernsOnRails::Controllers::SecureHeadable\n" +
      "  include ConcernsOnRails::Controllers::Throttleable\n" +
      "  include ConcernsOnRails::Controllers::Authorizable\n\n" +
      "  secure_headers :nosniff, :sameorigin_frame\n" +
      "  throttle_by limit: 100, period: 1.minute   # 429 + X-RateLimit-*\n" +
      "  authorize_by { current_user.present? }      # 403 unless truthy\n" +
      "end";

    var usageCode =
      "class Post < ApplicationRecord\n" +
      "  include ConcernsOnRails::Sluggable\n" +
      "  include ConcernsOnRails::SoftDeletable\n" +
      "  include ConcernsOnRails::Taggable\n" +
      "  include ConcernsOnRails::Searchable\n" +
      "  include ConcernsOnRails::Publishable\n\n" +
      "  sluggable_by  :title, scope: :author_id\n" +
      "  searchable_by :title, :body\n" +
      "  taggable_by   :tags\n" +
      "end\n\n" +
      "# --- and now, for free: ---\n" +
      'post = Post.create!(title: "Hello, Rails")\n' +
      'post.slug                       # => "hello-rails"\n' +
      'post.tag_list = "ruby, oss"\n' +
      'Post.search("rails").tagged_with("ruby").published';

    var html = '' +
    /* HERO */
    '<section class="hero"><div class="wrap"><div class="hero-grid">' +
      '<div class="reveal">' +
        '<span class="pill">v' + esc(META.version) + ' · Rails 5–8</span>' +
        '<h1>Reusable concerns,<br><span class="ruby">batteries included.</span></h1>' +
        '<p class="lede">A plug-and-play collection of ' + CONCERNS.length + ' reusable ActiveSupport concerns for your Rails models and controllers. Drop one in, skip the boilerplate.</p>' +
        copybar('<span class="tg">$</span> bundle add concerns_on_rails', 'bundle add concerns_on_rails') +
        '<div class="cta" style="margin-top:1.25rem">' +
          '<a class="btn btn-primary" href="#/c/sluggable">Get started →</a>' +
          '<a class="btn btn-ghost" href="#api" data-scroll="api">Browse the API</a>' +
        '</div>' +
        '<div class="facts"><span>' + CONCERNS.length + ' concerns</span><span>' + MODELS.length + ' model · ' + CTRLS.length + ' controller</span><span>Ruby ≥ 3.2</span><span>MIT</span></div>' +
      '</div>' +
      '<div class="reveal">' + term("app/models/article.rb", heroCode) + '</div>' +
    '</div></div></section>' +

    /* CONCERNS STRIP */
    '<section class="section-band" style="padding:3rem 0"><div class="wrap">' +
      '<p class="eyebrow strip-label">' + CONCERNS.length + ' concerns in the box — include only what you need</p>' +
      '<div class="strip-chips">' + CONCERNS.map(function (c) {
        return '<a class="chip" data-slug="' + c.slug + '" href="#/c/' + c.slug + '">' + c.icon + ' ' + esc(c.name) + '</a>';
      }).join("") + '</div>' +
    '</div></section>' +

    /* FEATURES */
    '<section id="features" class="section"><div class="wrap">' +
      '<div class="lead-block reveal"><span class="eyebrow">Features</span>' +
        '<h2>Two layers, one gem.</h2>' +
        '<p>Model concerns and controller concerns — each tested with RSpec, documented, and convention-driven. Include what you need; ignore the rest.</p></div>' +
      '<div class="feature-rows">' +
        featureRow(false, "01 · Models", "Drop-in model concerns", "Slugs, soft deletes, ordering, tagging, state machines, money columns. Each concern adds scopes, a declarative macro and instance methods with sensible defaults — and stays out of your way until you call it.",
          ["Zero ceremony — <code>include</code> and go", "Composable — stack as many as you like", "Override any default via a single macro"], "app/models/product.rb", modelsCode) +
        featureRow(true, "02 · Controllers", "Controller concerns that compose", "Pagination, query-param filtering, JSON envelopes and content negotiation, ready to chain. Keep your actions to one expressive line instead of a pile of before-actions.",
          ["<code>paginated</code> / <code>filtered</code> / <code>respond_*</code> helpers", "Whitelisted, injection-safe filters", "Standard pagination headers out of the box"], "app/controllers/articles_controller.rb", ctrlCode) +
        featureRow(false, "03 · Security &amp; integrity", "Hardening, built in", "Security headers with a native CSP DSL, rate limiting with <code>429</code> + <code>X-RateLimit-*</code>, block-based authorization, HTML sanitization and display masking — defense-in-depth without extra gems.",
          ["CSP, HSTS &amp; frame headers via <code>secure_headers</code>", "Rate limit any action with <code>throttle_by</code>", "Per-action <code>authorize_by</code> 403 gate"], "app/controllers/api/base_controller.rb", secCode) +
      '</div>' +
    '</div></section>' +

    /* ALL CONCERNS GRID */
    '<section id="concerns" class="section section-band"><div class="wrap">' +
      '<div class="lead-block reveal"><span class="eyebrow">The catalog</span>' +
        '<h2>Every concern, documented.</h2>' +
        '<p>All ' + CONCERNS.length + ' concerns, each with its own page covering installation, configuration options, scopes, methods and gotchas. Click any card to read the docs.</p></div>' +
      concernGrid("model", "🧱 Model concerns", MODELS) +
      concernGrid("controller", "🎮 Controller concerns", CTRLS) +
      '<div style="text-align:center;margin-top:2.5rem"><a class="btn btn-primary" href="#/c/sluggable">See all concerns →</a></div>' +
    '</div></section>' +

    /* USAGE */
    '<section id="usage" class="section"><div class="wrap">' +
      '<div class="lead-block reveal"><span class="eyebrow">Usage</span>' +
        '<h2>One line replaces forty.</h2>' +
        '<p>Mix concerns freely. Here a single model picks up slugs, soft deletes, tagging, search and publishing — each via one macro.</p></div>' +
      '<div class="reveal" style="max-width:46rem">' + term("app/models/post.rb", usageCode) + '</div>' +
    '</div></section>' +

    /* QUICK START */
    '<section id="start" class="section section-band"><div class="wrap"><div class="start-grid">' +
      '<div class="reveal"><span class="eyebrow">Quick start</span>' +
        '<h2>Up and running in three steps.</h2>' +
        '<p style="color:var(--ink-soft);font-size:1.1rem;margin:.75rem 0 1.5rem">From an empty Gemfile to your first concern in about a minute.</p>' +
        '<a class="btn btn-ghost" href="' + esc(META.repo) + '#readme" target="_blank" rel="noopener">Full guide on GitHub →</a></div>' +
      '<ol class="timeline reveal">' +
        '<li><span class="num">1</span><h4>Add the gem</h4><p>Drop it into your Gemfile and bundle.</p>' + copybar('<span class="tg">$</span> bundle add concerns_on_rails', 'bundle add concerns_on_rails') + '</li>' +
        '<li><span class="num">2</span><h4>Include a concern</h4><p>Mix it into a model and call its macro.</p>' + copybar('<span class="tk">include</span> <span class="tc">ConcernsOnRails::Sluggable</span>', 'include ConcernsOnRails::Sluggable') + '</li>' +
        '<li><span class="num">3</span><h4>Use it</h4><p>Friendly finds, scopes and helpers, for free.</p>' + copybar('<span class="tc">Article</span>.friendly.find(<span class="ts">"hello-world"</span>)', 'Article.friendly.find("hello-world")') + '</li>' +
      '</ol>' +
    '</div></div></section>' +

    /* API + AT A GLANCE */
    '<section id="api" class="section"><div class="wrap"><div class="api-grid">' +
      '<div class="reveal"><span class="eyebrow">API reference</span>' +
        '<h2 style="font-size:2.2rem;font-weight:800;margin:.6rem 0 1.4rem">The methods you\'ll reach for.</h2>' +
        '<div class="api-list">' +
          apiCard("include Sluggable · sluggable_by :title", 'Adds <code>#slug</code> via <code>friendly_id</code> and finds records by their slug.') +
          apiCard("include SoftDeletable", 'Soft-delete via <code>destroy</code>; <code>.without_deleted</code> / <code>.with_deleted</code> / <code>.only_deleted</code> scopes and <code>#restore</code>.') +
          apiCard("include Searchable · searchable_by *cols", 'A chainable <code>.search("query")</code> scope (LIKE/ILIKE) across the listed columns.') +
          apiCard("include Publishable", 'Publish via a <code>published_at</code> timestamp; <code>.published</code> / <code>.unpublished</code> scopes.') +
          apiCard("include Controllers::Paginatable · paginate_by", '<code>paginated(scope)</code> returns a page and sets pagination response headers.') +
          apiCard("include Controllers::Filterable · filter_by", '<code>filtered(scope)</code> applies whitelisted URL-param filters, safely.') +
        '</div>' +
        '<a class="btn btn-ghost" style="margin-top:1.4rem" href="#/c/sluggable">Full reference →</a>' +
      '</div>' +
      '<div class="reveal"><span class="eyebrow">At a glance</span>' +
        '<h2 style="font-size:2.2rem;font-weight:800;margin:.6rem 0 1.4rem">By the numbers.</h2>' +
        '<div class="glance">' +
          '<div class="stats">' +
            stat(CONCERNS.length, "concerns") + stat(MODELS.length, "model") +
            stat(CTRLS.length, "controller") + stat("MIT", "license") +
          '</div>' +
          '<div class="card meta-card">' +
            metaRow("Version", "v" + META.version) +
            metaRow("Rails", "5.0 – 8.x") +
            metaRow("Ruby", "≥ 3.2") +
            metaRow("Built on", "friendly_id · acts_as_list") +
            metaRow("Tests", "RSpec + SimpleCov") +
          '</div>' +
        '</div>' +
      '</div>' +
    '</div></div></section>' +

    footer();

    view.innerHTML = html;
    highlightAll(view);
    window.scrollTo(0, 0);
    applySearch();
    revealInit();
  }

  function featureRow(flip, pill, title, body, checks, file, code) {
    var text = '<div class="ftext"><span class="pill">' + pill + '</span>' +
      '<h3 style="margin-top:1rem">' + title + '</h3><p>' + body + '</p>' +
      '<ul class="checks">' + checks.map(function (c) { return '<li><span class="ck">✓</span><span>' + c + '</span></li>'; }).join("") + '</ul></div>';
    var code_ = '<div>' + term(file, code) + '</div>';
    return '<div class="feature-row reveal' + (flip ? " flip" : "") + '">' + (flip ? text + code_ : code_ + text) + '</div>';
  }
  function concernGrid(cat, title, items) {
    return '<div class="subhead"><h3>' + title + '</h3><span class="sub">' + items.length + '</span><span class="rule"></span></div>' +
      '<div class="cards compact" data-cardgrid="' + cat + '">' + items.map(function (c) {
        return '<a class="card concern" data-slug="' + c.slug + '" href="#/c/' + c.slug + '">' +
          '<div class="top"><span class="ico">' + c.icon + '</span><span class="nm">' + esc(c.name) + '</span>' +
          '<span class="cat ' + c.category + '">' + c.category + '</span></div>' +
          '<div class="desc">' + esc(c.tagline) + '</div>' +
          '<div class="inc">' + esc(c.include) + '</div></a>';
      }).join("") + '</div>';
  }
  function apiCard(sig, desc) { return '<div class="card api-card"><p class="sig">' + esc(sig) + '</p><p class="desc">' + desc + '</p></div>'; }
  function stat(n, l) { return '<div class="s"><div class="n">' + esc(String(n)) + '</div><div class="l">' + esc(l) + '</div></div>'; }
  function metaRow(k, v) { return '<div class="row"><span class="k">' + esc(k) + '</span><span class="v">' + esc(v) + '</span></div>'; }

  function footer() {
    var r = esc(META.repo);
    return '<footer class="site-footer"><div class="wrap">' +
      '<div class="top"><div>' +
        '<h2>Built in the open. Join in.</h2>' +
        '<p>Bug reports, new concern proposals and docs fixes all welcome. Open an issue and we\'ll take it from there.</p></div>' +
        '<div style="display:flex;flex-wrap:wrap;gap:.75rem">' +
          '<a class="btn btn-ruby" href="' + r + '/issues" target="_blank" rel="noopener">Open an issue</a>' +
          '<a class="btn" style="color:var(--code-fg);border-color:#41392f" href="' + r + '" target="_blank" rel="noopener">View on GitHub</a>' +
        '</div></div>' +
      '<div class="cols">' +
        '<div><div class="brand-mini"><img class="logo" src="assets/img/ruby.png" alt="" width="28" height="28" /><span class="name mono" style="font-weight:700">concerns_on_rails</span></div>' +
          '<p class="blurb">Reusable ActiveSupport concerns for Rails models &amp; controllers. MIT licensed.</p></div>' +
        '<div><p class="col-h">Docs</p><ul>' +
          '<li><a href="#/c/sluggable">Concern reference</a></li>' +
          '<li><a href="#start" data-scroll="start">Quick start</a></li>' +
          '<li><a href="#usage" data-scroll="usage">Examples</a></li></ul></div>' +
        '<div><p class="col-h">Project</p><ul>' +
          '<li><a href="' + r + '" target="_blank" rel="noopener">GitHub</a></li>' +
          (META.rubygems ? '<li><a href="' + esc(META.rubygems) + '" target="_blank" rel="noopener">RubyGems</a></li>' : '') +
          '<li><a href="' + r + '/blob/master/CHANGELOG.md" target="_blank" rel="noopener">Changelog</a></li></ul></div>' +
        '<div><p class="col-h">Community</p><ul>' +
          '<li><a href="' + r + '/issues" target="_blank" rel="noopener">Issues</a></li>' +
          '<li><a href="' + r + '/blob/master/CODE_OF_CONDUCT.md" target="_blank" rel="noopener">Code of conduct</a></li>' +
          '<li><a href="' + r + '/blob/master/MIT-LICENSE" target="_blank" rel="noopener">MIT License</a></li></ul></div>' +
      '</div>' +
      '<p class="copy-line">© concerns_on_rails contributors · Released under the MIT License.</p>' +
    '</div></footer>';
  }

  /* ============================================================
     CONCERN DOC PAGE
     ============================================================ */
  function renderConcern(slug) {
    var c = BY_SLUG[slug];
    if (!c) { renderNotFound(slug); return; }
    teardownToc();
    document.body.className = "route-doc";
    setActiveNav(slug);
    document.title = c.name + " — concerns_on_rails";

    var idx = CONCERNS.indexOf(c);
    var prev = CONCERNS[idx - 1], next = CONCERNS[idx + 1];

    var header = '<div class="breadcrumb"><a href="#/">Home</a> &nbsp;/&nbsp; ' +
      (c.category === "model" ? "Model concerns" : "Controller concerns") + ' &nbsp;/&nbsp; ' + esc(c.name) + '</div>' +
      '<div class="doc-title"><span class="ico">' + c.icon + '</span><h1>' + esc(c.name) + '</h1><span class="cat ' + c.category + '">' + c.category + '</span></div>' +
      '<p class="doc-tagline">' + esc(c.tagline) + '</p>' +
      '<div class="doc-meta"><span class="include">' + esc(c.include) + '</span>' +
        '<button class="copybtn" type="button" data-copy="include ' + esc(c.include) + '">' + COPY_ICON + ' copy include</button>' +
        '<a class="src" href="' + srcUrl(c) + '" target="_blank" rel="noopener">' + GH_SVG + ' View source</a></div>' +
      '<hr class="doc-rule">';

    view.innerHTML = header + '<div class="md" id="docMd"><div class="loading">Loading documentation…</div></div>' +
      '<aside class="toc" id="toc" hidden></aside>';
    window.scrollTo(0, 0);

    loadDoc(slug).then(function (md) {
      var t = document.getElementById("docMd"); if (!t) return;
      t.innerHTML = marked.parse(md);
      stripLeadingH1(t);
      enhanceCode(t);
      var toc = buildToc(t);
      t.insertAdjacentHTML("beforeend", pager(prev, next));
      if (toc) scrollSpy(t);
    }).catch(function (err) {
      var t = document.getElementById("docMd"); if (t) t.innerHTML = docError(slug, err);
    });
  }
  function loadDoc(slug) {
    if (mdCache[slug]) return Promise.resolve(mdCache[slug]);
    return fetch("concerns/" + slug + ".md", { cache: "no-cache" }).then(function (r) {
      if (!r.ok) throw new Error("HTTP " + r.status); return r.text();
    }).then(function (t) { mdCache[slug] = t; return t; });
  }
  function stripLeadingH1(c) { var f = c.firstElementChild; if (f && f.tagName === "H1") f.remove(); }

  /* ---------- code rendering ---------- */
  function highlightAll(container) {
    container.querySelectorAll("pre > code").forEach(function (code) { try { if (window.hljs) hljs.highlightElement(code); } catch (e) {} });
  }
  function enhanceCode(container) {
    container.querySelectorAll("pre > code").forEach(function (code) {
      var pre = code.parentElement;
      if (pre.closest(".code-wrap, .term")) { try { hljs.highlightElement(code); } catch (e) {} return; }
      var lang = "ruby";
      (code.className || "").split(/\s+/).forEach(function (cls) { if (cls.indexOf("language-") === 0) lang = cls.slice(9); });
      try { if (window.hljs) hljs.highlightElement(code); } catch (e) {}
      var wrap = document.createElement("div"); wrap.className = "code-wrap";
      var bar = document.createElement("div"); bar.className = "term-bar";
      bar.innerHTML = '<span class="dot r"></span><span class="dot y"></span><span class="dot g"></span><span class="term-file">' + esc(lang) + '</span><button class="copybtn" type="button">' + COPY_ICON + ' copy</button>';
      pre.parentNode.insertBefore(wrap, pre);
      wrap.appendChild(bar); wrap.appendChild(pre);
    });
  }

  function buildToc(container) {
    var toc = document.getElementById("toc"); if (!toc) return null;
    var heads = container.querySelectorAll("h2, h3");
    if (heads.length < 2) { toc.hidden = true; return null; }
    var used = {}, links = "";
    heads.forEach(function (h) {
      var base = slugify(h.textContent) || "section", id = base, n = 2;
      while (used[id]) { id = base + "-" + n++; } used[id] = true; h.id = id;
      var a = document.createElement("a"); a.className = "anchor"; a.href = "#"; a.setAttribute("aria-hidden", "true"); a.textContent = "#";
      a.addEventListener("click", function (ev) { ev.preventDefault(); jumpTo(id); });
      h.appendChild(a);
      links += '<a href="#" class="lvl-' + (h.tagName === "H3" ? 3 : 2) + '" data-target="' + id + '">' + esc(h.textContent.replace(/#$/, "")) + '</a>';
    });
    toc.innerHTML = '<div class="label">On this page</div>' + links;
    toc.hidden = false;
    toc.querySelectorAll("a[data-target]").forEach(function (a) { a.addEventListener("click", function (ev) { ev.preventDefault(); jumpTo(a.getAttribute("data-target")); }); });
    return toc;
  }
  function jumpTo(id) { var e = document.getElementById(id); if (e) e.scrollIntoView({ behavior: "smooth", block: "start" }); }
  function scrollSpy(container) {
    var toc = document.getElementById("toc"); if (!toc) return;
    var links = {}; toc.querySelectorAll("a[data-target]").forEach(function (a) { links[a.getAttribute("data-target")] = a; });
    tocObserver = new IntersectionObserver(function (entries) {
      entries.forEach(function (en) {
        if (en.isIntersecting) { Object.keys(links).forEach(function (k) { links[k].classList.remove("active"); }); if (links[en.target.id]) links[en.target.id].classList.add("active"); }
      });
    }, { rootMargin: "-70px 0px -70% 0px", threshold: 0 });
    container.querySelectorAll("h2, h3").forEach(function (h) { tocObserver.observe(h); });
  }
  function teardownToc() { if (tocObserver) { tocObserver.disconnect(); tocObserver = null; } }

  function pager(prev, next) {
    var h = '<div class="pager">';
    h += prev ? '<a class="prev" href="#/c/' + prev.slug + '"><div class="dir">← Previous</div><div class="ttl">' + prev.icon + " " + esc(prev.name) + '</div></a>' : '<span style="flex:1"></span>';
    h += next ? '<a class="next" href="#/c/' + next.slug + '"><div class="dir">Next →</div><div class="ttl">' + esc(next.name) + " " + next.icon + '</div></a>' : '<span style="flex:1"></span>';
    return h + '</div>';
  }
  function docError(slug, err) {
    var onFile = location.protocol === "file:";
    return '<div class="error-box"><strong>Couldn\'t load <code>concerns/' + esc(slug) + '.md</code></strong> (' + esc(err.message || err) + ').' +
      (onFile ? '<p style="margin:.6rem 0 0">Opening from <code>file://</code> blocks <code>fetch()</code>. Serve over HTTP: <code>cd docs &amp;&amp; python3 -m http.server 8000</code></p>'
              : '<p style="margin:.6rem 0 0">The documentation file may not be deployed yet.</p>') + '</div>';
  }
  function renderNotFound(slug) {
    teardownToc(); document.body.className = "route-doc"; setActiveNav(null);
    view.innerHTML = '<div class="error-box"><strong>Unknown concern: <code>' + esc(slug || "") + '</code></strong><p style="margin:.6rem 0 0"><a href="#/">← Back to home</a></p></div>';
    document.title = "Not found — concerns_on_rails";
  }

  /* ---------- reveal-on-scroll ---------- */
  function revealCheck() {
    var vh = window.innerHeight || document.documentElement.clientHeight;
    document.querySelectorAll(".reveal:not(.in)").forEach(function (el) {
      if (el.getBoundingClientRect().top < vh * 0.92) el.classList.add("in");
    });
  }
  function revealInit() { revealCheck(); setTimeout(function () { document.querySelectorAll(".reveal").forEach(function (el) { el.classList.add("in"); }); }, 1400); }

  /* ---------- routing ---------- */
  function currentSlug() { var m = location.hash.replace(/^#\/?/, "").match(/^c\/([^:/]+)/); return m ? m[1] : null; }
  function route() {
    var h = location.hash;
    if (h && h !== "#/" && h.indexOf("#/") !== 0) return; // in-page anchor (#features) — ignore
    closeNav();
    var slug = currentSlug();
    if (slug) renderConcern(slug); else renderHome();
  }

  /* ---------- theme ---------- */
  function initTheme() {
    var saved = null; try { saved = localStorage.getItem("cor-theme"); } catch (e) {}
    if (saved === "dark") document.documentElement.setAttribute("data-theme", "dark");
    else document.documentElement.removeAttribute("data-theme");
  }
  function toggleTheme() {
    var dark = document.documentElement.getAttribute("data-theme") === "dark";
    if (dark) { document.documentElement.removeAttribute("data-theme"); try { localStorage.setItem("cor-theme", "paper"); } catch (e) {} }
    else { document.documentElement.setAttribute("data-theme", "dark"); try { localStorage.setItem("cor-theme", "dark"); } catch (e) {} }
  }

  function closeNav() { document.body.classList.remove("nav-open"); }

  /* ---------- init ---------- */
  function init() {
    initTheme();
    var vb = document.getElementById("verBadge"); if (vb) vb.textContent = "v" + META.version;
    var gh = document.getElementById("ghLink"); if (gh) gh.href = META.repo;

    buildSidebar();

    document.getElementById("themeToggle").addEventListener("click", toggleTheme);
    document.getElementById("menuToggle").addEventListener("click", function () { document.body.classList.toggle("nav-open"); });
    document.getElementById("backdrop").addEventListener("click", closeNav);

    searchInput.addEventListener("input", applySearch);
    searchInput.addEventListener("keydown", function (e) { if (e.key === "Escape") { searchInput.value = ""; applySearch(); searchInput.blur(); } });
    document.addEventListener("keydown", function (e) {
      if (e.key === "/" && document.activeElement !== searchInput && !/^(INPUT|TEXTAREA)$/.test((document.activeElement || {}).tagName || "")) { e.preventDefault(); searchInput.focus(); }
    });

    // in-page anchor scrolling (landing nav + footer) without touching the route hash
    document.addEventListener("click", function (e) {
      var a = e.target.closest ? e.target.closest("[data-scroll]") : null;
      if (!a) return;
      e.preventDefault();
      if (currentSlug()) { location.hash = "#/"; setTimeout(function () { jumpTo(a.getAttribute("data-scroll")); }, 60); }
      else jumpTo(a.getAttribute("data-scroll"));
    });

    window.addEventListener("scroll", revealCheck, { passive: true });
    window.addEventListener("hashchange", route);
    route();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
