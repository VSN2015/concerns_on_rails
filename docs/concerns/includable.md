`Includable` is a controller concern that enforces a strict allow-list for association sideloading and sparse fieldsets in JSON APIs. It solves two related problems: arbitrary `?include=` parameters from clients that could trigger `.includes` on any association (N+1 risk and unintended data exposure), and unfiltered `?fields[table]=col,...` parameters that could return columns the application never intended to serialize. Only associations and columns you declare in the `includable` macro can be requested by clients — everything else is silently dropped before it reaches the query or serializer. The allow-list is a tree, so nested JSON:API paths (`?include=comments.author`) work exactly as far as you permit them; `default:` picks what loads when the client asks for nothing, and `strategy:` chooses between `includes`, `preload` and `eager_load`.

## When to use it

- A JSON API endpoint supports `?include=author,comments` and the association list must be constrained to a safe subset regardless of what the client sends.
- A serializer (ActiveModelSerializers, Blueprinter, jsonapi-serializer) accepts a `fields:` hash for sparse fieldsets and the allowed columns per resource type must be declared server-side.
- Multiple controllers share the same underlying model but expose different association subsets; each controller declares its own allow-list independently.
- An endpoint aggregates several resource types and the field allow-list differs per resource table (e.g. `articles` exposes `id,title` while `authors` exposes `id,name`).
- A security audit requires proof that no client-supplied string can ever be passed unfiltered to `ActiveRecord::Base.includes`.
- A JSON:API client sends nested paths (`?include=comments.author,comments.reactions`) and you want to permit exactly those two levels — not `comments.author.payment_methods`.
- An endpoint should always sideload one association unless the client explicitly asks for something else (`default: :author`).

## Installation

Include `ConcernsOnRails::Controllers::Includable` in any controller and call the `includable` macro:

```ruby
class ArticlesController < ApplicationController
  include ConcernsOnRails::Controllers::Includable

  includable :author, comments: :author,
             fields: { articles: %i[id title published_at], authors: %i[id name] },
             default: :author,
             strategy: :preload

  def index
    render json: with_includes(Article.all),
           include: requested_includes(as: :json),
           fields:  requested_fields
  end
end
```

## Configuration

The `includable` macro accepts association arguments in the same shapes `ActiveRecord::QueryMethods#includes` does — Symbols, dotted Strings, Arrays and nested Hashes — plus `fields:`, `default:` and `strategy:` keywords.

```
includable(*associations, fields: {}, default: nil, strategy: :includes)
```

| Option | Type | Default | Description |
|---|---|---|---|
| `*associations` | `Symbol`, dotted `String`, `Array`, nested `Hash` (variadic) | `[]` | The association **tree** clients may request via `?include=`: `:author` allows `author`; `comments: :author` allows `comments` and `comments.author`; `comments: [:author, { reactions: :user }]` goes deeper. A requested path is kept only when every segment exists in the tree. Stored as a nested Hash on `includable_tree`; the top-level names on `includable_associations` (`Array<Symbol>`). |
| `fields:` | `Hash{ Symbol/String => Array<Symbol/String> }` | `{}` | Sparse fieldset allow-list keyed by resource table name. Each value is the list of column names the client may request for that table via `?fields[table]=col,...`. Keys and values are normalized to `Symbol`. Stored as `Hash{ Symbol => Array<Symbol> }` on `includable_fields`. |
| `default:` | same shapes as `*associations` | `nil` | Paths eager-loaded (and returned by `requested_includes`) when the request has **no** `include` parameter at all. Every default path must be allow-listed, or `ArgumentError` is raised at class load. A blank `?include=` disables them for that request. Stored as dotted Strings on `includable_default_paths`. |
| `strategy:` | `:includes`, `:preload` or `:eager_load` | `:includes` | The relation method `with_includes` calls. `:includes` lets ActiveRecord choose (it switches to a JOIN when the association is referenced in a `where`), `:preload` always issues separate queries, `:eager_load` always JOINs. Anything else raises `ArgumentError`. |

All of `includable_tree`, `includable_associations`, `includable_fields`, `includable_default_paths` and `includable_strategy` are `class_attribute`s; calling `includable` replaces them entirely (not merges).

## Methods

### Instance methods

**`with_includes(relation) → ActiveRecord::Relation`**
Resolves the allow-listed include paths for this request (see `requested_include_paths`) and applies them with the configured `strategy:` — `relation.includes(:author, { comments: :author })` by default. Returns `relation` unchanged when nothing valid was requested and no `default:` applies.

**`requested_includes(as: :query) → Array`**
The sanitized includes in the shape you need:

| `as:` | Returns | Hand it to |
|---|---|---|
| `:query` (default) | `[:author, { comments: :author }]` | `includes`/`preload`/`eager_load`, ActiveModelSerializers `include:`, Blueprinter |
| `:paths` | `["author", "comments.author"]` | jsonapi-serializer / JSON:API `include:` options |
| `:json` | `[:author, { comments: { include: :author } }]` | `as_json(include:)` / `render json: records, include:` |

Flat allow-lists keep returning a plain `Array<Symbol>` under `:query`, so existing call sites are unchanged. An unknown `as:` raises `ArgumentError`.

**`requested_include_paths → Array<String>`**
The allow-listed dotted paths from `params[:include]` in request order, deduplicated. Accepts a comma-separated String or an Array of them; a hash-shaped param yields `[]`. When the param is absent entirely the `default:` paths are returned; when it is present but blank, `[]`.

**`requested_fields → Hash{ Symbol => Array<Symbol> }`**
Parses `params[:fields]` as a hash of `{ table => col_list }` pairs. Tables not present in `includable_fields` are dropped. Within each allowed table, the requested columns are intersected with the declared allow-list. Tables for which the intersection is empty are also dropped from the result. Returns `{}` when `params[:fields]` is absent or is not a hash-like object. Safe to pass directly to a serializer's `fields:` keyword.

### Class methods

**`includable(*associations, fields: {}, default: nil, strategy: :includes) → void`**
Declares the allow-lists for this controller. Calling the macro more than once replaces the previous allow-lists — it does not accumulate. Symbols, dotted Strings, Arrays and nested Hashes are accepted for associations (normalized into the `includable_tree`); Symbols and Strings for field keys/values. `default:` paths are validated against the tree and `strategy:` against `includes`/`preload`/`eager_load`, both raising `ArgumentError` at class load.

## Examples

**Basic sideloading**

```ruby
class StoriesController < ApplicationController
  include ConcernsOnRails::Controllers::Includable

  includable :writer, :remarks,
             fields: { stories: %i[id title], writers: %i[id name] }

  def index
    # GET /stories?include=writer,remarks&fields[stories]=id,title&fields[writers]=id,name
    render json: with_includes(Story.all),
           include: requested_includes,
           fields:  requested_fields
  end
end
```

**Allow-list enforcement in practice**

```ruby
# Request: GET /stories?include=writer,secret_association
# params[:include] => "writer,secret_association"

# Inside the controller action, the concern's instance helpers return:
requested_includes
# => [:writer]   — :secret_association is silently dropped

with_includes(Story.all).includes_values
# => [:writer]   — only the whitelisted association is eager-loaded
```

**Sparse fieldsets with partial client requests**

```ruby
# Request: GET /stories?fields[stories]=id,title,secret_column&fields[unknown_table]=x
# params[:fields] => { "stories" => "id,title,secret_column", "unknown_table" => "x" }

# Inside the controller action:
requested_fields
# => { stories: [:id, :title] }
# :secret_column is dropped (not in allow-list); :unknown_table is dropped entirely
```

**Nested paths, defaults and the three shapes**

```ruby
class StoriesController < ApplicationController
  include ConcernsOnRails::Controllers::Includable

  includable writer: :stories, remarks: :story, default: :writer, strategy: :preload
end

# GET /stories?include=remarks.story,writer.stories,writer.secret,remarks.story.writer
requested_include_paths            # => ["remarks.story", "writer.stories"]   (the two unknown tails are dropped)
requested_includes                 # => [{ remarks: :story }, { writer: :stories }]
requested_includes(as: :json)      # => [{ remarks: { include: :story } }, { writer: { include: :stories } }]
with_includes(Story.all)           # => Story.preload({ remarks: :story }, { writer: :stories })

# GET /stories            (no include param)  → default applies
requested_includes                 # => [:writer]
# GET /stories?include=   (blank)             → the client asked for nothing
requested_includes                 # => []
```

## Notes & gotchas

- **A path is all-or-nothing.** `comments.author.payment_methods` is dropped entirely when `payment_methods` is not in the tree — the concern never trims a path down to its allowed prefix, because the client asked for something specific and silently serving less would be confusing. Ask for `comments.author` explicitly if that is what you want.
- **`default:` means "absent", not "blank".** JSON:API semantics: a client that sends `?include=` is opting out of defaults. Treat the two cases differently in your tests.
- **`strategy: :eager_load` + sparse fieldsets.** `eager_load` JOINs every requested association into one query; combining it with a `select` of a few columns needs the joined tables' columns too. Prefer `:preload` when you also select columns.
- **Non-whitelisted values are silently dropped, not raised.** Both `requested_includes` and `requested_fields` return sanitized results without raising errors or setting response status. A client requesting `?include=secret` receives a response as if the parameter were absent.
- **`with_includes` returns the relation unchanged when nothing valid is requested.** `includes_values` on the returned relation will be `[]`, not `nil`, matching ActiveRecord's default behavior.
- **`params[:fields]` must be a hash-like object.** `requested_fields` checks `raw.respond_to?(:each_pair)` before iterating. A non-hash value (e.g. a string) returns `{}` rather than raising.
- **Column lists accept both comma-separated strings and arrays.** The private `split_field_list` helper handles both forms, so `?fields[stories]=id,title` and a Rails-style `params[:fields][:stories]` array are both valid inputs.
- **Calling `includable` more than once replaces the allow-lists entirely.** There is no merge/append behavior; the last call wins.
- **`includable_associations` and `includable_fields` are `class_attribute`s.** Subclassing a controller that has already called `includable` inherits the parent's allow-lists but can override them independently by calling `includable` again in the subclass.
- **The concern does not serialize or render anything.** `with_includes` only affects the ActiveRecord query. `requested_includes` and `requested_fields` return plain Ruby values for the caller to pass to `render json:` or a serializer. The concern has no knowledge of the serializer in use.
- **No runtime dependencies beyond `ActiveSupport::Concern`.** There are no gem dependencies beyond Rails itself; the concern works with any serializer.

## Changed in 1.22.0

- Sparse fieldsets no longer 500: in a real controller `params[:fields]` is an `ActionController::Parameters` (no `each_with_object`), so every `?fields[...]=` request raised `NoMethodError` before 1.22.
