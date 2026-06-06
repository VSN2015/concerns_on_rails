The `Publishable` concern gives any ActiveRecord model timestamp-driven publish state management. Include it in a model and call `publishable_by` once to configure the controlling column; the concern then wires up four ActiveRecord scopes and a suite of instance predicates and mutators. The central invariant is that a record is "published" only when its timestamp column is both present and in the past — a future-dated record is considered _scheduled_ (visible to queries, not yet live), and a nil timestamp is a true _draft_. This design lets editors pre-stage content without extra boolean flags or state machines.

## When to use it

- A blog or CMS where articles should go live at a specific date and time, with drafts and scheduled posts tracked separately.
- A product catalog where items become visible only after a reviewer sets a `published_at` date.
- An email campaign tool that needs to queue messages for future delivery while keeping them hidden from end-users until send time.
- A documentation site where pages authored in advance must remain invisible until a release date passes.
- Any model that needs a simple "live / not live" toggle without a full state machine or additional boolean column.

## Installation

```ruby
# app/models/article.rb
class Article < ApplicationRecord
  include ConcernsOnRails::Publishable

  publishable_by :published_at
end
```

The concern is defined as `ConcernsOnRails::Models::Publishable`; the top-level `ConcernsOnRails::Publishable` is a backwards-compatibility alias to that same module, and the two may be used interchangeably.

## Database columns

`Publishable` reads and writes a single timestamp column. A `datetime` column is the conventional choice; the concern also works with any column type for which `<=` and `>` comparisons are meaningful (including `boolean` — see the Configuration section).

| Column | Type | Required | Notes |
|---|---|---|---|
| `published_at` | `datetime` | Yes (default name) | Rename via `publishable_by`; must exist before the macro is called |

```ruby
# db/migrate/YYYYMMDDHHMMSS_add_published_at_to_articles.rb
class AddPublishedAtToArticles < ActiveRecord::Migration[7.1]
  def change
    add_column :articles, :published_at, :datetime
    add_index  :articles, :published_at
  end
end
```

## Configuration

```ruby
publishable_by(field = nil, default_scope: false)
```

Call `publishable_by` inside the model class body after including the concern. The macro validates that the column exists at load time and raises `ArgumentError` if it does not.

| Option | Type | Default | Description |
|---|---|---|---|
| `field` | Symbol (positional) | `:published_at` | The database column that controls publish state. Must exist in the table at the time the class is loaded. |
| `default_scope:` | Boolean (keyword) | `false` | When `true`, applies a `default_scope` so that `Model.all` returns only published records. The `.draft`, `.scheduled`, and `.unpublished` scopes unscope the field and remain fully functional. Reach all records with `.unscoped`. |

`publishable_by` may be called more than once on the same class to point it at a different column; each call overwrites `publishable_field` on the class.

## Scopes

All four scopes are defined in the `included` block and are therefore available as soon as the module is included, even before `publishable_by` is called (they read `publishable_field`, which defaults to `:published_at`).

| Scope | SQL condition | Description |
|---|---|---|
| `.published` | `published_at <= NOW()` | Records whose timestamp is set and is in the past or present — the live set. |
| `.unpublished` | `published_at IS NULL OR published_at > NOW()` | Records that are not yet live: both drafts and future-scheduled records combined. Unscopes the field before applying its condition. |
| `.scheduled` | `published_at > NOW()` | Records with a future timestamp — queued but not yet live. Unscopes the field before applying its condition. |
| `.draft` | `published_at IS NULL` | Records with no timestamp set — true drafts. Unscopes the field before applying its condition. |

```ruby
# Retrieve all live articles
Article.published

# Retrieve every record that is not currently live
Article.unpublished

# Retrieve articles queued for future release
Article.scheduled

# Retrieve articles with no publish date set
Article.draft

# Combine with other scopes
Article.published.where(category: "news").order(:published_at)
```

## Methods

### Instance methods

| Signature | Description |
|---|---|
| `publish!` | Sets the publish field to `Time.zone.now` and persists the record. Returns the `update` result. |
| `unpublish!` | Sets the publish field to `nil` and persists the record. |
| `publish_at!(time)` | Sets the publish field to `time` and persists the record. Pass a future time to schedule the record. |
| `published?` | Returns `true` if the field is present and its value is `<= Time.zone.now`. |
| `unpublished?` | Returns `true` if `published?` is `false` (logical inverse; covers both drafts and scheduled records). |
| `scheduled?` | Returns `true` if the field is present and its value is `> Time.zone.now`. |
| `draft?` | Returns `true` if the field is blank (nil or empty). |

### Class methods

| Signature | Description |
|---|---|
| `publishable_by(field = nil, default_scope: false)` | Configures the concern. Validates column existence and optionally installs a `default_scope`. |

## Examples

**Basic lifecycle — draft, publish, unpublish**

```ruby
article = Article.create!(title: "Breaking News")

article.draft?        # => true
article.published?    # => false

article.publish!
article.published?    # => true
article.draft?        # => false

article.unpublish!
article.published?    # => false
article.draft?        # => true
```

**Scheduled publishing**

```ruby
article = Article.create!(title: "Upcoming Feature", published_at: nil)

article.publish_at!(3.days.from_now)

article.scheduled?    # => true  (timestamp set, but in the future)
article.published?    # => false
article.draft?        # => false

# After the scheduled time passes, the scope picks it up automatically
Article.published     # includes article once Time.zone.now >= published_at
```

**Opt-in default scope**

```ruby
class Post < ApplicationRecord
  include ConcernsOnRails::Publishable

  publishable_by :published_at, default_scope: true
end

Post.create!(title: "Live",   published_at: 1.day.ago)
Post.create!(title: "Draft",  published_at: nil)
Post.create!(title: "Future", published_at: 1.day.from_now)

Post.all.map(&:title)       # => ["Live"]
Post.draft.map(&:title)     # => ["Draft"]
Post.scheduled.map(&:title) # => ["Future"]
Post.unscoped.count         # => 3
```

## Notes & gotchas

- **Column must exist at class load time.** `publishable_by` calls `ensure_columns!` immediately. If the migration has not been run, or the class is loaded before the migration in a test setup, an `ArgumentError` is raised with the message `"ConcernsOnRails::Models::Publishable: '<field>' does not exist in the database (table: <table_name>)"`.

- **Scopes are defined at include time, not at macro call time.** Unlike some concerns that register scopes inside `publishable_by`, all four scopes (`.published`, `.unpublished`, `.scheduled`, `.draft`) are defined inside `included do` and read the `publishable_field` class attribute lazily at query time. The attribute defaults to `:published_at`, so the scopes function against that default even if `publishable_by` is never called.

- **`scheduled?` and `published?` are mutually exclusive.** A record with a future timestamp is `scheduled?` and `unpublished?`; once that timestamp passes it becomes `published?` and neither `draft?` nor `scheduled?` — no write to the database is required.

- **`published?` on non-datetime columns.** When the field holds a value that does not respond to `<=` (for example a `boolean true`), `published?` returns `true` unconditionally. Similarly, `scheduled?` returns `false` for non-comparable types. This allows the concern to be used with boolean columns, though timestamp columns are strongly preferred.

- **`unpublished?` is not the inverse of `draft?` or `scheduled?` individually.** It is the complement of `published?` and therefore covers both drafts and scheduled records together.

- **`default_scope: true` interacts with ActiveRecord joins and `uniq`.** The `default_scope` macro inside Rails can produce unexpected `JOIN` conditions when associations eager-load. If a model is frequently used through `has_many` associations, prefer omitting `default_scope: true` and chaining `.published` explicitly at the call site.

- **`unpublished`, `scheduled`, and `draft` scopes call `unscope(where: publishable_field)`.** This is intentional: it ensures these scopes work correctly even when `default_scope: true` is active, allowing the admin-facing scopes to bypass the default filter without calling `.unscoped` (which would strip all other conditions).

- **`publish!` and `publish_at!` delegate to `update`.** Any `before_validation` or `before_save` callbacks on the model run normally. If those callbacks halt the chain, the timestamp is not persisted and the method returns `false`.

- **`publishable_by` can be called multiple times.** Each subsequent call overwrites `publishable_field`. Only the final configuration is active. Re-calling with `default_scope: true` will stack an additional `default_scope` onto the class, which Rails evaluates as an AND of all default scopes — avoid re-calling in production code.

- **No persistence of transition history.** The concern stores only the current timestamp; it does not record a log of publish/unpublish events. Pair with an auditing gem if a history trail is required.
