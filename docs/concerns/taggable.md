The `Taggable` concern adds lightweight, dependency-free tagging to any ActiveRecord model by storing tags delimiter-joined in a single string column. There are no join tables and no tagging engine — tags are split, normalized, de-duplicated, and reassembled on the fly, so it works on every database Rails supports, including SQLite. Use it when you need simple string labels on a model and do not require tag counts, contexts, ownership, or polymorphic tags shared across multiple models.

## When to use it

- A blog where articles carry a small set of editorial labels (e.g. `"ruby,rails,api"`).
- A job board where listings are tagged with skills and filtered by one or more skill names.
- A knowledge base where documents are tagged for search, and a tag-cloud widget needs the full sorted list of tags in use.
- A user profile model that stores technology interests case-insensitively for fuzzy matching.
- Any model that already has a string/text column and needs basic many-of-many-via-string tagging without adding gem dependencies.

## Installation

Add the concern to your model and call the configuration macro once. The fully-qualified alias `ConcernsOnRails::Models::Taggable` also works and resolves to the same module.

```ruby
class Article < ApplicationRecord
  include ConcernsOnRails::Taggable

  # Minimal — uses the default column :tags with default delimiter ","
  taggable_by :tags

  # Extended — custom column, pipe delimiter, case-folded
  # taggable_by :keywords, delimiter: "|", downcase: true
end
```

## Database columns

A single string (or text) column is required. No other columns are needed.

| Column | Type | Required | Notes |
|--------|------|----------|-------|
| `tags` (or your chosen field name) | `string` / `text` | Yes | Stores tags joined by the configured delimiter; set to `NULL` when the tag list is empty |

```ruby
class AddTagsToArticles < ActiveRecord::Migration[7.1]
  def change
    add_column :articles, :tags, :string
  end
end
```

## Configuration

### `taggable_by(field = :tags, delimiter:, downcase:)`

Call once per model. Validates that the column exists at class-load time and registers the `before_validation` normalization hook.

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `field` (positional) | `Symbol` | `:tags` | The database column that stores the delimiter-joined tag string. |
| `delimiter:` | `String` | `","` | The character used to join and split tags in the stored column. A tag value must not contain this character. |
| `downcase:` | `Boolean` | `false` | When `true`, every tag is lowercased on write, making all matching case-insensitive. |

## Scopes

### `.tagged_with(*names, any: false)`

Returns a chainable `ActiveRecord::Relation` of records that carry the specified tags.

| Form | Behavior |
|------|----------|
| `.tagged_with("ruby", "rails")` | AND — records must carry **all** listed tags (default). |
| `.tagged_with("ruby", "go", any: true)` | OR — records must carry **at least one** of the listed tags. |
| `.tagged_with` (no args) | Returns `all` — an empty tag list produces no filter clause. |

Matching is **boundary-safe**: `tagged_with("rail")` does not match a record tagged `"rails"`. Tags containing SQL `LIKE` wildcards (`_`, `%`) are escaped and match literally on every adapter.

```ruby
# AND: only articles tagged with both "ruby" AND "rails"
Article.tagged_with("ruby", "rails")

# OR: articles tagged with either "go" or "rails"
Article.tagged_with("go", "rails", any: true)

# Chainable with other scopes
Article.tagged_with("ruby").where(published: true).order(:title)
```

## Methods

### Class methods

#### `.all_tags → Array<String>`

Returns a sorted array of every distinct tag currently stored across all rows in the table.

```ruby
Article.all_tags  # => ["api", "go", "rails", "ruby"]
```

#### `.taggable_split(raw) → Array<String>`

Splits a raw stored column value on the configured delimiter and returns a normalized (stripped, de-duplicated, blank-rejected) array. Primarily used internally but public.

#### `.taggable_clean(tag) → String`

Normalizes a single tag: strips surrounding whitespace and optionally lowercases it. Used internally by all normalization paths.

### Instance methods

#### `#tag_list → Array<String>`

Returns the current tags as a normalized array. Always stripped and de-duplicated; returns `[]` when the column is `nil` or blank.

```ruby
article.tag_list  # => ["ruby", "rails"]
```

#### `#tag_list=(value)`

Accepts a `String` or `Array`. Splits (if a string), strips, de-duplicates, and writes the result back to the column joined by the delimiter. Stores `nil` when the resulting list is empty.

```ruby
article.tag_list = "Ruby, Rails, Ruby"  # stores "Ruby,Rails"
article.tag_list = ["go", " python "]   # stores "go,python"
article.tag_list = []                   # stores NULL
```

#### `#add_tags(*names) → Array<String>` / `#add_tag(*names)`

Adds one or more tags to the current list without duplicating existing entries. Returns the updated tag list. `add_tag` is an alias.

```ruby
article.add_tags("api", "ruby")  # "ruby" already present — not duplicated
```

#### `#remove_tags(*names) → Array<String>` / `#remove_tag(*names)`

Removes one or more tags from the current list. Returns the updated tag list. `remove_tag` is an alias.

```ruby
article.remove_tags("rails")
```

#### `#tagged_with?(tag) → Boolean` / `#has_tag?(tag)`

Returns `true` if the record currently carries the given tag. Applies the same normalization (strip + optional downcase) before comparing. `has_tag?` is an alias.

```ruby
article.tagged_with?("ruby")   # => true
article.has_tag?("nonexistent") # => false
```

## Examples

**Basic lifecycle — create, update, query**

```ruby
class Article < ApplicationRecord
  include ConcernsOnRails::Taggable
  taggable_by :tags
end

a = Article.create!(title: "Intro to Ruby", tag_list: "ruby, rails, ruby")
a.tag_list  # => ["ruby", "rails"]  (stripped, de-duped)

a.add_tags("api")
a.remove_tags("rails")
a.save!
a.tag_list  # => ["ruby", "api"]

Article.tagged_with("ruby")               # => [a]
Article.tagged_with("ruby", "api")        # => [a]  (AND)
Article.tagged_with("rails", any: true)   # => []   (removed above)
Article.all_tags                          # => ["api", "ruby"]
```

**Case-insensitive matching with `downcase: true`**

```ruby
class Skill < ApplicationRecord
  include ConcernsOnRails::Taggable
  taggable_by :tag_names, downcase: true
end

s = Skill.create!(tag_list: "Ruby, RAILS")
s.tag_list                       # => ["ruby", "rails"]
Skill.tagged_with("RUBY")        # => [s]
s.tagged_with?("Rails")          # => true
```

**Custom delimiter**

```ruby
class Post < ApplicationRecord
  include ConcernsOnRails::Taggable
  taggable_by :keywords, delimiter: "|"
end

p = Post.create!(tag_list: "ruby|rails")
p.reload[:keywords]              # => "ruby|rails"
p.tag_list                       # => ["ruby", "rails"]
Post.tagged_with("rails")        # => [p]
```

## Notes & gotchas

- **Column must exist before the macro runs.** `taggable_by` calls `ensure_columns!` at class-load time and raises `ArgumentError` with a message matching `/'<field>' does not exist/` if the column is absent. This prevents silent runtime failures.
- **`NULL` for empty.** When the tag list is set to `[]` or `""`, the column is written as `NULL`, not an empty string. Code reading the raw column should treat `nil` as "no tags."
- **`before_validation` normalization covers direct assignment.** If you assign the raw column directly (`record.tags = "a, b"`), the `before_validation` hook strips, splits, and de-duplicates the value before saving. You do not have to go through `tag_list=` for normalization to apply.
- **Boundary-safe SQL matching.** The `tagged_with` scope builds four OR-ed clauses per tag against the delimiter-joined column: an exact match (`column = ?`) plus three `LIKE` patterns that pin the tag to a delimiter boundary — `tag<delim>%` (tag first), `%<delim>tag` (tag last), and `%<delim>tag<delim>%` (tag in the middle). Each `LIKE` carries an explicit `ESCAPE '\\'` clause, so tags containing `_` or `%` are escaped and will not behave as SQL wildcards, and a search for `"rail"` will not match `"rails"`.
- **`tagged_with` with no arguments returns `all`.** An empty tag array short-circuits to `all`, so the result is safely chainable without a conditional guard.
- **No external gem dependencies.** Unlike `acts-as-taggable-on`, this concern requires no additional gems. The trade-off is that it has no support for tag counts, contexts, ownership, or polymorphic tags shared across multiple model types. Reach for `acts-as-taggable-on` when those features are needed.
- **Delimiter must not appear inside a tag value.** Tags containing the configured delimiter character produce incorrect split behavior. Choose a delimiter that cannot appear in your tag vocabulary, or sanitize tag input before assigning.
- **`all_tags` is a full-table scan.** It `pluck`s every row's tag column and aggregates in Ruby. Add a database-level index on the column only if needed for `tagged_with` queries; `all_tags` cannot use it efficiently at scale.
