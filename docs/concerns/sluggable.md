`Sluggable` generates and maintains URL-friendly slug strings on ActiveRecord models by wrapping the [`friendly_id`](https://github.com/norman/friendly_id) gem behind a single declarative macro. It automatically transliterates Unicode, downcases, and hyphenates the configured source attribute, writes the result into a `slug` column, and regenerates the slug whenever that attribute changes — without any extra callbacks or observers in application code.

## When to use it

- A blog or CMS where posts, pages, or categories need clean `/posts/my-first-post` URLs instead of `/posts/42`.
- A multi-tenant SaaS where the same slug must be allowed in different accounts (use `scope:`).
- A content site that renames articles but must keep old URLs resolving (use `history:`).
- Any resource where certain route-conflicting words (`new`, `edit`, `admin`) must be blocked from becoming slugs (use `reserved_words:`).
- A lookup-heavy read path where you want `Model.find("slug-string")` to work transparently alongside `Model.find(id)` (use `finders:`).

## Installation

Add the include and the configuration macro to your model:

```ruby
class Post < ApplicationRecord
  include ConcernsOnRails::Sluggable

  sluggable_by :title
end
```

`ConcernsOnRails::Models::Sluggable` is the canonical, fully-namespaced name of the module; `ConcernsOnRails::Sluggable` is a legacy alias for it (`Sluggable = Models::Sluggable`). Both resolve to the same module, so either include works.

## Database columns

| Column | Type   | Required | Notes                                                            |
|--------|--------|----------|------------------------------------------------------------------|
| `slug` | string | Yes      | Populated and maintained automatically by `friendly_id`          |
| source field (e.g. `title`) | string | Yes | The attribute passed to `sluggable_by` |
| scope column (e.g. `account_id`) | any | Conditional | Required when `scope:` option is used |

Generate the migration for the `slug` column:

```ruby
class AddSlugToPosts < ActiveRecord::Migration[7.0]
  def change
    add_column :posts, :slug, :string
    add_index  :posts, :slug, unique: true
  end
end
```

When `history: true` is used, `friendly_id`'s slug history table is also required. Generate it with:

```sh
rails generate friendly_id
rails db:migrate
```

Or add it manually:

```ruby
class CreateFriendlyIdSlugs < ActiveRecord::Migration[7.0]
  def change
    create_table :friendly_id_slugs do |t|
      t.string   :slug,           null: false
      t.integer  :sluggable_id,   null: false
      t.string   :sluggable_type, limit: 50
      t.string   :scope
      t.datetime :created_at
    end
    add_index :friendly_id_slugs, :sluggable_id
    add_index :friendly_id_slugs, [:slug, :sluggable_type]
    add_index :friendly_id_slugs, [:slug, :sluggable_type, :scope], unique: true
  end
end
```

## Configuration

`sluggable_by` is the sole configuration macro. It must be called after `include ConcernsOnRails::Sluggable`.

```ruby
sluggable_by :title
sluggable_by :title, history: true
sluggable_by :title, scope: :account_id
sluggable_by :title, reserved_words: %w[new edit admin]
sluggable_by :title, finders: true
```

| Option | Type | Default | Description |
|---|---|---|---|
| `field` (positional) | Symbol | `:name` | The model attribute whose value is used as the slug source. Must exist as a database column. |
| `history:` | Boolean | `false` | Activates `friendly_id`'s `:history` module. Old slugs remain resolvable via `Model.friendly.find` after the source attribute changes. Requires a `friendly_id_slugs` table. |
| `scope:` | Symbol / nil | `nil` | Activates `friendly_id`'s `:scoped` module. Slug uniqueness is enforced only within the given column (e.g. `account_id`), allowing the same slug across different scope values. A saved record moved to another scope (the column changes) keeps its slug when the new scope has it free — a hand-assigned slug and its URLs survive the move — and rebuilds it against the new scope when that scope already holds it (friendly_id's uuid suffix when the plain slug is taken there too); a slug assigned in the same save still wins. The named column must exist in the table. |
| `reserved_words:` | Array\<String\> / nil | `nil` | Activates `friendly_id`'s `:reserved` module. Records whose generated slug matches any entry in this list fail validation with an error message containing "reserved". Values are coerced to strings. |
| `finders:` | Boolean | `false` | Activates `friendly_id`'s `:finders` module. `Model.find` accepts a slug string in addition to a numeric id, so no `Model.friendly.find` call is needed at call sites. |
| `candidates:` | Array / nil | `nil` | friendly_id slug candidates, tried in order until one is available: each entry is a Symbol/String (a method on the record), a Proc, or an Array of those (values joined with the sequence separator) — `[:title, %i[title city], %i[title city year]]`. Only when every candidate is taken does friendly_id fall back to the first candidate plus its uuid suffix. Regeneration is still driven by the primary `field` changing; a NULL slug backfills through the candidates. Must be a non-empty Array. No Symbol/String candidate (nor `field`, when no `candidates:` replace it) may be an [Encryptable](encryptable.md) field or an `alias_attribute` of one — the slug would be its plaintext — which raises `ArgumentError` from either declaration order, before the declaration is applied; Encryptable also refuses such a save, covering an include of Sluggable without `sluggable_by` (the implicit `:name`). |
| `max_length:` | Integer / nil | `nil` | Truncate each candidate to at most this many characters at the last separator (`-`) inside the limit — `"the-quick-brown-fox"` → `"the-quick"` at 12 — falling back to a hard cut for a single long word. Applied before the uniqueness check, so friendly_id's conflict suffix is appended *after* and may exceed the limit (friendly_id's own `slug_limit` instead squeezes the uuid inside it). Must be a positive Integer. |

Options can be combined freely: `sluggable_by :title, history: true, scope: :account_id, finders: true`.

## Scopes

`Sluggable` itself does not add custom ActiveRecord scopes. The underlying `friendly_id` gem's `.friendly` finder is available on any model that includes this concern:

```ruby
Post.friendly.find("hello-world")   # always available
Post.find("hello-world")            # available only when finders: true
```

## Methods

### Instance methods

| Signature | Description |
|---|---|
| `slug_source` | Returns the current value of the configured `sluggable_field` attribute (falling back to `to_s`), or — with `candidates:` — the candidates Array for friendly_id to resolve. Used internally by `friendly_id` to derive the slug. |
| `regenerate_slug!` | Rebuilds the slug from the current source (candidates included) and `save!`s — even over a slug that was assigned by hand, which a normal save deliberately leaves alone. A conflict still gets friendly_id's uuid suffix. Returns `true`; raises `ActiveRecord::RecordInvalid` like `save!`. |
| `should_generate_new_friendly_id?` | Returns `true` when the configured source attribute has a pending change (via `will_save_change_to_<field>?`), when the slug is blank, when a saved record's `scope:` column has a pending change, or during `regenerate_slug!`; `false` while the slug column itself is being assigned a non-blank value — unless the pending slug is one friendly_id built earlier in the same save whose candidates have changed since (see *Order-independent slug source*). Overrides `friendly_id`'s default behavior so slugs regenerate on every update that changes the source field. |
| `normalize_friendly_id(value)` | friendly_id's normalization plus the `max_length:` word-boundary truncation. Defined on the including class so it takes precedence over friendly_id's module. |

### Class methods

| Signature | Description |
|---|---|
| `sluggable_by(field, history:, scope:, reserved_words:, finders:, candidates:, max_length:)` | Configures the slug source column and optionally enables additional `friendly_id` modules. Raises `ArgumentError` if `field` or the `scope:` column does not exist in the schema. |

## Examples

Basic slug generation and automatic update on rename:

```ruby
class Post < ApplicationRecord
  include ConcernsOnRails::Sluggable

  sluggable_by :title
end

post = Post.create!(title: "Hello World")
post.slug           # => "hello-world"

post.update!(title: "Hello, Rails!")
post.slug           # => "hello-rails"

Post.friendly.find("hello-rails")  # => post
```

Scoped slugs allowing the same value across tenants:

```ruby
class Article < ApplicationRecord
  include ConcernsOnRails::Sluggable

  sluggable_by :title, scope: :account_id
end

Article.create!(title: "Welcome", account_id: 1).slug  # => "welcome"
Article.create!(title: "Welcome", account_id: 2).slug  # => "welcome"  (no conflict)
```

Slug history so renamed records remain findable at their old URLs:

```ruby
class Page < ApplicationRecord
  include ConcernsOnRails::Sluggable

  sluggable_by :title, history: true
end

page = Page.create!(title: "Original Title")
old_slug = page.slug      # => "original-title"
page.update!(title: "New Title")
page.slug                 # => "new-title"

Page.friendly.find(old_slug)  # => page  (still resolves)
```

## Notes & gotchas

- **`friendly_id` is a runtime dependency, loaded lazily.** The gem must be in your `Gemfile`, but it is loaded only when `Sluggable` is first referenced — apps that never use the concern never load it. If the gem is missing, referencing `Sluggable` raises `ConcernsOnRails::MissingDependency` (a `LoadError` subclass) whose message names the Gemfile line to add.
- **Column validation is eager.** `sluggable_by` validates the source `field`, the slug column, and any `scope:` column at class-load time. A missing column raises `ArgumentError` with the message `"ConcernsOnRails::Models::Sluggable: '<field>' does not exist in the database (table: <table>)."` followed by a ready-to-paste `bin/rails generate migration` command (the slug column is suggested as `slug:string:uniq`). This fires at boot, not at record save time.
- **`slug` column must be added manually.** The concern does not generate the column, but since 1.22 `sluggable_by` does validate its existence — a model missing it fails at macro time with the ColumnGuard `ArgumentError` above instead of an opaque `friendly_id` error at first save.
- **Slug regeneration is change-driven.** `should_generate_new_friendly_id?` uses `will_save_change_to_<field>?`, so the slug is regenerated only when the source attribute (or, with `scope:`, the scope column of a saved record) has a dirty change pending. Updating unrelated attributes (e.g. `updated_at`) does not regenerate the slug.
- **Order-independent slug source.** friendly_id builds the slug in a `before_validation` registered when `Sluggable` is included, so a sibling included later that transforms the source — [Sanitizable](sanitizable.md) `on: :write`, [Normalizable](normalizable.md), your own `before_validation` — used to run after the slug was built from the raw value (`"<b>Hello</b>"` → slug `"b-hello-b"`, title `"Hello"`). A slug built earlier in the same save whose normalized candidates no longer match the source is now rebuilt at the start of validation — before any validator (`reserved_words:` included) or sibling `before_save` sees it. A transform that doesn't change the normalized slug (`"Hello  World"` squished) costs no rebuild.
- **Slugs from generated columns.** A source filled in `before_create` — [Sequenceable](sequenceable.md)'s `into:` number, a [Hashable](hashable.md) code — did not exist when friendly_id ran, so the row was stored slug-less until a later save backfilled it. Those producers now report the value (`Support::GeneratedValues`) and the slug is built right then, in the same `INSERT`, with friendly_id's usual rules (conflict suffix, candidates). Built after every `before_validation`/`before_save`, it gets what those would have applied: a reserved word is resolved like a taken one (uuid suffix) instead of failing validation, and the slug column's own write-time rules — a write-mode [Sanitizable](sanitizable.md) rule, then a [Normalizable](normalizable.md) rule on `:slug` — are applied to it (`normalizable :slug, with: ->(v) { v.tr("-", "_") }` → `"inv_1"`).
- **An explicitly assigned slug still wins.** Neither rebuild touches a slug you assigned (`create!(slug: "custom")`), or one changed after friendly_id built it; `regenerate_slug!` remains the way to force one.
- **A blank slug is never stored while there is a source.** An assigned `""` (an optional slug field in a form) or `nil` (friendly_id's idiom for "give me a fresh slug") is built from the source in the same save, on create and update alike — a second `create!(title: "Two", slug: "")` no longer trips the slug's unique index. With a blank source too, there is nothing to build from and the blank value is stored.
- **Duplicate slugs are disambiguated automatically.** When two records share the same source value, `friendly_id` appends a UUID-derived suffix to ensure uniqueness (e.g. `"same"` and `"same-a1b2c3d4"`).
- **Unicode is transliterated.** The `:slugged` strategy converts accented and non-ASCII characters; `"Tiếng Việt có dấu"` becomes `"ti-ng-vi-t-co-d-u"`. The exact output depends on `friendly_id`'s transliteration tables.
- **Reserved words raise a validation error, not an `ArgumentError`.** When `reserved_words:` is configured and a record's slug matches a reserved entry, `create!` / `save!` raises `ActiveRecord::RecordInvalid` with a message matching `/reserved/i`. The record is not persisted.
- **`history: true` requires the `friendly_id_slugs` table.** Without it, saves will raise a database error. Run `rails generate friendly_id` or add the migration manually before enabling this option in production.
- **`finders: true` vs `.friendly.find`.** Without `finders: true`, slug-based lookup requires `Model.friendly.find("slug")`. With it, the standard `Model.find("slug")` also works, but mixed numeric-and-slug `find` calls may behave unexpectedly on strings that look like integers.
- **Default `sluggable_field` is `:name`.** If `sluggable_by` is never called, the concern defaults to `:name` as the source field. Calling `sluggable_by` with an explicit field overrides this class attribute.
- **Refuses to share `to_param` with Hashable.** `friendly_id` overrides `to_param`, and so does `hashable_by ..., to_param: true` — whichever concern is included last silently wins. Including `Sluggable` on a model already configured that way raises `ArgumentError` at class load, and the mirror guard in `Hashable` covers the opposite declaration order. Drop one, or override `to_param` on the model yourself.
- **`slug_source` falls back to `to_s`.** If the model does not respond to the configured field (e.g. in a subclass that overrides `column_names` or excludes the column), `slug_source` returns `to_s` rather than raising, which may produce unexpected slug values.

## Changed in 1.22.0

- The slug column itself is validated at macro time — a model missing it now fails with the concern's clear `ArgumentError` instead of an opaque friendly_id error at first save.
