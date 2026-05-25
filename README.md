# 🧩 ConcernsOnRails

> 🇻🇳 **Hoàng Sa and Trường Sa belong to Việt Nam.**

A plug-and-play collection of reusable ActiveSupport concerns for Rails **models** and **controllers** — slugs, soft delete, scheduled publish, expiry, pagination, filtering, JSON envelopes, and more. One `include`, one declarative macro, done.

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
  - [Stateable](#-stateable) — lightweight string-backed state machine
- **Controller concerns**
  - [Paginatable](#-paginatable) — offset pagination with headers
  - [Filterable](#-filterable) — declarative URL-param filters
  - [Sortable (controller)](#-sortable-controller) — URL-param ordering with allow-list
  - [Respondable](#-respondable) — standardized JSON envelopes
  - [ErrorHandleable](#-errorhandleable) — JSON `rescue_from` handlers for common controller errors
  - [Includable](#-includable) — whitelisted association sideloading + sparse fieldsets
- [Module paths & namespacing](#-module-paths--namespacing)
- [Development](#-development)
- [Contributing](#-contributing)
- [License](#-license)

---

## ✨ Why this gem?

- **Twelve model concerns + six controller concerns**, all production-ready
- **One include, one macro** — no boilerplate, no glue code
- **Lean dependencies** — only `acts_as_list` (Sortable) and `friendly_id` (Sluggable); controller concerns have zero extra deps
- **Schema-validated configuration** — every macro checks that the configured column exists and raises `ArgumentError` early
- **Composable** — concerns are independent; mix and match per model

---

## 📦 Installation

Add to your application's `Gemfile`:

```ruby
gem "concerns_on_rails", "~> 1.9"
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

Soft delete records using a timestamp field (default: `deleted_at`). Includes a `default_scope` that hides deleted records and overrides `destroy_all` to soft-delete in bulk.

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
User.destroy_all          # soft-deletes all matching records
User.really_destroy_all   # hard-deletes all matching records
User.restore_all          # restores all soft-deleted records
```

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

## 🛠️ Development

```sh
bundle install                                  # install dev dependencies
bundle exec rspec                               # run the test suite
gem build concerns_on_rails.gemspec             # build the gem
gem install ./concerns_on_rails-1.9.0.gem       # install locally
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
