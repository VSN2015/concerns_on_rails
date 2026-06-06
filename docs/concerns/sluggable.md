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
| `scope:` | Symbol / nil | `nil` | Activates `friendly_id`'s `:scoped` module. Slug uniqueness is enforced only within the given column (e.g. `account_id`), allowing the same slug across different scope values. The named column must exist in the table. |
| `reserved_words:` | Array\<String\> / nil | `nil` | Activates `friendly_id`'s `:reserved` module. Records whose generated slug matches any entry in this list fail validation with an error message containing "reserved". Values are coerced to strings. |
| `finders:` | Boolean | `false` | Activates `friendly_id`'s `:finders` module. `Model.find` accepts a slug string in addition to a numeric id, so no `Model.friendly.find` call is needed at call sites. |

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
| `slug_source` | Returns the current value of the configured `sluggable_field` attribute. If the model does not respond to that attribute, falls back to `to_s`. Used internally by `friendly_id` to derive the slug. |
| `should_generate_new_friendly_id?` | Returns `true` when the configured source attribute has a pending change (via `will_save_change_to_<field>?`). Overrides `friendly_id`'s default behavior so slugs regenerate on every update that changes the source field. |

### Class methods

| Signature | Description |
|---|---|
| `sluggable_by(field, history:, scope:, reserved_words:, finders:)` | Configures the slug source column and optionally enables additional `friendly_id` modules. Raises `ArgumentError` if `field` or the `scope:` column does not exist in the schema. |

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

- **`friendly_id` is a runtime dependency.** The gem must be in your `Gemfile`. `Sluggable` calls `extend FriendlyId` and `friendly_id :slug_source, use: :slugged` at include time, so omitting the gem causes a `LoadError` immediately.
- **Column validation is eager.** `sluggable_by` calls `ensure_columns!` at class-load time. If the declared `field` or `scope:` column does not exist in the database schema, an `ArgumentError` is raised with the message `"ConcernsOnRails::Models::Sluggable: '<field>' does not exist in the database (table: <table>)"`. This fires at boot, not at record save time.
- **`slug` column must be added manually.** The concern does not generate or validate the existence of the `slug` column itself; `friendly_id` expects to find it and will raise a database-level error if it is absent.
- **Slug regeneration is change-driven.** `should_generate_new_friendly_id?` uses `will_save_change_to_<field>?`, so the slug is regenerated only when the source attribute has a dirty change pending. Updating unrelated attributes (e.g. `updated_at`) does not regenerate the slug.
- **Duplicate slugs are disambiguated automatically.** When two records share the same source value, `friendly_id` appends a UUID-derived suffix to ensure uniqueness (e.g. `"same"` and `"same-a1b2c3d4"`).
- **Unicode is transliterated.** The `:slugged` strategy converts accented and non-ASCII characters; `"Tiếng Việt có dấu"` becomes `"ti-ng-vi-t-co-d-u"`. The exact output depends on `friendly_id`'s transliteration tables.
- **Reserved words raise a validation error, not an `ArgumentError`.** When `reserved_words:` is configured and a record's slug matches a reserved entry, `create!` / `save!` raises `ActiveRecord::RecordInvalid` with a message matching `/reserved/i`. The record is not persisted.
- **`history: true` requires the `friendly_id_slugs` table.** Without it, saves will raise a database error. Run `rails generate friendly_id` or add the migration manually before enabling this option in production.
- **`finders: true` vs `.friendly.find`.** Without `finders: true`, slug-based lookup requires `Model.friendly.find("slug")`. With it, the standard `Model.find("slug")` also works, but mixed numeric-and-slug `find` calls may behave unexpectedly on strings that look like integers.
- **Default `sluggable_field` is `:name`.** If `sluggable_by` is never called, the concern defaults to `:name` as the source field. Calling `sluggable_by` with an explicit field overrides this class attribute.
- **`slug_source` falls back to `to_s`.** If the model does not respond to the configured field (e.g. in a subclass that overrides `column_names` or excludes the column), `slug_source` returns `to_s` rather than raising, which may produce unexpected slug values.
