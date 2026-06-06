# 🧩 ConcernsOnRails

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

- [Why this gem?](#-why-this-gem)
- [Installation](#-installation)
- [Compatibility](#-compatibility)
- [Quick Start](#-quick-start)
- **Model concerns**
  - [Sluggable](#-sluggable) — URL-friendly slugs
  - [Sortable](#-sortable) — list ordering via `acts_as_list`
  - [Publishable](#-publishable) — `published_at` timestamp publishing
  - [SoftDeletable](#-softdeletable) — soft delete with scopes & hooks
  - [Hashable](#-hashable) — auto-generate tokens / UUIDs / codes
  - [Schedulable](#-schedulable) — `starts_at` / `ends_at` time windows
  - [Expirable](#-expirable) — single-timestamp expiry
  - [Normalizable](#-normalizable) — attribute normalization (`:email`, `:phone`, …)
  - [Searchable](#-searchable) — LIKE/ILIKE search across configured columns
  - [Activatable](#-activatable) — boolean active/inactive toggle
  - [Tokenizable](#-tokenizable) — security tokens with timing-safe lookup
  - [Sequenceable](#-sequenceable) — ordered, human-friendly reference numbers
  - [Stateable](#-stateable) — lightweight string-backed state machine
  - [Addressable](#-addressable) — postal address normalization + format validation
  - [Taggable](#-taggable) — lightweight tagging over a single column
  - [Sanitizable](#-sanitizable) — opt-in HTML sanitization (XSS defense-in-depth)
  - [Maskable](#-maskable) — non-destructive display masking of sensitive fields
  - [Monetizable](#-monetizable) — integer-cents money columns (BigDecimal)
- **Controller concerns**
  - [Paginatable](#-paginatable) — offset pagination with headers
  - [Filterable](#-filterable) — declarative URL-param filters
  - [Sortable (controller)](#-sortable-controller) — URL-param ordering with allow-list
  - [Respondable](#-respondable) — standardized JSON envelopes
  - [ErrorHandleable](#-errorhandleable) — JSON `rescue_from` handlers for common controller errors
  - [Includable](#-includable) — whitelisted association sideloading + sparse fieldsets
  - [SecureHeadable](#-secureheadable) — security response headers + native CSP DSL
  - [Localizable](#-localizable) — per-request locale from params / Accept-Language
- [Module paths & namespacing](#-module-paths--namespacing)
- [Development](#-development)
- [Contributing](#-contributing)
- [License](#-license)

---

## ✨ Why this gem?

- **Eighteen model concerns + eight controller concerns**, all production-ready
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
| Audit trails / version history | [`paper_trail`](https://github.com/paper-trail-gem/paper_trail) / [`audited`](https://github.com/collectiveidea/audited) |

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
