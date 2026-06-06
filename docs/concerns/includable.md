`Includable` is a controller concern that enforces a strict allow-list for association sideloading and sparse fieldsets in JSON APIs. It solves two related problems: arbitrary `?include=` parameters from clients that could trigger `.includes` on any association (N+1 risk and unintended data exposure), and unfiltered `?fields[table]=col,...` parameters that could return columns the application never intended to serialize. Only associations and columns you declare in the `includable` macro can be requested by clients — everything else is silently dropped before it reaches the query or serializer.

## When to use it

- A JSON API endpoint supports `?include=author,comments` and the association list must be constrained to a safe subset regardless of what the client sends.
- A serializer (ActiveModelSerializers, Blueprinter, jsonapi-serializer) accepts a `fields:` hash for sparse fieldsets and the allowed columns per resource type must be declared server-side.
- Multiple controllers share the same underlying model but expose different association subsets; each controller declares its own allow-list independently.
- An endpoint aggregates several resource types and the field allow-list differs per resource table (e.g. `articles` exposes `id,title` while `authors` exposes `id,name`).
- A security audit requires proof that no client-supplied string can ever be passed unfiltered to `ActiveRecord::Base.includes`.

## Installation

Include `ConcernsOnRails::Controllers::Includable` in any controller and call the `includable` macro:

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

## Configuration

The `includable` macro accepts one or more association name arguments and an optional `fields:` keyword.

| Option | Type | Default | Description |
|---|---|---|---|
| `*associations` | `Symbol` / `String` (variadic) | `[]` | The associations that clients are allowed to request via `?include=`. Any value not listed here is silently dropped. Stored as `Array<Symbol>` on `includable_associations`. |
| `fields:` | `Hash{ Symbol/String => Array<Symbol/String> }` | `{}` | Sparse fieldset allow-list keyed by resource table name. Each value is the list of column names the client may request for that table via `?fields[table]=col,...`. Keys and values are normalized to `Symbol`. Stored as `Hash{ Symbol => Array<Symbol> }` on `includable_fields`. |

Both `includable_associations` and `includable_fields` are `class_attribute`s initialized to `[]` / `{}` at include time; calling `includable` replaces them entirely (not merges).

## Methods

### Instance methods

**`with_includes(relation) → ActiveRecord::Relation`**
Parses `params[:include]`, intersects the result with `includable_associations`, and calls `relation.includes(*associations)` when at least one valid association is present. Returns `relation` unchanged when `params[:include]` is absent or contains no whitelisted entries. The returned relation is the same object as the argument when nothing is eager-loaded.

**`requested_includes → Array<Symbol>`**
Parses `params[:include]` as a comma-separated string and returns the intersection with `includable_associations` as an array of symbols. Returns `[]` when the parameter is absent. Safe to pass directly to `render json:, include:`.

**`requested_fields → Hash{ Symbol => Array<Symbol> }`**
Parses `params[:fields]` as a hash of `{ table => col_list }` pairs. Tables not present in `includable_fields` are dropped. Within each allowed table, the requested columns are intersected with the declared allow-list. Tables for which the intersection is empty are also dropped from the result. Returns `{}` when `params[:fields]` is absent or is not a hash-like object. Safe to pass directly to a serializer's `fields:` keyword.

### Class methods

**`includable(*associations, fields: {}) → void`**
Declares the allow-lists for this controller. Calling the macro more than once replaces the previous allow-lists — it does not accumulate. Symbols and strings are both accepted for association names and field keys/values; all are normalized to `Symbol` internally.

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

controller = StoriesController.new(params: { include: "writer,secret_association" })
controller.requested_includes
# => [:writer]   — :secret_association is silently dropped

controller.with_includes(Story.all).includes_values
# => [:writer]   — only the whitelisted association is eager-loaded
```

**Sparse fieldsets with partial client requests**

```ruby
# Request: GET /stories?fields[stories]=id,title,secret_column&fields[unknown_table]=x
# params[:fields] => { "stories" => "id,title,secret_column", "unknown_table" => "x" }

controller = StoriesController.new(
  params: { fields: { stories: "id,title,secret_column", unknown_table: "x" } }
)
controller.requested_fields
# => { stories: [:id, :title] }
# :secret_column is dropped (not in allow-list); :unknown_table is dropped entirely
```

## Notes & gotchas

- **Non-whitelisted values are silently dropped, not raised.** Both `requested_includes` and `requested_fields` return sanitized results without raising errors or setting response status. A client requesting `?include=secret` receives a response as if the parameter were absent.
- **`with_includes` returns the relation unchanged when nothing valid is requested.** `includes_values` on the returned relation will be `[]`, not `nil`, matching ActiveRecord's default behavior.
- **`params[:fields]` must be a hash-like object.** `requested_fields` checks `raw.respond_to?(:each_pair)` before iterating. A non-hash value (e.g. a string) returns `{}` rather than raising.
- **Column lists accept both comma-separated strings and arrays.** The private `split_field_list` helper handles both forms, so `?fields[stories]=id,title` and a Rails-style `params[:fields][:stories]` array are both valid inputs.
- **Calling `includable` more than once replaces the allow-lists entirely.** There is no merge/append behavior; the last call wins.
- **`includable_associations` and `includable_fields` are `class_attribute`s.** Subclassing a controller that has already called `includable` inherits the parent's allow-lists but can override them independently by calling `includable` again in the subclass.
- **The concern does not serialize or render anything.** `with_includes` only affects the ActiveRecord query. `requested_includes` and `requested_fields` return plain Ruby values for the caller to pass to `render json:` or a serializer. The concern has no knowledge of the serializer in use.
- **No runtime dependencies beyond `ActiveSupport::Concern`.** There are no gem dependencies beyond Rails itself; the concern works with any serializer.
