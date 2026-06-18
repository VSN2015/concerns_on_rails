<div align="center">

# 🧩 ConcernsOnRails

**Plug-and-play ActiveSupport concerns for Rails models &amp; controllers.**<br/>
One `include`, one declarative macro — done.

[![Gem Version](https://img.shields.io/gem/v/concerns_on_rails?logo=rubygems&logoColor=white&color=CC342D)](https://rubygems.org/gems/concerns_on_rails)
[![Downloads](https://img.shields.io/gem/dt/concerns_on_rails?color=1f6feb)](https://rubygems.org/gems/concerns_on_rails)
[![CI](https://github.com/VSN2015/concerns_on_rails/actions/workflows/ci.yml/badge.svg)](https://github.com/VSN2015/concerns_on_rails/actions/workflows/ci.yml)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.2-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org)
[![Rails](https://img.shields.io/badge/rails-5.0--8.x-CC0000?logo=rubyonrails&logoColor=white)](https://rubyonrails.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-3fb950.svg)](#-license)

🧩 **23 model concerns** &nbsp;·&nbsp; 🎮 **16 controller concerns** &nbsp;·&nbsp; 🪶 **lean deps** &nbsp;·&nbsp; ✅ **schema-validated**

</div>

> 🇻🇳 **Hoàng Sa and Trường Sa belong to Việt Nam.**

A plug-and-play collection of reusable ActiveSupport concerns for Rails **models** and **controllers** — slugs, soft delete, scheduled publish, expiry, sequential reference numbers, pagination, filtering, JSON envelopes, and more. One `include`, one declarative macro, done.

```ruby
class Article < ApplicationRecord
  include ConcernsOnRails::Sluggable
  include ConcernsOnRails::Publishable
  include ConcernsOnRails::SoftDeletable

  sluggable_by :title
end

Article.published.without_deleted.find("hello-world")
```

---

## 📚 Table of Contents

[Why this gem?](#-why-this-gem) &nbsp;·&nbsp; [Installation](#-installation) &nbsp;·&nbsp; [Compatibility](#-compatibility) &nbsp;·&nbsp; [Quick Start](#-quick-start) &nbsp;·&nbsp; [Module paths](#-module-paths--namespacing) &nbsp;·&nbsp; [Development](#-development) &nbsp;·&nbsp; [Contributing](#-contributing) &nbsp;·&nbsp; [License](#-license)

### 🧱 Model concerns

| Concern | What it does |
|---------|--------------|
| [📝 Sluggable](#-sluggable) | URL-friendly slugs |
| [🔢 Sortable](#-sortable) | List ordering via `acts_as_list` |
| [📤 Publishable](#-publishable) | `published_at` timestamp publishing |
| [❌ SoftDeletable](#-softdeletable) | Soft delete with scopes &amp; hooks |
| [🔐 Hashable](#-hashable) | Auto-generate tokens / UUIDs / codes |
| [🗓️ Schedulable](#-schedulable) | `starts_at` / `ends_at` time windows |
| [⏳ Expirable](#-expirable) | Single-timestamp expiry |
| [✨ Normalizable](#-normalizable) | Attribute normalization (`:email`, `:phone`, …) |
| [🔍 Searchable](#-searchable) | LIKE / ILIKE search across columns |
| [✅ Activatable](#-activatable) | Boolean active / inactive toggle |
| [🔑 Tokenizable](#-tokenizable) | Security tokens with timing-safe lookup |
| [🧾 Sequenceable](#-sequenceable) | Ordered, human-friendly reference numbers |
| [🔄 Stateable](#-stateable) | Lightweight string-backed state machine |
| [🏠 Addressable](#-addressable) | Postal address normalization + validation |
| [🏷️ Taggable](#-taggable) | Lightweight tagging over a single column |
| [🧼 Sanitizable](#-sanitizable) | Opt-in HTML sanitization (XSS defense) |
| [🙈 Maskable](#-maskable) | Non-destructive display masking |
| [💰 Monetizable](#-monetizable) | Integer-cents money columns (BigDecimal) |
| [📜 Auditable](#-auditable) | Single-column change history ("paper_trail-lite") |
| [🔐 Lockable](#-lockable) | Failed-attempt tracking + account lockout |
| [🪞 Aliasable](#-aliasable) | Full read / write / query association aliases |
| [⚙️ Storable](#-storable) | Typed accessors over one JSON column ("store_attribute-lite") |
| [🧮 CounterCacheable](#-countercacheable) | Conditional denormalized counters ("counter_culture-lite") |

### 🎮 Controller concerns

| Concern | What it does |
|---------|--------------|
| [📄 Paginatable](#-paginatable) | Offset pagination with headers |
| [🧭 CursorPaginatable](#-cursorpaginatable) | Cursor (keyset) pagination with headers |
| [🔎 Filterable](#-filterable) | Declarative URL-param filters |
| [↕️ Sortable (controller)](#-sortable-controller) | URL-param ordering with allow-list |
| [📦 Respondable](#-respondable) | Standardized JSON envelopes |
| [🛟 ErrorHandleable](#-errorhandleable) | JSON `rescue_from` handlers |
| [🔗 Includable](#-includable) | Association sideloading + sparse fieldsets |
| [🛡️ SecureHeadable](#-secureheadable) | Security response headers + native CSP DSL |
| [🌐 Localizable](#-localizable) | Per-request locale from params / `Accept-Language` |
| [🔒 Authorizable](#-authorizable) | Per-action 403 authorization gate |
| [🚦 Throttleable](#-throttleable) | Rate limiting (429 + `X-RateLimit-*`) |
| [🕒 Timezoneable](#-timezoneable) | Per-request `Time.zone` from params / header / cookie |
| [🔁 Idempotentable](#-idempotentable) | `Idempotency-Key` request replay |
| [🪝 WebhookVerifiable](#-webhookverifiable) | HMAC verification for inbound webhooks |
| [🌅 Deprecatable](#-deprecatable) | RFC `Deprecation` / `Sunset` headers + 410 |
| [🗄️ Cacheable](#-cacheable) | HTTP conditional GET (ETag / 304) + `Cache-Control` |

---

## ✨ Why this gem?

- **Twenty-three model concerns + sixteen controller concerns**, all production-ready
- **One include, one macro** — no boilerplate, no glue code
- **Lean dependencies** — only `acts_as_list` (Sortable) and `friendly_id` (Sluggable); controller concerns have zero extra deps
- **Schema-validated configuration** — every macro checks that the configured column exists and raises `ArgumentError` early
- **Composable** — concerns are independent; mix and match per model

---

## 📦 Installation

Add to your application's `Gemfile`:

```ruby
gem "concerns_on_rails", "~> 1.11"
```

Or pull the latest from GitHub:

```ruby
gem "concerns_on_rails", github: "VSN2015/concerns_on_rails"
```

Then run:

```sh
bundle install
```

---

## 🧪 Compatibility

- **Ruby**: 3.2+
- **Rails**: 5.0 through 8.x

---

## 🚀 Quick Start

```ruby
# A model that's sluggable, publishable, and soft-deletable
class Article < ApplicationRecord
  include ConcernsOnRails::Sluggable
  include ConcernsOnRails::Publishable
  include ConcernsOnRails::SoftDeletable
  include ConcernsOnRails::Normalizable

  sluggable_by    :title
  normalizable    :title, with: :squish
end

# A controller that paginates, filters, sorts, and renders JSON envelopes
class ArticlesController < ApplicationController
  include ConcernsOnRails::Controllers::Paginatable
  include ConcernsOnRails::Controllers::Filterable
  include ConcernsOnRails::Controllers::Sortable
  include ConcernsOnRails::Controllers::Respondable

  filter_by   :published, scope: :published
  sortable_by :created_at, :title, default: :created_at, direction: :desc

  def index
    render_success(data: paginated(sorted(filtered(Article.all))))
  end
end
```

That's it. The sections below document each concern individually.

---

# 🧱 Model Concerns

All model concerns are independent — `include` only what you need.

## 📝 Sluggable

URL-friendly slugs via [`friendly_id`](https://github.com/norman/friendly_id) — auto-updates when the source attribute changes.

```ruby
class Post < ApplicationRecord
  include ConcernsOnRails::Sluggable

  sluggable_by :title
end

post = Post.create!(title: "Hello World")
post.slug              # => "hello-world"
post.update!(title: "Hello, World!")
post.slug              # => "hello-world"  (regenerates on title change)

Post.friendly.find("hello-world")
```

**Options**

```ruby
# Keep old slugs resolvable after a title change (needs a friendly_id_slugs migration)
sluggable_by :title, history: true
Post.friendly.find("old-slug")   # still resolves to the renamed post

# Unique slug only within a scope column (same slug allowed in different accounts)
sluggable_by :title, scope: :account_id

# Reject reserved slugs — saving a record whose slug would be reserved fails validation
sluggable_by :title, reserved_words: %w[new edit admin]

# Let Model.find accept a slug directly (not just the id)
sluggable_by :title, finders: true
Post.find("hello-world")   # resolves by slug
```

**Notes**
- Schema must have a `slug` column (string).
- `history: true` requires a `friendly_id_slugs` table — generate with `rails generate friendly_id` or add a manual migration.
- `scope: :col` requires `col` to exist in the same table.
- Falls back to `to_s` if the configured source field doesn't respond.
- Uses friendly_id's `:slugged` (+ optionally `:history`, `:scoped`) strategies under the hood.

---

## 🔢 Sortable

List ordering via [`acts_as_list`](https://github.com/brendon/acts_as_list) — adds a `default_scope` ordering plus `move_higher`, `move_lower`, `move_to_top`, `move_to_bottom`, and automatic position reordering on destroy.

```ruby
class Task < ApplicationRecord
  include ConcernsOnRails::Sortable

  sortable_by :position           # default — ascending
end

Task.create!(name: "A")
Task.create!(name: "B")
Task.last.move_higher
```

**Configuration**

```ruby
sortable_by :priority                       # ascending priority
sortable_by priority: :desc                 # descending priority
sortable_by :position, use_acts_as_list: false   # just the default_scope ordering, no acts_as_list
sortable_by :position, scope: :list_id           # independent position sequence per list (acts_as_list scope:)
sortable_by :position, add_new_at: :top          # new rows insert at the top (acts_as_list add_new_at:)
```

**Notes**
- The configured field must exist as a column.
- Direction values other than `:asc` / `:desc` silently fall back to `:asc`.

---

## 📤 Publishable

Manage published / unpublished records via a `published_at` timestamp.

```ruby
class Article < ApplicationRecord
  include ConcernsOnRails::Publishable

  publishable_by :published_at   # default — call is optional
end

article = Article.create!(title: "Draft")
article.published?      # => false
article.publish!
article.published?      # => true
article.unpublish!

Article.published       # WHERE published_at <= NOW()
Article.unpublished     # WHERE published_at IS NULL OR published_at > NOW()
Article.scheduled       # WHERE published_at > NOW()  (future-dated — not live yet)
Article.draft           # WHERE published_at IS NULL  (no date set at all)
```

**Scheduling**

```ruby
article.publish_at!(1.week.from_now)   # sets published_at to a future time
article.scheduled?                      # => true (not live yet)
article.draft?                          # => false
```

**Opt-in default scope**

```ruby
publishable_by :published_at, default_scope: true
# Article.all now returns only published records automatically
# Article.unscoped reaches everything
```

**Notes**
- "Published" means `published_at` is set **and** in the past — so future-dated posts stay unpublished until their time arrives.
- No `default_scope` is added by default; chain `.published` explicitly (or opt in with `default_scope: true`).

---

## ❌ SoftDeletable

Soft delete records using a timestamp field (default: `deleted_at`). By default a `default_scope` hides deleted records — **opt out** with `soft_deletable_by :deleted_at, default_scope: false` and chain `.without_deleted` explicitly (the safer choice for new models, avoiding `default_scope`'s join/uniqueness footguns). `soft_delete!` / `restore!` and the bulk helpers run inside a transaction, so a raising hook rolls the change back.

```ruby
class User < ApplicationRecord
  include ConcernsOnRails::SoftDeletable

  soft_deletable_by :deleted_at, touch: true   # both args optional
end

user = User.create!(email: "alice@example.com")
user.soft_delete!
user.deleted?              # => true
user.restore!
user.deleted?              # => false

user.really_delete!        # bypasses callbacks, hard deletes from DB
```

**Scopes**

```ruby
User.active               # alias of .without_deleted — non-deleted records
User.without_deleted      # same
User.soft_deleted         # only deleted records (timestamp set)
User.only_deleted         # alias for .soft_deleted
User.with_deleted         # all records — deleted + non-deleted
User.deleted_within(7.days)  # soft-deleted within the last 7 days
User.all                  # default scope: non-deleted only
User.unscoped             # everything (deleted + non-deleted)
```

**Bulk operations**

```ruby
User.soft_delete_all      # soft-deletes all matching records (explicit — preferred)
User.destroy_all          # alias of soft_delete_all (kept for backwards compatibility)
User.really_destroy_all   # hard-deletes all matching records
User.restore_all          # restores all soft-deleted records
```

All of these run in a transaction, so a raising hook rolls the whole batch back.

**Lifecycle hooks** — override these methods on the model:

```ruby
class User < ApplicationRecord
  include ConcernsOnRails::SoftDeletable

  def before_soft_delete; end
  def after_soft_delete;  end
  def before_restore;     end
  def after_restore;      end
end
```

**Aliases**: `soft_deleted?` and `is_soft_deleted?` both delegate to `deleted?`.

---

## 🔐 Hashable

Auto-generate random values on create — tokens, codes, UUIDs, or anything from a custom alphabet.

```ruby
class Order < ApplicationRecord
  include ConcernsOnRails::Hashable

  hashable_by :token   # default: type: :hex, length: 16 → 32-char hex string
end

order = Order.create!
order.token              # => "a3f7c9b1e2d40859e2f1c9b73d40a857"
order.regenerate_token!  # rolls a new value and persists it
```

**Generators**

| Type       | `length` means                                | Example                                  |
|------------|-----------------------------------------------|------------------------------------------|
| `:hex`     | byte count (output is `length * 2` chars)     | `"a3f7c9b1e2d40859"`                     |
| `:uuid`    | ignored                                       | `"550e8400-e29b-41d4-a716-446655440000"` |
| `:integer` | digit count                                   | `483921`                                 |
| `:custom`  | output length, samples from `alphabet:`       | `"K7M3PQ9A"`                             |

```ruby
hashable_by :token,       type: :hex,     length: 16
hashable_by :external_id, type: :uuid
hashable_by :code,        type: :integer, length: 6
hashable_by :code,        type: :custom,  length: 8,
            alphabet: "ABCDEFGHJKMNPQRSTUVWXYZ23456789"   # Crockford-style, no ambiguous chars
```

**Notes**
- Auto-assigns in `before_create` only when the field is blank — callers can pass an explicit value.
- A `regenerate_<field>!` instance method is defined dynamically.
- For fixed-width numeric codes (e.g. `000042`), use a **string** column — integer columns drop leading zeros.
- No uniqueness retry is built in. For collision-prone configs (short integer codes), add a unique index and rescue at the app level.
- If your model has `validates :<field>, presence: true`, switch this concern's hook to `before_validation` in your model — it uses `before_create` by default.

---

## 🗓️ Schedulable

Records with a `starts_at` / `ends_at` time window — promotions, events, feature flags.

```ruby
class Promotion < ApplicationRecord
  include ConcernsOnRails::Schedulable

  schedulable_by   # defaults: starts_at: :starts_at, ends_at: :ends_at
end

promo = Promotion.create!(starts_at: 1.hour.ago, ends_at: 1.day.from_now)
promo.current?     # => true
promo.upcoming?    # => false
promo.expired?     # => false

Promotion.current                    # WHERE starts_at <= NOW AND (ends_at IS NULL OR ends_at > NOW)
Promotion.upcoming                   # WHERE starts_at > NOW
Promotion.expired                    # WHERE ends_at <= NOW
Promotion.active_at(time)            # active at an arbitrary time
```

**Configuration**

```ruby
# Custom column names
schedulable_by starts_at: :starts_on, ends_at: :ends_on

# Open-ended start (only an end / expiry)
schedulable_by starts_at: nil, ends_at: :expires_at
```

**Mutators**

```ruby
promo.start!                                                # sets starts_at = now
promo.finish!                                               # sets ends_at   = now
promo.reschedule!(starts_at: 1.day.from_now,
                  ends_at:   2.days.from_now)
```

**Notes**
- Boundary semantics: **inclusive start, exclusive end** — active at exactly `starts_at`, not at exactly `ends_at`.
- A `nil` end means "never expires"; a `nil` start means "not yet started".
- No `default_scope`; chain `.current` explicitly.

---

## ⏳ Expirable

Single-timestamp expiry — tokens, sessions, password-reset links, invitations.

```ruby
class ApiToken < ApplicationRecord
  include ConcernsOnRails::Expirable

  expirable_by   # default field: :expires_at
end

token = ApiToken.create!(expires_at: 1.hour.from_now)
token.active?               # => true
token.expired?              # => false
token.time_until_expiry     # => ActiveSupport::Duration (~1.hour)

ApiToken.active                  # nil expiry OR future expiry
ApiToken.expired                 # past expiry
ApiToken.expiring_within(1.day)  # future expiry within the next 1 day
```

**Mutators**

```ruby
token.expire!                       # expires_at = now
token.expire!(2.hours.from_now)     # explicit time
token.extend_expiry!(by: 1.day)     # pushes expiry forward
```

`extend_expiry!` is smart about the base:
- If `expires_at` is `nil` or in the past → new value is `now + by`
- If `expires_at` is still in the future → `by` is added to the existing value

**Custom field name**

```ruby
expirable_by :valid_until
```

**Expirable vs. Schedulable**: `Expirable` is the ergonomic choice when you just care about expiry; `Schedulable` adds a start time. They overlap (`schedulable_by starts_at: nil, ends_at: :expires_at` is similar) — pick whichever reads better in your domain.

---

## ✨ Normalizable

Auto-normalize attribute values in `before_validation` — strip whitespace, downcase emails, dedupe spaces, run any custom transform.

```ruby
class User < ApplicationRecord
  include ConcernsOnRails::Normalizable

  normalizable :email,                  with: :email                       # strip + downcase
  normalizable :phone,                  with: :phone                       # digits only
  normalizable :first_name, :last_name, with: :whitespace                  # strip — same rule, multiple fields
  normalizable :slug,                   with: ->(v) { v.to_s.parameterize } # custom lambda
end

User.create(email: "  ALICE@Example.com  ").email   # => "alice@example.com"
User.create(phone: "+1 (415) 555-1234").phone       # => "14155551234"
```

**Built-in presets**

| Preset       | Transform                                |
|--------------|------------------------------------------|
| `:email`     | `strip` + `downcase`                     |
| `:phone`     | digits only (`gsub(/\D/, "")`)           |
| `:whitespace`| `strip`                                  |
| `:squish`    | `squish` (collapse inner whitespace)     |
| `:downcase`  | `downcase`                               |
| `:upcase`    | `upcase`                                 |

**Notes**
- Runs in `before_validation`, so DB constraints and AR validations see the normalized value.
- `nil` values are skipped — no `nil → ""` coercion.
- Preset normalizers pass non-string values through unchanged.
- Works on Rails 5+ (no dependency on Rails 7.1's built-in `normalizes`).

---

## 🔍 Searchable

LIKE-based search across one or more columns — no external search engine, no extra gems.

```ruby
class Article < ApplicationRecord
  include ConcernsOnRails::Searchable

  searchable_by :title, :body
end

Article.search("hello")                # WHERE title ILIKE '%hello%' OR body ILIKE '%hello%'
Article.search("")                     # no-op — returns the full relation
Article.search("foo").where(state: 1)  # chainable like any scope
```

**Options**

```ruby
# mode: :any (default) — any term in any field matches (OR)
# mode: :all           — every whitespace-separated term must match somewhere (AND per term, OR across fields)
searchable_by :title, :body, mode: :all
Article.search("ruby framework")  # title OR body must contain "ruby" AND "framework"

# match: :contains (default) — %term% (substring)
# match: :prefix           — term%  (starts with)
# match: :exact            — term   (full match)
searchable_by :sku, match: :prefix
```

**Notes**
- Uses Arel's `matches`, which emits `ILIKE` on Postgres (case-insensitive) and `LIKE` elsewhere.
- The query is escaped before interpolation — `%`, `_`, and `\` from user input are treated as literals, not wildcards.
- Blank or nil queries return the relation unchanged, so it's safe to drop into a controller pipeline.
- Reach for `pg_search` / Elasticsearch when you need ranking, stemming, or full-text indexes.

---

## ✅ Activatable

Boolean active/inactive toggle backed by a single column.

```ruby
class Subscription < ApplicationRecord
  include ConcernsOnRails::Activatable

  activatable_by               # defaults to :active
  # activatable_by :enabled    # custom column name
end

sub = Subscription.create!(active: true)
sub.active?            # => true
sub.deactivate!
sub.inactive?          # => true
sub.toggle_active!     # flips back to true

Subscription.active     # WHERE active = TRUE
Subscription.inactive   # WHERE active = FALSE OR active IS NULL
```

**Notes**
- `NULL` is treated as inactive (same convention as most apps' "unset = off").
- The configured column must exist; `activatable_by` raises `ArgumentError` otherwise.
- `SoftDeletable` also defines a `.active` scope (alias of `.without_deleted`). If both concerns are included on the same model, the later one wins — include the one whose `.active` semantics you want last, or stick to one of them.

---

## 🔑 Tokenizable

Generate and manage security tokens — API keys, invite codes, share links, password-reset tokens. One model can declare any number of independently-configured token fields.

```ruby
class User < ApplicationRecord
  include ConcernsOnRails::Tokenizable

  tokenizable_by :api_token                                  # 32-char URL-safe
  tokenizable_by :reset_password_token, length: 24
  tokenizable_by :invite_code, type: :alphanumeric, length: 8
end

user = User.create!                       # all three tokens auto-generated
user.api_token                            # => "k3Jf...g2" (32 URL-safe chars)
user.api_token?                           # => true

user.regenerate_api_token!                # rotates and persists
user.revoke_api_token!                    # nils the column

User.find_by_api_token(token)             # Rails default
User.authenticate_by_api_token(token)     # timing-safe; returns user or nil
```

**Options**

| Option   | Default     | Notes                                                         |
| -------- | ----------- | ------------------------------------------------------------- |
| `type:`  | `:urlsafe`  | One of `:urlsafe`, `:hex`, `:alphanumeric`, `:numeric`        |
| `length:`| `32`        | Character length of the generated token                       |

**Notes**
- URL-safe by default (`A–Z`, `a–z`, `0–9`, `-`, `_`) — drop straight into URLs and headers.
- Caller-supplied values are respected: `User.create!(api_token: "preset")` won't be overwritten.
- Generation does a best-effort uniqueness check before insert and retries up to 10 times. Pair with a `unique` DB index for real safety, especially for short alphanumeric/numeric codes.
- `.authenticate_by_<field>` uses `ActiveSupport::SecurityUtils.secure_compare` to avoid leaking partial matches via response timing.
- Distinct from `Hashable`: Hashable handles a single random field; Tokenizable focuses on security tokens (multi-field, URL-safe default, timing-safe lookup, revocation).

---

## 🧾 Sequenceable

Ordered, human-friendly reference numbers — invoice numbers, order numbers, ticket IDs, support cases. Unlike the *random* identifiers from [Hashable](#-hashable) / [Tokenizable](#-tokenizable), `Sequenceable` produces *sequential* ones backed by an integer column that is the source of truth.

```ruby
class Invoice < ApplicationRecord
  include ConcernsOnRails::Sequenceable

  sequenceable_by :sequence,        # integer column — the source of truth
    into:    :number,               # optional string column for the formatted value
    prefix:  "INV-",
    padding: 5,
    scope:   :account_id,           # one independent counter per account
    reset:   :year                  # restart numbering each calendar year
end

invoice = Invoice.create!(account_id: 1)
invoice.sequence            # => 1, 2, 3 ... (per account, per year)
invoice.number              # => "INV-2026-00001"
invoice.formatted_sequence  # => "INV-2026-00001"

Invoice.next_sequence(account_id: 1)   # => 4  (peek the next value, without creating)
```

**Options**

| Option               | Default     | Purpose                                                                                  |
|----------------------|-------------|------------------------------------------------------------------------------------------|
| `field` (positional) | `:sequence` | Integer column holding the sequence — the source of truth.                               |
| `into:`              | `nil`       | String column to persist the formatted reference into (immutable display value).          |
| `prefix:`            | `""`        | Prepended to the formatted value.                                                        |
| `padding:`           | `0`         | Zero-pad width of the numeric portion (`0` = no padding).                                |
| `separator:`         | `"-"`       | Joins prefix / period token / number in the default format.                              |
| `start_at:`          | `1`         | First value when the scope/period has no rows yet.                                       |
| `scope:`             | `nil`       | Column (or array of columns) the counter is scoped to — e.g. one sequence per `account_id`. |
| `reset:`             | `:never`    | `:never` / `:year` / `:month` / `:day` — restart numbering each period (needs `created_at`). |
| `template:`          | `nil`       | `->(seq, record) { ... }` full custom formatter; overrides `prefix` / `padding` / period. |

**Default format**

| `reset:`  | Example               | Shape                            |
|-----------|-----------------------|----------------------------------|
| `:never`  | `INV-00001`           | `prefix + padded`                |
| `:year`   | `INV-2026-00001`      | `prefix + YYYY + sep + padded`   |
| `:month`  | `INV-202606-00001`    | `prefix + YYYYMM + sep + padded` |
| `:day`    | `INV-20260604-00001`  | `prefix + YYYYMMDD + sep + padded` |

**Generated API**

| Method                            | What it does                                                                          |
|-----------------------------------|---------------------------------------------------------------------------------------|
| `formatted_<field>`               | The formatted string — the persisted `into:` value when set, otherwise computed.      |
| `Model.next_<field>(scope_attrs)` | Peek the next integer for a scope without creating a record.                           |

**Notes**
- The next value is `MAX(<field>) + 1` within the scope (and period), so numbering is dense and ordered — not random.
- Caller-supplied values are respected: `Invoice.create!(sequence: 100)` is not overwritten (and its `into:` string is still formatted from `100`).
- Generation reads `MAX` then inserts, so two concurrent inserts can race. It's **best-effort** — add a **scoped unique index** on `<field>` (and on `into:`) for a real guarantee, the same way you would for any `MAX`-based numbering.
- `reset:` requires a `created_at` column; the period is taken from each row's creation time.
- For fixed-width display (`00042`), make the `into:` column a **string** — integer columns drop leading zeros.
- Distinct from `Hashable` / `Tokenizable`, which generate *random* values; reach for those when the identifier must be unguessable.

---

## 🔄 Stateable

Lightweight string-backed state machine — the 80% of AASM without the dependency.

```ruby
class Article < ApplicationRecord
  include ConcernsOnRails::Stateable

  stateable_by :status,
               states:      %i[draft pending published archived],
               default:     :draft,
               transitions: {
                 publish:  { from: %i[draft pending], to: :published },
                 archive:  { to: :archived }   # no :from → allowed from any state
               }
end
```

**Generated API**

```ruby
article = Article.new          # status defaults to "draft"
article.draft?                 # => true   (predicate per state)
article.published?             # => false

Article.draft                  # scope: WHERE status = 'draft'
Article.published              # scope: WHERE status = 'published'

article.published!             # direct setter — updates regardless of current state
article.publish!               # guarded transition — raises InvalidTransition if not allowed
article.may_publish?           # => true  (guard check without raising)

article.transition_to!(:archived)  # generic move to any declared state
```

**Prefix / suffix** — avoid clashes when the state names overlap with other concerns or scopes:

```ruby
stateable_by :state, states: %i[open closed], prefix: true
# generates: state_open?, state_closed?, state_open!, state_closed!, State.state_open, …
```

**Validation**
- Raises `ArgumentError` if the column, states, default, or transition config is invalid.
- Raises `Stateable::InvalidTransition` at runtime for disallowed guarded transitions.

**Notes**
- String-column backed (not integer-backed like Rails enum) — values are stored as-is.
- States like `active` / `expired` overlap with `Activatable`/`Expirable` scopes — use `prefix:` or `suffix:` to disambiguate.
- No persistence of transition history; combine with `Publishable` / `Schedulable` for time-based state tracking.

---

## 🏠 Addressable

Normalize and format-validate a postal address spread across several columns — one macro for whitespace cleanup, postal-code and ISO country-code checks, required-part presence, and a `full_address` helper. No external geocoding service required.

```ruby
class Location < ApplicationRecord
  include ConcernsOnRails::Addressable

  addressable_by   # standard columns: line1, line2, city, state, postal_code, country
end

loc = Location.create(line1: "  1 Infinite  Loop ", city: "Cupertino",
                      state: "ca", postal_code: "95014", country: "us")
loc.line1         # => "1 Infinite Loop"   (stripped + squished)
loc.state         # => "CA"                (2-letter code upcased)
loc.country       # => "US"
loc.full_address  # => "1 Infinite Loop, Cupertino, CA, 95014, US"
```

Map onto your own column names and tune behavior:

```ruby
class Place < ApplicationRecord
  include ConcernsOnRails::Addressable

  addressable_by line1: :street, postal_code: :zip, country: :country_code,
                 required:        %i[line1 city postal_code country],
                 default_country: "GB",                       # country used when the record has none
                 validate_state:  true,                       # opt-in US/CA state-code check
                 lengths:         { line1: 100, city: 50, postal_code: 5..10 }, # max (Int) or min..max (Range)
                 allow_blank:     %i[state],                   # these parts skip the length check when blank
                 normalize_country: true,                      # "Canada"/"CAN" -> "CA" (off by default)
                 verify_with:     ->(rec) { Usps.verify(rec) } # opt-in external verifier
end
```

**Options**

| Option            | Default                              | Purpose                                                              |
|-------------------|--------------------------------------|---------------------------------------------------------------------|
| `line1:` … `country:` | same-named columns               | Map each canonical part to a real column. Missing columns are skipped. |
| `required:`       | `%i[line1 city postal_code country]` | Parts (by canonical name) that must be present. Each must map to an existing column. |
| `default_country:`| `"US"`                               | Postal-code format used when the country column is **absent or blank**. A present-but-unrecognized country value falls back to the permissive pattern instead — see the postal note below. |
| `validate_state:` | `false`                              | When `true`, validates the state against US / CA code sets.         |
| `lengths:`        | `{}`                                 | Per-part length limits: `{ line1: 100, city: 50, postal_code: 5..10 }`. An Integer is a (positive) maximum; a Range is `min..max` (non-negative, satisfiable; endless `3..` and beginless `..50` allowed). Only the parts you list are checked. Bad bounds raise an `ArgumentError` at load time. |
| `allow_blank:`    | `false`                              | Per-field opt-out for the length check: an Array of parts (e.g. `%i[line2 state]`), or `true` for all parts. A blank value for an allowed part skips its length check. Independent of `required:`. |
| `normalize_country:` | `false`                           | When `true`, canonicalize the country to its ISO 3166-1 alpha-2 code: an English name (`"Canada"`, `"United States"`) or a 3-letter alpha-3 (`"CAN"`, `"USA"`) maps to the alpha-2 (`"CA"`, `"US"`); unrecognized values are left untouched. This also lets postal/state validation recognize a named country. |
| `verify_with:`    | `nil`                                | A callable for real-world verification (see below).                 |
| `if:` / `unless:` | `nil`                                | Standard Rails validation conditions (Symbol, Proc, or Array) gating the address **validations** — e.g. `if: :on_addresses?`. Normalization still runs unconditionally. |

**What it normalizes** (in `before_validation`)
- Text parts: `strip` + `squish`.
- `postal_code`: squish + upcase, with canonical spacing for CA (`A1A1A1` → `A1A 1A1`).
- `country` / `state`: upcased when they look like a 2-letter code (full names left alone). With `normalize_country: true`, a recognized ISO country name or alpha-3 code is canonicalized to its alpha-2 (`"Canada"`/`"CAN"` → `"CA"`); unrecognized values are left as-is.

**What it validates**
- Presence of every `required:` part.
- `country`: a 2-letter value must be a real ISO 3166-1 alpha-2 code.
- `postal_code`: matched against a per-country pattern (US, CA, GB, AU, DE, FR) with a permissive fallback for everything else. A strict per-country pattern is only applied when the country is a recognized ISO alpha-2 code (or `default_country` when the country column is absent/blank); a present-but-unrecognized country (e.g. a full name like `"Canada"`) uses the permissive pattern, so valid foreign codes aren't rejected against the wrong country.
- `state`: only when `validate_state: true` and the country is US/CA.
- `lengths`: each listed part's length (measured on the **normalized** value) must fit its `min..max` (Integer = max only). Errors mirror Rails, including singular/plural: `"is too short (minimum is N characters)"` / `"is too long (maximum is 1 character)"`. A blank value satisfies a max-only rule and, by default, **fails a minimum greater than 0** — list the part in `allow_blank:` to skip the check when blank. `allow_blank` is independent of `required:`: presence is still governed solely by `required:`, so a required part with a minimum that's left blank reports both `"can't be blank"` and `"is too short …"`. Note length is counted *after* normalization, so a CA `postal_code` includes the inserted space (`"A1A 1A1"` is 7) — size limits accordingly.

**External verification (`verify_with:`)** — runs **only after** structural validation passes, so you never spend an API call on an obviously-broken address. The callable receives the record and may either add to `record.errors` itself, or return:

| Return value      | Effect                                          |
|-------------------|-------------------------------------------------|
| `true` / `nil`    | success                                         |
| `false`           | adds a generic `:base` error                    |
| `String`          | added as a `:base` error                        |
| `Array`           | each element added as a `:base` error           |

**Notes**
- Scope is **format/structure only** — it checks shape, not real-world deliverability. Plug a USPS/Google/Smarty client into `verify_with:` for that.
- Error messages are plain English strings — no host-app i18n setup required.
- Partial schemas just work: a model without a `line2` (or any other) column simply omits that part.
- Pairs with [Normalizable](#-normalizable) when you also have non-address fields to clean up.

---

## 🏷️ Taggable

Lightweight, dependency-free tagging stored in a **single string column** — no join tables, no tagging engine. Works on any database, including SQLite.

```ruby
class Article < ApplicationRecord
  include ConcernsOnRails::Taggable

  taggable_by :tags                      # default column :tags
  # taggable_by :skills, downcase: true  # custom column, case-folded
end

article = Article.new
article.tag_list = "Ruby, Rails, Ruby"   # accepts a String or an Array
article.tag_list                          # => ["Ruby", "Rails"]  (stripped + de-duped)
article.add_tags("api")
article.remove_tags("Rails")
article.tagged_with?("ruby")              # => membership predicate
article.save!

Article.tagged_with("ruby", "rails")          # records carrying BOTH tags
Article.tagged_with("ruby", "go", any: true)  # records carrying ANY tag
Article.all_tags                               # => sorted unique tags in use
```

**Options**

| Option       | Default | Purpose                                                          |
|--------------|---------|------------------------------------------------------------------|
| `delimiter:` | `","`   | Character joining the stored tags (a tag must not contain it).    |
| `downcase:`  | `false` | Case-fold tags on write so matching is case-insensitive.          |

**Notes**
- Matching is **boundary-safe** — searching `rail` does not match `rails`. An explicit SQL `ESCAPE` clause makes tags containing `_` / `%` match literally on every adapter.
- Tags are normalized in `before_validation`, so a direct `record.tags = "a, b"` assignment is cleaned too. An empty list stores `NULL`.
- Reach for [`acts-as-taggable-on`](https://github.com/mbleigh/acts-as-taggable-on) when you need tag contexts, ownership, counts/clouds, or polymorphic tags shared across models.

---

## 🧼 Sanitizable

Opt-in HTML sanitization for string attributes — **defense-in-depth, not a replacement for Rails' default output escaping** (`<%= %>` already escapes). Reach for it on the rare column you render as trusted HTML (`raw` / `html_safe`) or that must stay plain text. Zero extra dependencies — it uses the `rails-html-sanitizer` that already ships with Action View.

```ruby
class Article < ApplicationRecord
  include ConcernsOnRails::Sanitizable

  # DEFAULT (on: :read) — non-destructive. The column stays raw; a
  # `sanitized_<field>` reader returns the cleaned value:
  sanitizable :body, with: :safe_list            # => article.sanitized_body
  sanitizable :summary, with: :strip             # => article.sanitized_summary
  sanitizable :body, with: { tags: %w[b i a], attributes: %w[href] }

  # EXPLICIT destructive opt-in — for plain-text-only columns only:
  sanitizable :title, with: :strip, on: :write   # overwrites in before_validation
end

article = Article.new(body: "<b>Hi</b><script>alert(1)</script>")
article.body            # => "<b>Hi</b><script>alert(1)</script>"  (raw, intact)
article.sanitized_body  # => "<b>Hi</b>alert(1)"                    (script tag dropped)
```

**Presets** (`with:`)

| Preset       | Behavior                                                               |
|--------------|------------------------------------------------------------------------|
| `:strip`     | Remove all tags, keep inner text (the default).                        |
| `:safe_list` | Rails' allow-list: keep formatting tags, drop `<script>` / `<iframe>`. |
| `:no_links`  | Strip only `<a>` tags, keep their text.                                |
| `:none`      | No-op (declare the field / reader without transforming).               |
| `Array`      | Custom tag allow-list, e.g. `with: %w[b i a]`.                         |
| `Hash`       | `{ tags: [...], attributes: [...] }` allow-list.                       |
| `Proc`       | Used as-is (you own the non-String guard).                             |

**Notes**
- `on: :read` (default) is **non-destructive**: it adds a `sanitized_<field>` reader and leaves the stored column untouched.
- `on: :write` overwrites the column in `before_validation` — **lossy and irreversible** (never use it on code, Markdown, math, or prices), and bypassed by `update_column` / `update_all` / raw SQL.
- For full user-authored rich text, prefer [Action Text](https://guides.rubyonrails.org/action_text_overview.html).

---

## 🙈 Maskable

Non-destructive display masking for sensitive attributes. Each declaration adds a `masked_<field>` reader and **never writes the column** — the raw value stays in the database (masking is a presentation concern). Dependency-free.

```ruby
class User < ApplicationRecord
  include ConcernsOnRails::Maskable

  maskable :email, with: :email          # => user.masked_email  "j****@example.com"
  maskable :card,  with: :credit_card    # => user.masked_card   "**** **** **** 4242"
  maskable :ssn,   with: :last4, mask: "•"
  maskable :token, with: ->(v) { "#{v.to_s[0, 3]}…" }
end
```

**Presets** (`with:`)

| Preset         | Result                                      |
|----------------|---------------------------------------------|
| `:email`       | `j****@example.com` (first char + domain)   |
| `:phone`       | `***-2671` (last 4 digits)                  |
| `:credit_card` | `**** **** **** 4242` (last 4 digits)       |
| `:last4`       | keep the last 4 characters                  |
| `:all`         | mask every character (the default)          |
| `Proc`         | used as-is (you own the non-String guard)   |

`mask:` sets the mask character (default `*`). Nil and non-string values pass through untouched. To strip dangerous HTML instead, see [Sanitizable](#-sanitizable).

---

## 💰 Monetizable

Money handling for an integer "subunit" column (e.g. cents) — exact and float-free via `BigDecimal`. `monetizable :price_cents` derives three methods (the `_cents` suffix is stripped):

```ruby
class Product < ApplicationRecord
  include ConcernsOnRails::Monetizable

  monetizable :price_cents                          # => price / price= / formatted_price
  monetizable :shipping_cents, as: :shipping
  monetizable :total_cents, unit: "€", delimiter: ".", separator: ","
end

product.price = 19.99   # stores price_cents = 1999 (rounded to whole cents)
product.price           # => BigDecimal 19.99
product.formatted_price # => "$19.99"
```

| Method            | Returns                                       |
|-------------------|-----------------------------------------------|
| `price`           | the amount as a `BigDecimal` (cents ÷ 100)    |
| `price=`          | assign in major units; rounded to whole cents |
| `formatted_price` | a display string (`"$1,234.56"`)              |

**Options**: `as:` (explicit method name — required when the column does not end in `_cents`), `unit:` (`"$"`), `precision:` (`2`), `delimiter:` (`","`), `separator:` (`"."`), `subunit_to_unit:` (`100`). `nil` stays `nil` across all three methods.

---

## 📜 Auditable

Lightweight change history ("paper_trail-lite") stored as JSON entries in **one text column** on the same table — no extra tables, no versioning engine.

```ruby
class Product < ApplicationRecord
  include ConcernsOnRails::Auditable

  auditable_by :price, :status                       # default column :audit_log
  # auditable_by :price, into: :history,
  #              actor: -> { Current.user&.email },  # stamps "by" on each entry
  #              max_entries: 50                     # keep the newest 50
end

product.update!(price: 200)
product.audit_trail
# => [{"field"=>"price", "from"=>100, "to"=>200, "at"=>"2026-06-10T12:34:56Z", "by"=>"admin@shop.com"}]
product.last_change_for(:price)            # newest entry for one field
product.audited_changes_since(1.day.ago)   # recent entries, oldest first
product.clear_audit_trail!                 # wipe the column (skips callbacks)
```

One entry is recorded **per changed field per save** (creates record `"from" => nil`), appended in the same `INSERT`/`UPDATE` via `before_save` — zero extra queries.

**Options**: `into:` (`:audit_log`), `actor:` (callable, `instance_exec`'d on the record; `"by"` omitted when absent), `max_entries:` (`200`; keeps the newest N, `nil` = unlimited), `max_value_length:` (`nil`; truncates long String `from`/`to` values to the first N characters + `…`).

**Notes**
- Writes that skip callbacks (`update_column(s)`, `touch`, `increment!`) are **not** audited; `save(validate: false)` is.
- Values are JSON-coerced (times → ISO8601 UTC strings, `BigDecimal` → precision-safe numeric string); a corrupt column decodes as `[]` and is replaced on the next tracked save.
- Per-record and bounded by design — reach for [`paper_trail`](https://github.com/paper-trail-gem/paper_trail) / [`audited`](https://github.com/collectiveidea/audited) when you need reify/undo or audit queries across models.

---

## 🔐 Lockable

Failed-attempt tracking + **account lockout** ("Devise lockable-lite") for apps rolling their own authentication (Rails 8 auth generator / `has_secure_password`) — which ships **no brute-force protection** out of the box. Two columns on the model's own table; no tokens, no mailers.

```ruby
class User < ApplicationRecord
  include ConcernsOnRails::Lockable

  lockable_by max_attempts: 5, unlock_in: 15.minutes
  # lockable_by attempts: :failed_logins, locked_at: :locked_until_at,
  #             prefix: :account          # => .account_locked / .account_unlocked
end

user.register_failed_attempt!   # atomic SQL increment; locks at max_attempts
user.access_locked?             # true while locked (lapses after unlock_in)
user.attempts_remaining         # => 3   (for "3 attempts remaining" messaging)
user.reset_failed_attempts!     # call on successful login
user.lock_access!               # manual lock     (hooks: before/after_lock)
user.unlock_access!             # manual unlock   (hooks: before/after_unlock)
User.locked / User.unlocked     # expiry-aware scopes
```

**Options**: `attempts:` (`:failed_attempts`, must be an integer column), `locked_at:` (`:locked_at`, datetime column), `max_attempts:` (`5`; `nil` = count but never auto-lock), `unlock_in:` (`nil` = locked until manual unlock; a duration makes the lock lapse by itself), `prefix:` / `suffix:` (affix the scope names).

**Notes**
- The increment is SQL-side (`COALESCE(attempts, 0) + 1` via `update_counters`), so concurrent failures never lose updates and a NULL counter needs no column default; a locked account stops counting.
- Expiry is **lazy**: readers and scopes treat a stale lock as unlocked but never write. The column is cleared by the next `unlock_access!` or failed attempt (quietly there — no unlock hooks fire from a failed login).
- `lock_access!` / `unlock_access!` persist via `update_columns` — validations and AR callbacks deliberately bypassed so an otherwise-invalid record can still be locked (this also skips `updated_at`/`Auditable`). The `before/after_lock`, `before/after_unlock` hooks run in a transaction; `after_lock` is the place for the "account locked" email.
- Reach for Devise's `lockable` when you need unlock tokens, unlock emails, or per-strategy unlocks.

---

## 🪞 Aliasable

Alias an existing association under a second name with **full** semantics — read, write/assign, build/create, and the query side (`joins` / `includes` / `where`-hash) — not just a delegated reader. (`alias_attribute` covers columns only; Rails has no built-in association aliasing.)

```ruby
class Book < ApplicationRecord
  include ConcernsOnRails::Aliasable

  belongs_to :author
  has_many :chapters

  alias_association :writer,   :author      # alias_method order: new, old
  alias_association :sections, :chapters
end

book.writer                   # same cached object as book.author
book.writer = user            # assigns through the original association
book.build_writer(...)        # build_ / create_ / create_! / reload_ (singular)
book.sections << chapter      # the same CollectionProxy as book.chapters
book.section_ids              # ids reader/writer (collection)
Book.joins(:sections).where(sections: { title: "Intro" })
```

**Options**: `alias_association new_name, source_name` — repeatable; declare it **after** the source association; re-declaring an existing alias with the **same** source (e.g. in a subclass that redefined the source) is allowed and refreshes it, while repointing an alias at a *different* source raises. Keyword options: `only:`/`except:` narrow the generated methods by group (`:reader`, `:writer`, `:build`, `:reload`, `:ids`); `deprecated: true` (or a String hint) makes every delegator warn through `ConcernsOnRails.deprecator` — the gradual-rename story; `alias_foreign_key: true` (`belongs_to` only) also aliases `<alias>_id` (and `<alias>_type` when polymorphic) via `alias_attribute`.

**Notes**
- One loaded cache under two names: `record.association(:alias)` IS `record.association(:source)`, and only the source macro installs callbacks — `dependent:`, counter caches, autosave and validations run exactly once.
- The where-hash key must match the name you joined under (stock-Rails rule): `joins(:sections).where(sections: {...})` works; `joins(:chapters).where(sections: {...})` does not.
- The `belongs_to` foreign-key **attribute** is not aliased — pair with `alias_attribute :writer_id, :author_id` if you need it.
- `has_and_belongs_to_many` cannot be aliased (use `has_many :through`). `has_many`/`has_one :through` **can** — the copy pins `source:` so it is not re-derived from the alias name; if your classes load lazily and the through model names the source differently (e.g. `belongs_to :author` behind `has_many :authors`), declare `source:` explicitly on the original association. Aliases are inherited by subclasses.

---

## ⚙️ Storable

Typed, defaulted, optionally-validated accessors over a **single JSON (or text) column** ("store_attribute-lite"). Rails' native `store_accessor` is untyped on every supported version — a form-submitted `"true"` stays the String `"true"` — with no defaults and no per-key dirty tracking; that gap is why the `store_attribute` / `jsonb_accessor` gems exist.

```ruby
class Account < ApplicationRecord
  include ConcernsOnRails::Storable

  storable_by :settings,
    theme:          { type: :string,  default: "light", in: %w[light dark] },
    notifications:  { type: :boolean, default: true },
    items_per_page: { type: :integer, default: 25 },
    trial_ends_at:  { type: :datetime }
  storable_by :flags, { beta: { type: :boolean, default: false } }, prefix: :flag
end

account.theme                     # => "light"  (virtual default; nothing persisted)
account.notifications = "0"       # params arrive as strings…
account.notifications            # => false    (…and read back cast)
account.notifications?           # boolean keys get a predicate
account.items_per_page_changed?  # per-key dirty (and items_per_page_was)
account.reset_theme              # drop the key → the default applies again
account.flag_beta                # affixed accessor
```

**Options** (per key): `type:` (`:string` default, `:integer`, `:float`, `:decimal`, `:boolean`, `:date`, `:datetime`, `:json`), `default:` (a value, or a Proc `instance_exec`'d per read), `in:` (inclusion validation, errors on the accessor name). Macro options: `prefix:` / `suffix:` affix the generated method names (the collision escape hatch). The macro is repeatable — repeat calls for the same column merge keys, different columns are independent, and subclasses can add keys without affecting the parent.

**Notes**
- Works on a plain `text` column (JSON encoded/decoded internally), a native `json`/`jsonb` column, or a column the host app already `serialize`d — detected automatically. `serialize` itself is never used, so the Rails 7.1 API drift is irrelevant.
- nil vs unset: a written `nil` (explicit JSON null) reads back as `nil` and does **not** fall back to the default; `reset_<key>` removes the key so the default applies again. `:decimal` is stored as a precision-safe string, `:date`/`:datetime` as ISO8601 (datetime in UTC at microsecond precision).
- Writing one key dirties (and saves) the **whole column** — concurrent writers to different keys are last-write-wins on the hash. Undeclared keys are preserved. `:json` readers return a dup: reassign, don't mutate in place.
- Generated names are collision-checked against existing methods and columns at macro time (`ArgumentError`; affix to escape). Read-side casting never raises — corrupt column JSON decodes as `{}`, garbage values cast to `nil`.
- Reach for [`store_attribute`](https://github.com/palkan/store_attribute) / [`jsonb_accessor`](https://github.com/madeintandem/jsonb_accessor) when you need to **query** into the store (jsonb operators, store-backed scopes).

---

## 🧮 CounterCacheable

Conditional, denormalized association counters ("counter_culture-lite"). Rails' built-in `belongs_to ..., counter_cache: true` maintains exactly one column counting *every* child — it can't keep an `approved_comments_count` next to a `comments_count`, and has no way to repair drift. Declared on the **child**, this keeps one or many parent columns in sync, each with an optional condition.

```ruby
class Comment < ApplicationRecord
  include ConcernsOnRails::CounterCacheable

  belongs_to :post                       # declare the belongs_to FIRST
  belongs_to :author, class_name: "User"

  counter_cacheable_by :post                                          # posts.comments_count
  counter_cacheable_by :post, count: :approved_comments_count,
                              if: -> { approved? }                    # conditional
  counter_cacheable_by :author, count: :posts_count, touch: true
end

post.comments_count                # maintained on create / destroy / update
Comment.recount_counter_caches!    # repair drift / backfill every counter
```

Counters are adjusted with `update_counters` (a single atomic SQL `COALESCE(col,0) ± 1`) inside the record's own save transaction. The update path handles the full matrix: a **foreign-key reparent** moves the count from the old parent to the new one, a **condition flip** increments/decrements in place, and the two compose.

**Options** (`counter_cacheable_by association, …`, repeatable): `count:` (the parent column; default `"<table_name>_count"`), `if:` (a callable evaluated against the record — counts only when truthy; the previous state is reconstructed for updates), `touch:` (`false`; also bump the parent's `updated_at`).

**Notes**
- The `belongs_to` must be declared **before** the macro (the reflection is validated at declaration). Polymorphic associations are not supported.
- Don't also set native `counter_cache: true` on the same column — both would fire and double-count.
- Counters track the **persisted** record; writes that skip callbacks (`update_column(s)`, `update_all`, `delete`) are not tracked — run `recount_counter_caches!` to reconcile. It rewrites every parent (portable across adapters, but O(n) for conditional counters) — a maintenance operation, run it offline.
- Reach for [`counter_culture`](https://github.com/magnusvk/counter_culture) when you need multi-level rollups, delta columns, or after-commit execution.

---

# 🎮 Controller Concerns

Pure ActionController + ActiveRecord — **zero extra runtime dependencies** (no Kaminari, Pundit, or Ransack).

## 📄 Paginatable

Offset-based pagination with standard response headers — no Kaminari needed.

```ruby
class ArticlesController < ApplicationController
  include ConcernsOnRails::Controllers::Paginatable

  paginate_by per_page: 25, max_per_page: 200    # optional — these are the defaults

  def index
    render json: paginated(Article.all)
  end
end
```

**URL params**

| Param        | Default | Notes                              |
|--------------|---------|------------------------------------|
| `?page=`     | `1`     | Page numbers below 1 are clamped to 1 |
| `?per_page=` | `25`    | Capped at `max_per_page` (default 200) |

**Response headers**: `X-Total-Count`, `X-Page`, `X-Per-Page`, `X-Total-Pages`.

---

## 🧭 CursorPaginatable

Cursor (keyset) pagination — the constant-time complement to Paginatable: **no COUNT query**, stable under concurrent inserts, ideal for infinite scroll and sync feeds.

```ruby
class ArticlesController < ApplicationController
  include ConcernsOnRails::Controllers::CursorPaginatable

  cursor_paginate_by order: { created_at: :desc }, per_page: 25, max_per_page: 200

  def index
    render json: cursor_paginated(Article.all)   # bad cursors are rescued to a 400 automatically
  end
end
```

**URL params**

| Param        | Default | Notes                                                    |
|--------------|---------|----------------------------------------------------------|
| `?cursor=`   | —       | The opaque token from `X-Next-Cursor` (omit for page 1)  |
| `?per_page=` | `25`    | Capped at `max_per_page` (default 200; `0` disables the cap) |
| `?order=`    | first preset | With `order_presets:` only — selects a named ordering from the allow-list (unknown names → 400 `invalid_order_preset`) |

**Response headers**: `X-Per-Page`, `X-Count` (rows on **this** page — totals are deliberately not computed), `X-Has-More`, `X-Next-Cursor` (only while more pages exist). With `bidirectional: true`: also `X-Has-Prev`, `X-Prev-Cursor`.

**Notes**
- The primary key is always appended as a tiebreaker, so duplicate values never skip or repeat rows; ordering columns are chosen **in code** (never from params) and should be `NOT NULL` (a NULL boundary value raises rather than silently dropping rows).
- Cursors are opaque, table/order-pinned tokens — a malformed, cross-endpoint, or stale-config cursor renders a 400 (`invalid_cursor`; override `render_invalid_cursor` to customize, delegates to Respondable's `render_error` when present). They are **not signed**: a client can mint different boundary values, but values are cast through the model's attribute types and bound by Arel (no injection) and the relation's own scoping still applies — treat a cursor as a page position, never an authorization boundary.
- `cursor_paginated` uses `reorder` (replaces any `default_scope` ORDER BY) and returns a loaded Array. Don't wrap it with the controller Sortable's `sorted` — pass `order:` per call instead.
- Forward-only by default — `bidirectional: true` (macro or per call) adds prev cursors and `X-Has-Prev`/`X-Prev-Cursor`; direction is pinned in the token, so prev tokens replayed on forward-only endpoints 400 and old direction-less tokens stay valid. `order_presets: { newest: {...}, top: {...} }` (+ `default_preset:`, `order_param:`) lets clients pick a **named** ordering from an allow-list. `predicate: :auto` upgrades the keyset WHERE to a row-value tuple `(a, b, id) > (x, y, z)` on PostgreSQL/MySQL/SQLite when directions are uniform — composite-index friendly — falling back to the portable OR-expansion (`:row`/`:or` force a strategy).
- Use Paginatable when you need page numbers and totals.

---

## 🔎 Filterable

Declarative URL-param filtering with three modes per filter.

```ruby
class ArticlesController < ApplicationController
  include ConcernsOnRails::Controllers::Filterable

  filter_by :status, :category                                       # ?status=draft → .where(status: 'draft')
  filter_by :published, scope: :published                            # ?published=1 → Article.published
  filter_by :q, with: ->(rel, v) { rel.where("title ILIKE ?", "%#{v}%") }

  def index
    render json: filtered(Article.all)
  end
end
```

**Modes**

| Mode        | Declaration                          | What it does                                    |
|-------------|--------------------------------------|-------------------------------------------------|
| Direct      | `filter_by :status`                  | `relation.where(status: params[:status])`       |
| Scope       | `filter_by :published, scope: :published` | `relation.published` (when param is present)    |
| Custom      | `filter_by :q, with: ->(rel, v) { ... }`  | Calls your lambda with `(relation, value)`      |

**Notes**
- Blank params are skipped — unset filters don't narrow the relation.
- Passing both `:scope` and `:with` raises `ArgumentError`.
- Scope mode pairs naturally with `Publishable.published`, `SoftDeletable.active`, `Expirable.active`, etc.

---

## ↕️ Sortable (controller)

URL-param-driven ordering with a **strict allow-list** — never orders by an arbitrary user-supplied column.

```ruby
class ArticlesController < ApplicationController
  include ConcernsOnRails::Controllers::Sortable

  sortable_by :created_at, :title, :published_at,
              default: :created_at, direction: :desc

  def index
    render json: sorted(Article.all)
  end
end
```

**URL params**: `?sort=title&direction=asc`

- `params[:sort]` selects the column; non-whitelisted values fall back to the declared default.
- `params[:direction]` accepts `asc` / `desc` (case-insensitive); invalid values fall back to the declared default direction.
- If no `default:` is given, the **first** declared field is used.

> Distinct from `Models::Sortable` (which manages list position via `acts_as_list`). Both can coexist on a model + its controller.

---

## 📦 Respondable

Standardized JSON envelopes for API controllers — two methods, zero state.

```ruby
class Api::ArticlesController < ApplicationController
  include ConcernsOnRails::Controllers::Respondable

  def show
    article = Article.find_by(id: params[:id])
    return render_error(message: "Not found", status: :not_found) unless article

    render_success(data: article)
  end

  def create
    article = Article.new(article_params)
    if article.save
      render_success(data: article, status: :created)
    else
      render_error(message: "Invalid", errors: article.errors.full_messages)
    end
  end
end
```

**Response shapes**

```jsonc
// Success
{ "success": true, "data": {...}, "meta": {...}  /* meta omitted when empty */ }

// Error
{ "success": false, "error": { "message": "...", "code": "...", "details": [...] } }
```

**API**

| Method            | Signature                                                                                  |
|-------------------|--------------------------------------------------------------------------------------------|
| `render_success`  | `render_success(data: nil, status: :ok, meta: {})`                                         |
| `render_error`    | `render_error(message:, status: :unprocessable_entity, code: nil, errors: nil)`            |

> `data:` is a keyword arg (not positional) on purpose — it sidesteps Ruby 3's behavior of treating hash literals as kwargs when a method declares any keyword params.

---

## 🛟 ErrorHandleable

Install `rescue_from` handlers for the three most common controller exceptions and render them as the same JSON envelope used by Respondable.

```ruby
class Api::BaseController < ApplicationController
  include ConcernsOnRails::Controllers::Respondable       # recommended
  include ConcernsOnRails::Controllers::ErrorHandleable
end
```

**Handled exceptions**

| Exception                              | Status | `code`                |
|----------------------------------------|--------|-----------------------|
| `ActiveRecord::RecordNotFound`         | 404    | `"not_found"`         |
| `ActionController::ParameterMissing`   | 400    | `"parameter_missing"` |
| `ActiveRecord::RecordInvalid`          | 422    | `"record_invalid"`    |

Response shape (matches `Respondable#render_error`):

```json
{ "success": false, "error": { "message": "...", "code": "...", "details": [...] } }
```

**Overriding a handler**

Each handler is a public instance method, so subclasses can customize the message or response shape without re-declaring the `rescue_from`:

```ruby
class Api::BaseController < ApplicationController
  include ConcernsOnRails::Controllers::ErrorHandleable

  def handle_record_not_found(error)
    render json: { success: false, error: { message: "Not here, friend." } }, status: :not_found
  end
end
```

**Notes**
- When `Respondable` is also included, the handlers delegate to `render_error` so the envelope shape stays in one place. Otherwise they render the same envelope inline.
- `RecordInvalid.details` are populated from `error.record.errors.full_messages`.

---

## 🔗 Includable

Whitelisted association sideloading + sparse fieldsets for JSON APIs — zero arbitrary `.includes` from user input.

```ruby
class ArticlesController < ApplicationController
  include ConcernsOnRails::Controllers::Includable

  includable :author, :comments,
             fields: { articles: %i[id title published_at], authors: %i[id name] }

  def index
    render json: with_includes(Article.all),
           include: requested_includes,
           fields:  requested_fields
  end
end
```

**URL params**

```
GET /articles?include=author,comments&fields[articles]=id,title&fields[authors]=id,name
```

**API**

| Method               | What it does                                                                               |
|----------------------|--------------------------------------------------------------------------------------------|
| `with_includes(rel)` | Parses `params[:include]`, intersects with the allow-list, calls `relation.includes(...)`  |
| `requested_includes` | Returns the sanitized `[:author, :comments]` array (pass to `render json:, include:`)     |
| `requested_fields`   | Returns `{ articles: [:id, :title] }` sanitized map (pass to your serializer)             |

**Notes**
- Non-whitelisted associations are **silently dropped** — no error, no arbitrary eager-loading.
- Non-whitelisted tables in `params[:fields]` are dropped; non-whitelisted columns within an allowed table are dropped.
- Pass `requested_fields` to your serializer (e.g. AMS / Blueprinter) — `Includable` itself does not alter the JSON output, only the query.

---

## 🛡️ SecureHeadable

Modern security response headers + a thin wrapper over Rails' native Content-Security-Policy DSL. Defense-in-depth on top of output escaping — it does **not** scrub request params and never re-enables the deprecated X-XSS-Protection auditor. Zero extra dependencies.

```ruby
class ApplicationController < ActionController::Base
  include ConcernsOnRails::Controllers::SecureHeadable

  # Preset headers, plus any custom "Header-Name" => "value" pairs:
  secure_headers :nosniff, :sameorigin_frame, :no_referrer_leak, :disable_legacy_xss
  secure_headers "Permissions-Policy" => "geolocation=()"

  # Delegates to Rails' native CSP DSL — roll out report-only FIRST:
  content_security_policy_for(report_only: true) do |policy|
    policy.default_src :self
    policy.script_src  :self
    policy.object_src  :none
  end
end
```

**Header presets** (`secure_headers`)

| Preset                | Header                                                 |
|-----------------------|--------------------------------------------------------|
| `:nosniff`            | `X-Content-Type-Options: nosniff`                      |
| `:sameorigin_frame`   | `X-Frame-Options: SAMEORIGIN`                          |
| `:deny_frame`         | `X-Frame-Options: DENY`                                |
| `:no_referrer_leak`   | `Referrer-Policy: strict-origin-when-cross-origin`     |
| `:no_cross_domain`    | `X-Permitted-Cross-Domain-Policies: none`              |
| `:disable_legacy_xss` | `X-XSS-Protection: 0` (the only correct modern value)  |

**Notes**
- Headers are applied in an `after_action`, so they reinforce Rails' middleware defaults; later `secure_headers` declarations win on a colliding name.
- `content_security_policy_for` forwards `report_only:` and per-action `only:` / `except:` / `if:` / `unless:` straight to Rails — it never re-implements CSP. Per-controller CSP overrides the global initializer for that controller.
- CSP nonce generation (`content_security_policy_nonce_generator`) is app-wide initializer config and intentionally stays out of the concern.
- These headers mitigate clickjacking / MIME-sniffing and (via CSP) XSS as **defense-in-depth** — output escaping remains the primary defense.

---

## 🌐 Localizable

Per-request locale selection from the request params and/or the `Accept-Language` header, wrapped in an `around_action` so `I18n.locale` is set for the action and restored afterwards. Dependency-free.

```ruby
class ApplicationController < ActionController::Base
  include ConcernsOnRails::Controllers::Localizable

  localizable available: %i[en fr de], default: :en
  # localizable param: :lang, header: false   # params[:lang] only
end
```

Resolution order: `params[param]` → first match in `Accept-Language` → `default` → `I18n.default_locale`. The chosen locale is always validated against `I18n.available_locales`, so a stray param or a mismatched `available:` list can never raise `I18n::InvalidLocale`.

**Options**: `available:` (allow-list for matching; defaults to `I18n.available_locales`), `default:`, `param:` (default `:locale`), `header:` (default `true`).

---

## 🔒 Authorizable

A declarative, **block-only** per-action authorization gate. Each rule is a predicate; the first one that applies to the current action and returns falsey halts the request with **403**. Deliberately small — not a Pundit/CanCan replacement.

```ruby
class Api::BaseController < ApplicationController
  include ConcernsOnRails::Controllers::Authorizable

  authorize_by { current_user.present? }                          # every action
  authorize_by(only: %i[update destroy]) { |_action, user| user.admin? }
  require_role :admin, :editor, only: :publish                    # role sugar
end
```

The predicate runs via `instance_exec`, so `current_user` (and any helper) resolves on the controller. It is **arity-safe** — write it with zero, one (`|action|`), or two (`|action, user|`) parameters.

**API**

| Method         | Signature                                                                                  |
|----------------|--------------------------------------------------------------------------------------------|
| `authorize_by` | `authorize_by(only: nil, except: nil, status: :forbidden, message: "Forbidden", &block)`   |
| `require_role` | `require_role(*roles, via: :current_user, role_method: :role, only:, except:, status:, message:)` |

**Notes**
- Rules run in declaration order; the first failing rule renders and halts.
- When `Respondable` is also included, denials delegate to `render_error` (envelope `{ success: false, error: { message:, code: "forbidden" } }`); otherwise the same envelope is rendered inline.
- `only:` / `except:` are mutually exclusive (passing both raises `ArgumentError`); `authorize_by` requires a block and `require_role` requires at least one role.
- **Non-goals**: no policy objects, no ability DSL, no resource inference — reach for [`pundit`](https://github.com/varvet/pundit) / [`cancancan`](https://github.com/CanCanCommunity/cancancan) when you outgrow a predicate per action.

---

## 🚦 Throttleable

Per-request rate limiting with a **store-agnostic, injectable** backend — no `rack-attack` needed. When a rule's limit is exceeded the request is halted with **429** plus `Retry-After` and `X-RateLimit-Limit` / `X-RateLimit-Remaining` / `X-RateLimit-Reset`.

```ruby
class Api::BaseController < ApplicationController
  include ConcernsOnRails::Controllers::Throttleable

  self.throttleable_store = Rails.cache               # must support atomic #increment

  throttle_by limit: 100, period: 1.minute                          # by IP (default)
  throttle_by limit: 5,   period: 1.minute, only: :create,
              by: -> { current_user&.id || request.remote_ip }
end
```

Fixed-window counter: the key embeds a floored time bucket (`epoch / period`) so each window starts clean and `X-RateLimit-Reset` is exact.

**Options**: `limit:` (positive integer), `period:` (a `Duration` or seconds), `by:` (discriminator lambda, default per-IP), `only:` / `except:` (mutually exclusive action scoping), `name:` (disambiguates the counter key).

**Notes**
- The store MUST support **atomic increment-with-expiry** (`Rails.cache` with `#increment`, or Redis) — a non-atomic store under-counts under concurrency.
- There is **no in-process default store** on purpose: the first throttled request raises `ArgumentError` until you set `throttleable_store`, so you never silently rate-limit per-process.
- When `Respondable` is included, the 429 body delegates to `render_error` (`code: "rate_limited"`).
- Backports the essentials of Rails 7.2's `rate_limit` (with standardized headers) to Rails 5.0+. For richer rules (fail2ban, allow/deny lists, exponential backoff) reach for [`rack-attack`](https://github.com/rack/rack-attack).

---

## 🕒 Timezoneable

Per-request `Time.zone` selection wrapped in an `around_action` (`Time.use_zone`) — the time analogue of [Localizable](#-localizable). Dependency-free.

```ruby
class ApplicationController < ActionController::Base
  include ConcernsOnRails::Controllers::Timezoneable

  timezoneable available: ["UTC", "Eastern Time (US & Canada)"], default: "UTC"
  # timezoneable param: :tz, header: false, cookie: :time_zone
end
```

Resolution order: `params[param]` → `Time-Zone` header → cookie (if enabled) → `default` → the current `Time.zone`. Every value — the configured `available:` / `default:` **and** each request candidate — is resolved through `ActiveSupport::TimeZone[...]`, so a zone accepted at boot can never be rejected at request time.

**Options**: `available:` (allow-list applied to param/header/cookie matching; `default:` bypasses it, mirroring Localizable), `default:`, `param:` (default `:time_zone`), `header:` (default `true`, reads the `Time-Zone` header), `cookie:` (default `false`; `true` reads the `:time_zone` cookie, or pass a cookie name).

**Notes**
- An unknown `available:` / `default:` zone raises `ArgumentError` at declaration time (fail-fast on misconfiguration).
- Pairs naturally with the model concerns that read the clock (`Schedulable`, `Publishable`, `Expirable`, `SoftDeletable`).

---

## 🔁 Idempotentable

Stripe-style **`Idempotency-Key`** support for mutating endpoints, with a **store-agnostic, injectable** backend. The first request with a key runs the action and caches the response; a retry **replays** the cached response; a concurrent duplicate gets **409**.

```ruby
class PaymentsController < ApplicationController
  include ConcernsOnRails::Controllers::Idempotentable

  self.idempotency_store = Rails.cache    # must support #read / #write(expires_in:, unless_exist:) / #delete

  idempotent_actions :create, ttl: 24.hours, required: true
end
```

Per-key lifecycle: claim atomically (`write unless_exist`, TTL `lock_ttl:`) → run action → cache 2xx–4xx responses for `ttl:`; 5xx and raised exceptions release the claim so the client can retry. Replays carry `X-Idempotency-Replayed: true`; duplicates in flight get 409 + `Retry-After`; reusing a key with a **different payload** gets 422 (`idempotency_key_reuse`, fingerprint overridable via `idempotency_fingerprint`).

**Options**: `*actions` (allow-list, required), `ttl:` (`24.hours`), `lock_ttl:` (`1.minute`), `header:` (`"Idempotency-Key"`), `required:` (`false`).

**Notes**
- Cache keys are scoped per `controller#action` and the client key is SHA256-hashed, so the same key on different endpoints never collides.
- There is **no in-process default store** on purpose: the first keyed request raises `ArgumentError` until you set `idempotency_store`.
- When `Respondable` is included, the 400/409/422 bodies delegate to `render_error`.
- Declare halting filters (authentication, `Throttleable`) **before** including this concern — a 401/403 rendered by an inner filter would be cached and replayed for the full TTL. Responses rendered by `rescue_from` handlers are never cached.
- Keys must be ≤255 chars with no control characters (the raw key is echoed in `X-Idempotency-Key`); set `lock_ttl:` above the slowest declared action's worst case.

---

## 🪝 WebhookVerifiable

HMAC **signature verification for inbound webhooks** — the receiving side of Stripe/GitHub/Shopify-style integrations. The action runs only when the signature over the **raw request body** verifies; otherwise a 401/400 is rendered and the action never executes.

```ruby
class WebhooksController < ApplicationController
  include ConcernsOnRails::Controllers::WebhookVerifiable   # declare BEFORE Idempotentable

  verify_webhook :stripe,  secret: -> { ENV["STRIPE_WEBHOOK_SECRET"] },    scheme: :stripe
  verify_webhook :github,  secret: -> { ENV["GITHUB_WEBHOOK_SECRET"] },    scheme: :github
  verify_webhook :shopify, secret: [ENV["NEW_SECRET"], ENV["OLD_SECRET"]], scheme: :shopify  # rotation
  verify_webhook :custom,  secret: "s3cr3t", scheme: :hex, header: "X-Acme-Signature"
  # verify_webhook secret: ...   # no actions = catch-all (declare specific rules first)

  def stripe
    event = JSON.parse(request.raw_post)   # parse the raw body — it is what was signed
    # ...
  end
end
```

| Scheme | Header (default) | Format |
|--------|------------------|--------|
| `:github` | `X-Hub-Signature-256` | `sha256=<hex>` |
| `:shopify` | `X-Shopify-Hmac-Sha256` | strict Base64 of the binary HMAC |
| `:stripe` | `Stripe-Signature` | `t=<unix>,v1=<hex>[,v1=…]` — signs `"#{t}.#{body}"`, every `v1` tried, `tolerance:` rejects stale **and** future timestamps |
| `:hex` / `:base64` | — (`header:` required) | plain hex / strict Base64 HMAC of the body |

**Options**: `*actions` (none = catch-all; the first matching rule wins), `secret:` (String, callable `instance_exec`'d per request, or Array for rotation — any match passes), `scheme:` (`:hex`), `header:` (overrides the preset), `tolerance:` (Stripe only, `300`s default), `digest:` (`:sha256`; `:sha1`/`:sha512` for `:hex`/`:base64` only).

**Notes**
- Comparison is constant-time and the attacker-controlled header is **never decoded** — garbage (including invalid UTF-8 bytes) just fails with 401, it cannot raise.
- A secret that resolves **blank at request time raises `ArgumentError`** — a misconfigured endpoint should page you, not 401 into the provider's silent retry loop.
- Failure codes: `webhook_signature_missing` / `webhook_signature_invalid` / `webhook_timestamp_stale` → 401; `webhook_signature_malformed` (unparseable Stripe header) → 400. With `Respondable`, bodies delegate to `render_error`; override `webhook_verification_failed` to customize.
- Declare **before** `Idempotentable` (a 401 cached by its around filter would be replayed) and before `Throttleable` (forged traffic shouldn't burn rate budget). Webhook endpoints also need `skip_before_action :verify_authenticity_token`.
- In tests: `skip_before_action :verify_webhook_signature!`, or sign payloads for real with `OpenSSL::HMAC`. After a pass, `webhook_verified?` is true.

---

## 🌅 Deprecatable

Standards-based **API endpoint deprecation**: the RFC 9745 `Deprecation` and RFC 8594 `Sunset` headers, `Link` rels pointing at the migration docs and the successor endpoint, an instrumentation hook to measure who still calls the endpoint, and optional **410 Gone** enforcement once the sunset instant passes. This is how Stripe/GitHub/Zalando retire API versions — and nothing native exists on any Rails version.

```ruby
class Api::V1::OrdersController < ApplicationController
  include ConcernsOnRails::Controllers::Deprecatable

  deprecate_actions :index, :show,
    deprecated_at: "2026-06-01",
    sunset_at:     "2026-12-31T00:00:00Z",
    link:          "https://docs.example.com/v1-migration",
    successor:     "https://api.example.com/v2/orders",
    after_sunset:  :gone,         # default :headers — announce, never block
    notify:        -> { StatsD.increment("api.v1.orders.deprecated") }
end

# Every matching response then carries:
#   Deprecation: @1780272000
#   Sunset: Thu, 31 Dec 2026 00:00:00 GMT
#   Link: <https://docs.example.com/v1-migration>; rel="deprecation", <https://api.example.com/v2/orders>; rel="successor-version"
```

**Options**: `deprecated_at:` (required; Time/Date/String — parsed eagerly, normalized to UTC), `sunset_at:` (optional, must be ≥ `deprecated_at`; a bare date means **00:00 UTC that day** — sunset is an instant, not end-of-day), `link:` / `successor:` (URLs), `after_sunset:` (`:headers` default | `:gone` → 410 with code `endpoint_sunset` at/after the sunset instant), `header_format:` (`:rfc9745` default, `@<unix>` | `:legacy`, the widely-deployed draft literal `true`), `notify:` (callable, `instance_exec`'d per matching request — a raising notify propagates on purpose). No positional actions = catch-all for the whole controller. **The last matching rule wins**, so an action-specific declaration naturally overrides a base controller's catch-all.

**Notes**
- Headers go out on every matching response — **including the 410 itself**, so the cut-off self-documents. `Link` values are appended to any existing `Link` header (pagination, CDN), never clobbered.
- Each hit instruments `deprecated_endpoint.concerns_on_rails` (`ActiveSupport::Notifications`) with `{controller:, action:, deprecated_at:, sunset_at:}` — subscribe to count stragglers *before* flipping `after_sunset: :gone`. Override `on_deprecated_access(rule)` to replace the default instrumentation.
- 410 bodies delegate to `Respondable`'s `render_error` when present (inline JSON envelope otherwise). `skip_before_action :apply_api_deprecations` opts an action out; `deprecation_active?` / `sunset_passed?` are available for serializers/response bodies.
- Flipping `:gone` is a deliberate, customer-facing cut-off — coordinate it with `notify:`-driven outreach, and mind CDN-cached responses that may outlive the headers.

---

## 🗄️ Cacheable

HTTP conditional GET + declarative `Cache-Control` ("fresh_when/stale?-lite" for JSON APIs). The method names are deliberately distinct from Rails' `ActionController::ConditionalGet`, so including it never shadows `fresh_when` / `stale?` / `expires_in`.

```ruby
class Api::ArticlesController < ApplicationController
  include ConcernsOnRails::Controllers::Cacheable

  http_cache_actions :index, :show, max_age: 5.minutes,
                     visibility: :public, vary: "Accept"

  def show
    @article = Article.find(params[:id])
    return unless stale_resource?(@article)   # 304 + halt when the client copy is fresh
    render json: @article
  end
end

# A matching response then carries:
#   Cache-Control: public, max-age=300
#   Vary: Accept
#   ETag: W/"…"
#   Last-Modified: Thu, 01 Jan 2026 12:00:00 GMT
```

`http_cache_actions` declares the `Cache-Control`/`Vary` policy (emitted via `after_action` — it rides a 304 too); `stale_resource?` sets the ETag/Last-Modified validators and, on a safe request whose precondition matches, sends `304 Not Modified` and returns `false`.

**Options** (`http_cache_actions *actions, …`, repeatable; no actions = catch-all; **last matching rule wins**): `visibility:` (`:private` default | `:public`), `max_age:` (Integer/Duration), `must_revalidate:`, `no_store:` (overrides everything → bare `no-store`), `stale_while_revalidate:`, `vary:` (String or Array, appended to any existing `Vary`).

**Conditional-GET correctness**
- Weak ETag `W/"<md5>"` from the resource's cache key (collections fold their members' keys + size); `If-None-Match` is matched with **weak comparison**, honours `*`, and accepts a comma-separated list.
- `Last-Modified` is an IMF-fixdate via `Time#httpdate` (not hand-rolled ISO 8601); `If-Modified-Since` is compared at whole-second granularity.
- When both are sent, `If-None-Match` wins and the date is ignored (RFC 7232 §3.3); a 304 is only sent for safe (GET/HEAD) requests, and still carries the validators and the `Cache-Control` policy.
- Override `cache_etag_for` / `cache_last_modified_for` to customise validator derivation. For write-side preconditions (`If-Match` → 412), reach for Rails' own helpers.

---

## 🗂️ Module paths & namespacing

Every concern is available under two paths:

```ruby
# Short form (recommended for brevity):
include ConcernsOnRails::Sluggable
include ConcernsOnRails::Normalizable

# Fully-qualified form:
include ConcernsOnRails::Models::Sluggable
include ConcernsOnRails::Models::Normalizable
```

Controller concerns live under `ConcernsOnRails::Controllers::*` (no short form, to disambiguate from `Models::Sortable`):

```ruby
include ConcernsOnRails::Controllers::Paginatable
include ConcernsOnRails::Controllers::Sortable
```

Both forms reference the same module, so you can freely mix them.

---

## 🧭 Philosophy & when to reach for a dedicated gem

`concerns_on_rails` aims to cover the common 80% of each behavior with **one `include` + one declarative macro**, **schema-validated** configuration, **no-surprise defaults**, and **lean dependencies** (only `acts_as_list` and `friendly_id`; controller concerns have none). It is deliberately *not* a re-implementation of the category leaders — reach for a dedicated gem when you outgrow the basics:

| Need | Use instead |
|------|-------------|
| Complex state machines (callbacks, transition logging) | [`aasm`](https://github.com/aasm/aasm) |
| Association-cascade soft delete / sentinel-aware unique indexes | [`paranoia`](https://github.com/rubysherpas/paranoia) or [`discard`](https://github.com/jhawthorn/discard) |
| Tagging with contexts, ownership, or tag clouds | [`acts-as-taggable-on`](https://github.com/mbleigh/acts-as-taggable-on) |
| Full-text search with ranking / stemming | [`pg_search`](https://github.com/Casecommons/pg_search) / Elasticsearch |
| Versioned audit trails with undo/reify, who-dunnit queries, or association tracking | [`paper_trail`](https://github.com/paper-trail-gem/paper_trail) / [`audited`](https://github.com/collectiveidea/audited) |

`Sluggable` wraps [`friendly_id`](https://github.com/norman/friendly_id) and `Sortable` wraps [`acts_as_list`](https://github.com/brendon/acts_as_list), so you get those leaders' engines behind the declarative macro.

---

## 🛠️ Development

```sh
bundle install                                  # install dev dependencies
bundle exec rspec                               # run the test suite
gem build concerns_on_rails.gemspec             # build the gem
gem install ./concerns_on_rails-1.11.2.gem      # install locally
```

The test suite uses an in-memory SQLite database and a lightweight `FakeController` harness for controller-concern specs — no Rails routes or boot required.

---

## 🤝 Contributing

Bug reports and pull requests are welcome at **[github.com/VSN2015/concerns_on_rails](https://github.com/VSN2015/concerns_on_rails)**. ⭐️ stars and 🍴 forks appreciated.

---

## 📄 License

MIT — see [LICENSE](MIT-LICENSE).

---

🇻🇳 **Hoàng Sa and Trường Sa belong to Việt Nam.**
