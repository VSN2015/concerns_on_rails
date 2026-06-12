Aliases an existing ActiveRecord association under a second name with **full** semantics — read, write/assign, build/create, and the query side (`joins` / `includes` / `preload` / `eager_load` / `where`-hash conditions) — not just a delegated reader. Rails' `alias_attribute` covers columns only; there is no built-in way to alias an association.

## When to use it

- **Association renames without a flag day.** Roll out `has_many :clients` while every existing call site still says `customers` — both names stay fully functional (including queries) until the old one is retired.
- **Domain language vs. schema language.** The table says `users`, the business says *members*: expose `team.members` (and `Team.joins(:members)`) without touching the schema.
- **API backwards compatibility.** Serializers, GraphQL types, or nested-attributes endpoints that must keep accepting the old association name after a model refactor.
- **A maintained replacement for the unmaintained `alias_association` gem** — with assignment, ids writers, and the query side included.

## Installation

Include the concern and declare aliases **after** the source association.

```ruby
class Book < ApplicationRecord
  include ConcernsOnRails::Aliasable

  belongs_to :author
  has_many :chapters

  alias_association :writer,   :author      # alias_method order: new, old
  alias_association :sections, :chapters
end
```

## Database columns

**None required.** The macro validates that the alias would not collide with an existing column or attribute, but only when a database connection and table are available — class loading without a database (`rake db:create`, `assets:precompile`) never crashes; the column sweep is simply skipped.

## Configuration

### `alias_association(new_name, source_name)`

Class-level macro, callable any number of times. The argument order mirrors `alias_method new, old`.

| Rule | Behavior |
|---|---|
| Source must already exist | Raises `ArgumentError` (“does not exist”) when called before the source association is declared. |
| Collisions are rejected | The **full** derived method map (reader, writer, `build_`/`create_`/`create_!`/`reload_`/`reset_`, the `_ids` pair) is swept against existing associations, methods, columns, and virtual attributes. |
| Aliases of aliases collapse | `alias_association :catalog, :works` (where `:works` already aliases `:books`) maps `:catalog` straight to `:books`. |
| Re-declaring is allowed | Declaring an existing alias again **with the same source** (the subclass path — see Notes) refreshes its reflection instead of raising. Repointing an alias at a *different* source raises. |
| HABTM is rejected | `has_and_belongs_to_many` sources raise `ArgumentError` — use `has_many :through`. |
| `:through` is supported | `has_many`/`has_one :through` sources work — the reflection copy pins `source:` so it is not re-derived from the alias name (see Notes for the lazy-loading caveat). |

### Options

| Option | Default | Description |
|---|---|---|
| `only:` / `except:` | all groups | Narrow the generated methods by group: `:reader`, `:writer`, `:build`, `:reload` (singular), `:ids` (collection). Unknown groups raise; groups that don't apply to the reflection type are ignored. The query side (`joins`/`includes`/`where`-hash) is always registered. Re-declaring with narrower groups prunes the now-unwanted delegators. |
| `deprecated:` | `nil` | `true` or a String hint. Every generated delegator warns through `ConcernsOnRails.deprecator` before delegating — the gradual-rename story (alias the old name to the renamed association and deprecate it). Configure the channel with `ConcernsOnRails.deprecator.behavior = :log` etc. The query side and `alias_foreign_key` attribute aliases do not warn. |
| `alias_foreign_key:` | `false` | `belongs_to` only — also aliases the FK attribute via Rails' `alias_attribute`: `<alias>_id`, plus `<alias>_type` when polymorphic. The names join the collision sweep. |

## Methods

For `alias_association :works, :books` (collection) and `alias_association :writer, :author` (singular):

### Collection aliases

| Method | Delegates to |
|---|---|
| `works` | `books` (the **same** `CollectionProxy` object) |
| `works=` | `books=` |
| `work_ids` / `work_ids=` | `book_ids` / `book_ids=` |

### Singular aliases (`belongs_to` / `has_one`)

| Method | Delegates to |
|---|---|
| `writer` / `writer=` | `author` / `author=` |
| `build_writer` / `create_writer` / `create_writer!` | `build_author` / … (not defined for polymorphic `belongs_to` — Rails defines no `build_`/`create_` there either) |
| `reload_writer` / `reset_writer` | `reload_author` / `reset_author` (defined only when the running Rails defines the source method) |

### Query side

| Usage | Behavior |
|---|---|
| `Author.joins(:works)` | Joins `books` (aliased as `works` when a `where`-hash references the alias). |
| `Author.joins(:works).where(works: { title: "X" })` | Full hash-condition support through the alias. |
| `Author.includes(:works)` / `preload` / `eager_load` | Loads once, fills the **shared** cache — both `works.loaded?` and `books.loaded?` become true. |
| `Author.reflect_on_association(:works)` | Returns a renamed copy of the source reflection (same macro/klass/table; compare attributes, not object identity). |
| `record.association(:works)` | IS `record.association(:books)` — one loaded cache under two names. |

## Examples

**Rename rollout**

```ruby
class Team < ApplicationRecord
  include ConcernsOnRails::Aliasable

  has_many :users
  alias_association :members, :users
end

team.members << user                     # writes through the one real association
Team.joins(:members).where(members: { active: true })
# SELECT "teams".* FROM "teams"
#   INNER JOIN "users" "members" ON "members"."team_id" = "teams"."id"
#   WHERE "members"."active" = 1
```

**Nested attributes through the alias**

```ruby
class Author < ApplicationRecord
  include ConcernsOnRails::Aliasable

  has_many :books
  alias_association :works, :books
  accepts_nested_attributes_for :works   # works_attributes= creates books
end
```

## Notes & gotchas

- **One loaded cache, one set of callbacks.** `record.association(:alias)` is the source's association object, and only the source macro installs callbacks — `dependent:`, counter caches, autosave, and validations run exactly once. Children added through the alias on a new parent autosave normally.
- **The where-hash key must match the name you joined under** (the same rule stock Rails applies to any renamed association): `joins(:works).where(works: {...})` works; `joins(:books).where(works: {...})` raises `StatementInvalid`.
- **SQL naming.** A bare `joins(:works)` joins `"books"` directly; pairing it with `where(works: {...})` makes Rails alias the join (`INNER JOIN "books" "works"`). Raw SQL fragments must reference the name actually joined.
- **The `belongs_to` foreign-key attribute is not aliased.** `book.writer_id` is not defined — pair with Rails' `alias_attribute :writer_id, :author_id` when needed.
- **`:through` aliases and lazy loading.** When the alias is declared before the through model's class has loaded (the usual class-body + autoloading case), the copy pins `source:` to the source association's own name — Rails' derivation anchor. If the through model defines the source under a *different* name (e.g. `belongs_to :author` behind `has_many :authors`), declare `source:` explicitly on the original association; it is copied verbatim.
- **Subclasses inherit aliases.** If a subclass redefines the source association, re-declare the alias there (allowed and idempotent) so the query side picks up the new reflection. Declaring aliases on *anonymous* classes hits stock Rails' anonymous-class limitation for the query side, exactly like declaring any association on one.
- **The reflection is a macro-time snapshot.** The renamed copy captures the source's scope and options when `alias_association` runs; redefine-then-re-declare is the supported refresh path.
- **`_reflections` key form is probed at runtime** (String-keyed on Rails <= 7.x, Symbol-keyed on newer releases), so the concern works across the gem's supported range without version checks.
- **Zero new runtime dependencies.**
