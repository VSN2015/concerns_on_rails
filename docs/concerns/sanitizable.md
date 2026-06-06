The `Sanitizable` concern provides opt-in HTML sanitization for ActiveRecord model attributes. It addresses the narrow but high-risk use case of columns whose values are rendered as trusted HTML (`raw` / `html_safe`) or that must remain strictly plain text. Because Rails already HTML-escapes normal `<%= %>` output via `SafeBuffer`, this concern is defense-in-depth rather than a general-purpose escaping layer; it should not be applied wholesale to every string column.

Two modes are available. The default, `on: :read`, is non-destructive: the raw value is stored unchanged and a `sanitized_<field>` reader returns the cleaned string on demand. The explicit opt-in `on: :write` mutates the column in a `before_validation` callback, permanently stripping tags before the record is saved.

The concern has no gem dependencies beyond `rails-html-sanitizer`, which already ships transitively with Action View in every standard Rails application.

## When to use it

- A `body` or `description` column is rendered with `raw` or `html_safe` and may contain user-submitted content.
- A `title` or `slug_source` column must be guaranteed free of HTML tags before indexing or display in a plain-text context (use `on: :write`).
- An API endpoint accepts rich-text input that must be stored as a safe subset of HTML (use `:safe_list` or a custom allow-list).
- A legacy column already contains raw HTML fragments and you need a read-time view that is safe to embed directly.
- You want to strip anchor tags from user bios or comments while preserving other formatting (`:no_links` preset).

## Installation

```ruby
class Article < ApplicationRecord
  include ConcernsOnRails::Sanitizable

  # Non-destructive default: sanitized_body returns a clean string;
  # the stored column is never touched.
  sanitizable :body, with: :safe_list

  # Multiple fields in one declaration share the same sanitizer and mode.
  sanitizable :summary, :excerpt, with: :strip

  # Custom allow-list via Hash.
  sanitizable :teaser, with: { tags: %w[b i a], attributes: %w[href] }

  # Destructive write — strips tags in before_validation, overwrites the column.
  # Only appropriate for plain-text-only columns.
  sanitizable :title, with: :strip, on: :write
end
```

The canonical namespaced path is `ConcernsOnRails::Models::Sanitizable`; the short `ConcernsOnRails::Sanitizable` form shown above is a backwards-compatibility alias for it. Both are equivalent, so either may be used in an `include`.

## Configuration

`Sanitizable` adds no database columns of its own. Every field passed to `sanitizable` must already exist in the schema as a `string` or `text` column (or any column type whose values you want sanitized — the concern enforces column existence at class-load time and raises `ArgumentError` if the column is absent).

### `sanitizable(*fields, with:, on:)`

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `fields` | One or more `Symbol`s (positional) | — (required) | The model attributes to sanitize. At least one field must be supplied. |
| `with:` | `Symbol`, `Array`, `Hash`, or `Proc` | `:strip` | The sanitizer to apply. See the Presets table below. |
| `on:` | `Symbol` (`:read` or `:write`) | `:read` | `:read` adds a non-destructive `sanitized_<field>` reader. `:write` mutates the column in `before_validation`. |

**`with:` presets and custom forms**

| Value | Behavior |
|-------|----------|
| `:strip` | Removes all HTML tags, keeping inner text. Uses `FullSanitizer`. Safe default for plain-text columns. |
| `:safe_list` | Keeps Rails' curated set of formatting tags (`em`, `strong`, `a`, `p`, etc.), drops `<script>`, `<iframe>`, and neutralizes `javascript:` URLs. Uses `SafeListSanitizer`. |
| `:no_links` | Strips only `<a>` tags, keeping their visible text and all other markup. Uses `LinkSanitizer`. |
| `:none` | No-op. Declares the field and (in `:read` mode) adds the `sanitized_<field>` reader without transforming the value. |
| `Array` (e.g. `%w[b i a]`) | Custom tag allow-list. Delegates to `SafeListSanitizer` restricted to the listed tags. |
| `Hash` (e.g. `{ tags: %w[a], attributes: %w[href] }`) | Custom tag and attribute allow-list. Only `:tags` and `:attributes` keys are accepted; any other key raises `ArgumentError`. Delegates to `SafeListSanitizer`. |
| `Proc` / `lambda` | Used as-is. The caller is responsible for handling non-String values. |

## Methods

### Instance methods

| Signature | Description |
|-----------|-------------|
| `sanitized_<field>` | Added for each field declared with `on: :read` (the default). Returns the sanitized string on demand without modifying the stored column. Returns `nil` when the column value is `nil`. Not defined for fields declared with `on: :write`. |
| `apply_sanitizations` | `before_validation` callback invoked automatically. Iterates `sanitizable_rules` and mutates only the fields declared with `on: :write`. `nil` values are skipped. Stored values are always plain `String`, never `SafeBuffer`. |

### Class methods

| Signature | Description |
|-----------|-------------|
| `sanitizable(*fields, with: :strip, on: :read)` | Configuration macro. Validates arguments, resolves the sanitizer, checks column existence, merges the rule into `sanitizable_rules`, and (for `:read` mode) defines `sanitized_<field>` readers. |

## Examples

**Non-destructive read-time sanitization**

```ruby
class Article < ApplicationRecord
  include ConcernsOnRails::Sanitizable

  sanitizable :body, with: :safe_list
end

article = Article.new(body: "<b>Hi</b><script>alert(1)</script>")

article.body           # => "<b>Hi</b><script>alert(1)</script>"  (stored raw)
article.sanitized_body # => "<b>Hi</b>alert(1)"                   (script dropped)
```

**Destructive write mode for a plain-text title column**

```ruby
class Post < ApplicationRecord
  include ConcernsOnRails::Sanitizable

  sanitizable :title, with: :strip, on: :write
  validates :title, presence: true
end

post = Post.new(title: "<script></script>")
post.valid?   # => false  (strips to "" before presence validation runs)
post.title    # => ""
```

**Custom allow-list with a Hash, and a Proc for fully custom logic**

```ruby
class Comment < ApplicationRecord
  include ConcernsOnRails::Sanitizable

  # Keep only <a> with href; silently drop onclick and other attributes.
  sanitizable :body, with: { tags: %w[a], attributes: %w[href] }

  # Proc: uppercase the code field for display without modifying the column.
  sanitizable :code_sample, with: ->(v) { v.to_s.upcase }
end

comment = Comment.new(
  body: %(<a href="/x" onclick="evil()">Link</a>),
  code_sample: "puts 'hello'"
)

comment.sanitized_body        # => '<a href="/x">Link</a>'
comment.sanitized_code_sample # => "PUTS 'HELLO'"
```

## Notes & gotchas

- **`on: :write` is lossy and irreversible.** Once a value is overwritten in `before_validation`, the original markup cannot be recovered from the database. Never use `:write` on Markdown, code, mathematical expressions, prices, or any field where `<` and `>` carry non-HTML meaning.
- **`on: :write` is bypassed by mass-update methods.** `update_column`, `update_all`, and raw SQL skip Active Record callbacks entirely, so `apply_sanitizations` never runs. Values written through those paths are stored exactly as supplied.
- **`on: :read` does not define `sanitized_<field>` for `:write` fields.** The two modes are mutually exclusive per field. Calling `sanitized_title` on a model where `:title` was declared `on: :write` raises `NoMethodError`.
- **Non-String values pass through untouched.** All built-in presets (`strip`, `safe_list`, `no_links`) check `v.is_a?(String)` and return the value unchanged for integers or other types. This means `sanitizable` can be called on a non-string column without raising, and the `sanitized_<field>` reader will return the raw value.
- **`nil` values are preserved.** In `:read` mode, `sanitized_<field>` returns `nil` when the column is `nil` (it does not return an empty string). In `:write` mode, `apply_sanitizations` skips `nil` values entirely.
- **Column existence is validated at class-load time.** If the column named in the `sanitizable` call does not exist in the schema, `ArgumentError` is raised with the message `"does not exist in the database"` when the class is first loaded (not at runtime). This catches typos early.
- **`sanitizable_rules` is a `class_attribute`.** Subclasses inherit their parent's rules, and a subclass can add further declarations without affecting the parent. If the same field is re-declared in a subclass with a different sanitizer, the subclass rule overwrites the inherited one for that field only.
- **The sanitizer instances are memoized and thread-safe.** `ConcernsOnRails::Support::HtmlSanitizers` lazily initializes one `FullSanitizer`, one `SafeListSanitizer`, and one `LinkSanitizer` and reuses them. The underlying `rails-html-sanitizer` objects are safe to call `#sanitize` on from multiple threads concurrently.
- **HTML5 vs HTML4 parser is auto-detected.** On platforms with `libgumbo` support (MRI + Rails 7.1+), the HTML5 parser (`Rails::HTML5::*`) is used, matching the output of Action View's own `sanitize` and `strip_tags` helpers. JRuby and older Rails fall back to the HTML4 (`Rails::HTML4::*`) implementation automatically.
- **`ArgumentError` is raised for invalid configuration** in several cases at class-load time: no fields supplied, an unrecognized `:on` value, an unknown preset symbol, an unsupported `:with` type (not a `Symbol`, `Array`, `Hash`, or `Proc`), or a `Hash` allow-list containing keys other than `:tags` and `:attributes`.
- **For full user-authored rich text, prefer Action Text.** `Sanitizable` is a lightweight layer for the specific case of columns rendered as trusted HTML. Action Text provides a richer storage, editing, and sanitization pipeline for document-level content.
