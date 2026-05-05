# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
# Run all tests
bundle exec rspec

# Run a single spec file
bundle exec rspec spec/concerns/publishable_spec.rb

# Run a single example by line number
bundle exec rspec spec/concerns/publishable_spec.rb:28

# Build the gem
gem build concerns_on_rails.gemspec

# Install locally
gem install ./concerns_on_rails-1.0.0.gem
```

## Architecture

This is a Ruby gem providing four `ActiveSupport::Concern` modules that Rails models include directly. There is no Rails app — tests use an in-memory SQLite database configured in `spec/support/database.rb`, with a `TestModel < ActiveRecord::Base` (abstract) as the base for all spec model classes.

Each concern lives in `lib/concerns_on_rails/<name>.rb` and follows the same pattern: `class_attribute` defaults set in `included do`, a `class_methods` block with a `<concern>_by` configuration macro, and instance methods. The `<concern>_by` macro validates that the configured column exists in the schema and raises `ArgumentError` if not.

### Concerns

- **`Sluggable`** — wraps `friendly_id` (`:slugged` strategy). Overrides `should_generate_new_friendly_id?` so slugs regenerate on field update. `slug_source` reads the configured `sluggable_field` class attribute.
- **`Sortable`** — wraps `acts_as_list`. Sets a `default_scope` ordering by the configured field/direction. `sortable_by` can take a symbol (`:position`) or hash (`position: :desc`). Pass `use_acts_as_list: false` to skip `acts_as_list` setup.
- **`Publishable`** — uses a timestamp field (default `published_at`). Scopes `.published`/`.unpublished` are added by `publishable_by` (not in `included`), so they're only available after the macro is called.
- **`SoftDeletable`** — uses a timestamp field (default `deleted_at`). Applies a `default_scope` hiding deleted records. Overrides `destroy_all` to soft-delete instead of hard-delete. `really_destroy_all` and `really_delete!` perform hard deletes. Supports `before_soft_delete`, `after_soft_delete`, `before_restore`, `after_restore` hooks via plain method overrides or `run_callbacks`.

### Test structure

Each spec file recreates tables in a `before` block using `ActiveRecord::Schema.define` and drops them in `after(:each)`. Test model classes are defined inline inside `before` blocks. SimpleCov tracks coverage, output to `coverage/`.

### Runtime dependencies

- `rails ~> 5.0`
- `acts_as_list ~> 0.7.5`
- `friendly_id ~> 5.4`
