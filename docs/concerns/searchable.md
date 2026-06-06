A lightweight LIKE-based full-text search concern for ActiveRecord models. `Searchable` adds a `.search` scope that queries one or more string columns using SQL `LIKE` / `ILIKE` patterns, handling input escaping automatically. It requires no external search engine, no background indexing, and no additional gems — making it a practical first choice for applications where ranked or stemmed full-text search is not yet needed.

## When to use it

- A product catalogue where users filter by SKU prefix or partial name before a dedicated search engine is justified.
- An admin interface that needs a quick "search by title or body" filter across a `posts` or `articles` table.
- A customer support tool that must search open tickets by subject line using a simple starts-with or contains pattern.
- Any model where search inputs come from untrusted user input and you need SQL wildcard characters (`%`, `_`, `\`) to be treated as literals automatically.
- Prototyping or early-stage apps where `pg_search` or Elasticsearch would be premature — you can swap the concern out later without changing call sites.

## Installation

```ruby
class Article < ApplicationRecord
  include ConcernsOnRails::Searchable

  # Search across multiple columns with default options
  searchable_by :title, :body

  # OR: require every whitespace-separated term to appear somewhere
  # searchable_by :title, :body, mode: :all

  # OR: anchor matches at the start of the value
  # searchable_by :sku, match: :prefix

  # OR: require an exact, case-sensitive match
  # searchable_by :code, match: :exact, case_sensitive: true
end
```

The fully-qualified module path `ConcernsOnRails::Models::Searchable` is an alias that also works; `ConcernsOnRails::Searchable` is the conventional short form.

## Database columns

The concern reads the columns declared in `searchable_by` — it does not write to the database and adds no columns of its own. The columns must already exist. Any column type readable as a string is supported (`string`, `text`, `citext`, etc.).

No migration is required for the concern itself. Ensure the target columns exist:

```ruby
class CreateArticles < ActiveRecord::Migration[7.1]
  def change
    create_table :articles do |t|
      t.string :title,   null: false
      t.text   :body

      t.timestamps
    end
  end
end
```

## Configuration

The single macro `searchable_by` configures the concern. It must be called at least once; calling it a second time on the same class replaces all previous settings.

```
searchable_by(*fields, mode:, match:, case_sensitive:)
```

| Option | Type | Default | Description |
|---|---|---|---|
| `*fields` (positional) | `Symbol` or `String` (one or more) | — | **Required.** The column names to search. At least one field must be supplied or `ArgumentError` is raised. All named columns must exist in the schema or `ArgumentError` is raised. |
| `mode:` | `:any` \| `:all` | `:any` | `:any` treats the entire query string as a single term. `:all` splits the query on whitespace and requires every term to match at least one of the configured columns (each term adds an `AND` `WHERE` clause; columns for that term are combined with `OR`). |
| `match:` | `:contains` \| `:prefix` \| `:exact` | `:contains` | Controls the LIKE pattern shape. `:contains` wraps the term as `%term%`. `:prefix` appends a trailing wildcard: `term%`. `:exact` emits the term verbatim with no wildcards. |
| `case_sensitive:` | `Boolean` | `false` | When `false`, Arel emits `ILIKE` on PostgreSQL (case-insensitive). When `true`, plain `LIKE` is emitted on all adapters. SQLite's `LIKE` is case-insensitive for ASCII by default regardless of this setting. |

Valid values for `mode:` are `:any` and `:all`. Valid values for `match:` are `:contains`, `:prefix`, and `:exact`. Passing any other value raises `ArgumentError` at class-load time.

## Scopes

`searchable_by` registers a single named scope on the model:

| Scope | Description |
|---|---|
| `.search(query)` | Returns records where at least one configured column matches `query`. When `query` is `nil` or blank (including whitespace-only strings), returns the unfiltered relation unchanged. Fully chainable with other scopes and `where` clauses. |

```ruby
# Basic usage
Article.search("hello")
# => WHERE (title ILIKE '%hello%' OR body ILIKE '%hello%')

# Blank query is a no-op
Article.search("")
# => SELECT * FROM articles   (no WHERE added)

# Chaining
Article.search("rails").where(published: true).order(:created_at)
```

## Methods

### Class methods

| Method | Signature | Description |
|---|---|---|
| `searchable_by` | `searchable_by(*fields, mode: :any, match: :contains, case_sensitive: false)` | Configuration macro. Sets the columns, match mode, pattern style, and case sensitivity for the `.search` scope. Raises `ArgumentError` for empty field lists, missing columns, or unrecognised option values. |
| `search_relation` | `search_relation(query) → ActiveRecord::Relation` | Public class method backing the `.search` scope. Accepts a query string and returns a relation. Called by the scope lambda; can also be called directly when composing queries programmatically. |

### Instance methods

This concern adds no public instance methods.

## Examples

**Multi-column substring search (default)**

```ruby
class Post < ApplicationRecord
  include ConcernsOnRails::Searchable

  searchable_by :title, :body
end

Post.create!(title: "Hello world", body: "intro")
Post.create!(title: "Unrelated",   body: "Hello there")
Post.create!(title: "Goodbye",     body: "nothing")

Post.search("hello").pluck(:title)
# => ["Hello world", "Unrelated"]

Post.search("").count
# => 3  (blank — returns all records)
```

**Prefix matching for SKU lookup**

```ruby
class Product < ApplicationRecord
  include ConcernsOnRails::Searchable

  searchable_by :sku, match: :prefix
end

Product.create!(sku: "ABC-100")
Product.create!(sku: "X-ABC-200")

Product.search("ABC").pluck(:sku)
# => ["ABC-100"]   (X-ABC-200 is excluded — "ABC" is not at the start)
```

**All-terms mode across title and body**

```ruby
class Book < ApplicationRecord
  include ConcernsOnRails::Searchable

  searchable_by :title, :body, mode: :all
end

Book.create!(title: "Ruby on Rails", body: "web framework")
Book.create!(title: "Ruby",          body: "language")

Book.search("ruby framework").pluck(:title)
# => ["Ruby on Rails"]
# Both "ruby" and "framework" must appear somewhere across title or body.

Book.search("ruby language").pluck(:title)
# => ["Ruby"]
```

## Notes & gotchas

- **At least one field is required.** Calling `searchable_by` with no arguments raises `ArgumentError` immediately at class-load time (message includes "at least one field").
- **All configured columns must exist in the schema.** `searchable_by` calls `ensure_columns!` via `ConcernsOnRails::Support::ColumnGuard` and raises `ArgumentError` (message: `'<column>' does not exist in the database (table: <table>)`) for any column not present at load time. This means the table must exist when the class is loaded — a concern in test suites that define tables dynamically.
- **Invalid `mode:` or `match:` values raise immediately.** Unknown symbols raise `ArgumentError` with messages matching `/unknown mode/` and `/unknown match/` respectively, caught at class definition time.
- **User input wildcard escaping is automatic.** The characters `%`, `_`, and `\` are escaped before interpolation using a backslash escape character (`\`). Searching for `"100%"` will find rows literally containing `100%` and will not match everything.
- **Blank and nil queries are safe no-ops.** `nil`, `""`, and strings consisting entirely of whitespace all return `all` — the unfiltered relation. This makes it safe to pass `params[:q]` directly without a presence guard in the controller.
- **Case sensitivity is adapter-dependent.** With `case_sensitive: false` (the default), Arel emits `ILIKE` on PostgreSQL, which is genuinely case-insensitive. On SQLite, `LIKE` is used and is case-insensitive for ASCII characters by default, but case-sensitive for non-ASCII. On MySQL, case sensitivity depends on the column collation, not the `ILIKE`/`LIKE` distinction.
- **`mode: :all` splits on whitespace only.** The split is `String#split` with no argument, which splits on any whitespace run. There is no phrase-quoting or stop-word handling. A query of `"ruby on rails"` produces three terms: `"ruby"`, `"on"`, `"rails"`.
- **`searchable_by` is not additive.** Calling it a second time on the same class replaces `searchable_fields`, `searchable_mode`, `searchable_match`, and `searchable_case_sensitive` entirely — it does not merge with a previous call.
- **No full-text indexes are created.** For large tables, performance depends entirely on a sequential scan against the LIKE pattern. Consider `pg_search` (PostgreSQL) or a dedicated search service when the table grows beyond a few hundred thousand rows or when ranking and stemming are needed.
