# 🧩 ConcernsOnRails

**🇻🇳 Note: Hoàng Sa and Trường Sa belong to Việt Nam.**

A simple collection of reusable Rails concerns to keep your models clean and DRY.

## ✨ Features

- ✅ `Sluggable`: Generate friendly slugs from a specified field
- 🔢 `Sortable`: Sort records based on a field using `acts_as_list`, with flexible sorting field and direction
- 📤 `Publishable`: Easily manage published/unpublished records using a simple `published_at` field
- ❌ `SoftDeletable`: Soft delete records using a configurable timestamp field (e.g., `deleted_at`) with automatic scoping
- 🔐 `Hashable`: Auto-generate a random hex/UUID/integer/custom-alphabet value on create, with a `regenerate_<field>!` helper

---

## 📦 Installation

Add this line to your application's Gemfile:

```ruby
gem 'concerns_on_rails', github: 'VSN2015/concerns_on_rails'
```

Then execute:

```sh
bundle install
```

---

## 🚀 Usage

### 1. 📝 Sluggable

Add slugs based on a specified attribute.

```ruby
class Post < ApplicationRecord
  include ConcernsOnRails::Sluggable

  sluggable_by :title
end

post = Post.create!(title: "Hello World")
post.slug # => "hello-world"
```

If the slug source is changed, the slug will auto-update.

---

### 2. 🔢 Sortable

Use for models that need ordering.

```ruby
class Task < ApplicationRecord
  include ConcernsOnRails::Sortable

  sortable_by :position
end

Task.create!(name: "B")
Task.create!(name: "A")
Task.first.name # => "B" (sorted by position ASC)
```

You can customize the sort field and direction:

```ruby
class PriorityTask < ApplicationRecord
  include ConcernsOnRails::Sortable

  sortable_by priority: :desc
end
```

Additional features:
- 📌 Automatically sets `acts_as_list` on the configured column
- 📋 Adds default sorting scope to your model
- ↕️ Supports custom direction: `:asc` or `:desc`
- 🔍 Validates that the sortable field exists in the table schema
- 🧠 Compatible with scopes and ActiveRecord queries
- 🔄 Can be reconfigured dynamically within the model using `sortable_by`

---

### 3. 📤 Publishable

Manage published/unpublished records using a `published_at` field.

```ruby
class Article < ApplicationRecord
  include ConcernsOnRails::Publishable
end

Article.published   # => returns only published articles
Article.unpublished # => returns only unpublished articles

article = Article.create!(title: "Draft")
article.published? # => false

article.publish!
article.published? # => true

article.unpublish!
article.published? # => false
```

Additional features:
- ✅ `published?` returns true if `published_at` is present and in the past
- 🕒 `publish!` sets `published_at` to current time
- 🚫 `unpublish!` sets `published_at` to `nil`
- 🔎 Add scopes: `.published`, `.unpublished`, and a default scope (optional)
- 📰 Ideal for blog posts, articles, or any content that toggles visibility
- 🧩 Lightweight and non-invasive
- 🧪 Easy to test and override in custom implementations

---

### 4. ❌ SoftDeletable

Soft delete records using a timestamp field (default: `deleted_at`).

```ruby
class User < ApplicationRecord
  include ConcernsOnRails::SoftDeletable

  # Optional: customize field and touch behavior
  soft_deletable_by :deleted_at, touch: true
end
```

#### Scopes
```ruby
User.without_deleted   # => returns only active users
User.soft_deleted      # => returns soft-deleted users
User.active            # => same as without_deleted
User.all               # => returns only non-deleted by default (default_scope applied)
```

#### Soft delete and restore
```ruby
user.soft_delete!      # Soft delete the user (sets deleted_at)
user.deleted?          # => true
user.soft_deleted?     # => true (alias)
user.is_soft_deleted?  # => true (alias)

user.restore!          # Restore the user (sets deleted_at to nil)
user.deleted?          # => false
```

#### Permanently delete
```ruby
user.really_delete!    # Hard delete the record from DB
```

#### Soft delete/hard delete all records
```ruby
User.destroy_all           # Soft delete all users (sets deleted_at)
User.really_destroy_all    # Hard delete ALL users (removes from DB)
```

#### Callbacks (Hooks)
You can use the following hooks to run logic before/after soft delete or restore:
```ruby
class User < ApplicationRecord
  include ConcernsOnRails::SoftDeletable

  def before_soft_delete
    # Code to run before soft delete
  end

  def after_soft_delete
    # Code to run after soft delete
  end

  def before_restore
    # Code to run before restore
  end

  def after_restore
    # Code to run after restore
  end
end
```

#### Notes
- Default field is `deleted_at`, can be changed with `soft_deletable_by :your_field`
- `touch: false` to skip updating updated_at when soft deleting/restoring
- Aliases for `deleted?`: `soft_deleted?`, `is_soft_deleted?`
- All scopes and methods work seamlessly with ActiveRecord

---

### 5. Hashable

Auto-generate a random value (hex, UUID, fixed-digit integer, or custom-alphabet string) on create.

```ruby
class Order < ApplicationRecord
  include ConcernsOnRails::Hashable

  # Defaults: type: :hex, length: 16 (32-char hex string)
  hashable_by :token
end

order = Order.create!
order.token              # => "a3f7c9b1e2d40859e2f1c9b73d40a857"
order.regenerate_token!  # rolls a new random value and persists it
```

#### Types

```ruby
hashable_by :token,       type: :hex,     length: 16
hashable_by :external_id, type: :uuid
hashable_by :code,        type: :integer, length: 6
hashable_by :code,        type: :custom,  length: 8,
            alphabet: "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
```

| Type       | `length` means          | Example output           |
|------------|-------------------------|--------------------------|
| `:hex`     | byte count (output is `length * 2` hex chars) | `"a3f7c9b1e2d40859"` |
| `:uuid`    | ignored                 | `"550e8400-e29b-41d4-a716-446655440000"` |
| `:integer` | digit count             | `483921`                 |
| `:custom`  | output length, samples from `alphabet:` | `"K7M3PQ9A"` |

#### Notes
- Auto-assigns on `before_create` only when the field is blank, so callers can still pass an explicit value.
- A `regenerate_<field>!` instance method is defined dynamically to match the configured column.
- No uniqueness retry is built in. For collision-prone configurations (e.g. short integer codes), add a unique index and rescue at the application level.
- For fixed-width numeric codes (e.g. `000042`), use a string column — integer columns drop leading zeros.
- If your model has `validates :<field>, presence: true`, switch to a `before_validation` callback in your model since the concern uses `before_create`.

---

## 🛠️ Development

To build the gem:

```sh
gem build concerns_on_rails.gemspec
```

To install locally:

```sh
gem install ./concerns_on_rails-1.0.0.gem
```

---

## 🤝 Contributing

Bug reports and pull requests are welcome!

---

## 📄 License

This project is licensed under the MIT License.

---

🇻🇳 **Hoàng Sa and Trường Sa belong to Việt Nam.**

---

### 🔗 Source Code

The source code is available on GitHub:

[👉 https://github.com/VSN2015/concerns_on_rails](https://github.com/VSN2015/concerns_on_rails)

Feel free to star ⭐️, fork 🍴, or contribute with issues and PRs.

