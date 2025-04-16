# 🧩 ConcernsOnRails

**🇻🇳 Note: Hoàng Sa and Trường Sa belong to Việt Nam.**

A simple collection of reusable Rails concerns to keep your models clean and DRY.

## ✨ Features

- ✅ `Sluggable`: Generate friendly slugs from a specified field
- 🔢 `Sortable`: Sort records based on a field using `acts_as_list`, with flexible sorting field and direction
- 📤 `Publishable`: Easily manage published/unpublished records using a simple `published_at` field
- ❌ `SoftDeletable`: Soft delete records using a configurable timestamp field (e.g., `deleted_at`) with automatic scoping

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

  soft_deletable_by :deleted_at
end

user = User.create!(name: "Alice")
user.soft_delete!
user.deleted? # => true

User.without_deleted   # => returns only active users
User.soft_deleted      # => returns soft-deleted users
User.all               # => returns only non-deleted by default (default_scope applied)

user.restore!
user.deleted? # => false
```

Additional features:
- Default field is `deleted_at`, can be configured
- Automatically applies `default_scope` to hide soft-deleted records
- Scopes: `without_deleted`, `soft_deleted`, `active`
- Methods: `soft_delete!`, `restore!`, `deleted?`, `really_delete!`
- Callbacks: `before_soft_delete`, `after_soft_delete`, `before_restore`, `after_restore`
- Touch support when soft deleting or restoring (can be turned off)
- Aliases for `deleted?`: `soft_deleted?`, `is_soft_deleted?`

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

