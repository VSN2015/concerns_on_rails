# Scope Affixing + Batch Operations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Publishable, SoftDeletable and Schedulable the `prefix:`/`suffix:` scope-name escape hatch the other scope-generating concerns already have, and extend the existing batch-operation contract to Publishable, Expirable, Activatable, Lockable and Stateable.

**Architecture:** Two new autoloaded support modules absorb duplication that already exists. `Support::Affix` computes affixed names, normalizes `prefix: true`, and owns the scope capture/retire machinery. `Support::BatchOps` owns the hook-ownership fast-path predicate and the transactional streaming loop. Every scope-generating concern gains a `<concern>_scope_names` class_attribute mapping base name => actual name, so scope bodies and batch verbs reference scopes through the map instead of hard-coded symbols.

**Tech Stack:** Ruby >= 3.2, ActiveRecord/ActiveSupport >= 5.0 < 9, RSpec, in-memory SQLite, RuboCop.

**Spec:** `docs/superpowers/specs/2026-08-29-affixing-and-batch-ops-design.md`

## Global Constraints

- Ruby floor `>= 3.2.0`; Rails component gems `>= 5.0, < 9`. No syntax or API newer than that floor.
- Run tests with `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec` — plain `bundle exec rspec` picks the wrong Ruby.
- **No new columns, migrations, dependencies or gemspec changes** in this release.
- **Fully backward compatible:** with no affix passed, every scope name, default scope and emitted query must be byte-identical to 1.26.0.
- Batch verbs take **no bang**. `anonymize_all!` keeps its existing name and is not renamed.
- Every concern's error messages are prefixed with its full label, e.g. `ConcernsOnRails::Models::Publishable: ...`.
- Never run `rubocop -A` on files containing lambda literals — its `lambda(&:sym)` autocorrection is broken and has produced invalid code in this repo before.
- Target version **1.27.0**. Do not tag or release; the final task only prepares the files.

---

### Task 1: `Support::Affix` — name and normalize

**Files:**
- Create: `lib/concerns_on_rails/support/affix.rb`
- Modify: `lib/concerns_on_rails.rb` (Support autoload block, after `:Encryptor`)
- Test: `spec/concerns/support/affix_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `ConcernsOnRails::Support::Affix.name(base, prefix: nil, suffix: nil) -> Symbol`
  - `ConcernsOnRails::Support::Affix.normalize(option, default:) -> String | nil`

- [ ] **Step 1: Write the failing test**

Create `spec/concerns/support/affix_spec.rb`:

```ruby
require "spec_helper"

describe ConcernsOnRails::Support::Affix do
  describe ".name" do
    it "returns the bare base as a Symbol when neither affix is given" do
      expect(described_class.name(:active)).to eq(:active)
    end

    it "prepends the prefix" do
      expect(described_class.name(:active, prefix: "subscription")).to eq(:subscription_active)
    end

    it "appends the suffix" do
      expect(described_class.name(:active, suffix: "window")).to eq(:active_window)
    end

    it "applies both" do
      expect(described_class.name(:active, prefix: "sub", suffix: "window")).to eq(:sub_active_window)
    end

    it "accepts a String base" do
      expect(described_class.name("active", prefix: "sub")).to eq(:sub_active)
    end
  end

  describe ".normalize" do
    it "returns nil for nil" do
      expect(described_class.normalize(nil, default: :status)).to be_nil
    end

    it "returns nil for false" do
      expect(described_class.normalize(false, default: :status)).to be_nil
    end

    it "returns the default as a String for true" do
      expect(described_class.normalize(true, default: :status)).to eq("status")
    end

    it "returns a Symbol option as a String" do
      expect(described_class.normalize(:archived, default: :status)).to eq("archived")
    end

    it "returns a String option unchanged" do
      expect(described_class.normalize("archived", default: :status)).to eq("archived")
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/support/affix_spec.rb`
Expected: FAIL — `uninitialized constant ConcernsOnRails::Support::Affix`

- [ ] **Step 3: Write minimal implementation**

Create `lib/concerns_on_rails/support/affix.rb`:

```ruby
module ConcernsOnRails
  module Support
    # Shared naming for concerns that generate affixable scopes or accessors.
    #
    # Two concerns that each define `.active` (SoftDeletable, Activatable,
    # Expirable) can coexist on one model only if their generated names can be
    # renamed, so every such concern takes `prefix:`/`suffix:` and routes the
    # name through here rather than re-implementing the join.
    module Affix
      module_function

      # `[prefix, base, suffix]`, underscore-joined, as a Symbol.
      def name(base, prefix: nil, suffix: nil)
        [prefix, base, suffix].compact.join("_").to_sym
      end

      # Normalize an affix option: `true` means "use the configured field
      # name" (Stateable's semantics, generalized to every affixing concern),
      # a String/Symbol is used literally, and nil/false means no affix.
      def normalize(option, default:)
        return nil unless option

        option == true ? default.to_s : option.to_s
      end
    end
  end
end
```

Add to the `module Support` autoload block in `lib/concerns_on_rails.rb`, immediately after the `:Encryptor` line:

```ruby
    autoload :Affix,                   "concerns_on_rails/support/affix"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/support/affix_spec.rb`
Expected: PASS (10 examples, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/concerns_on_rails/support/affix.rb lib/concerns_on_rails.rb spec/concerns/support/affix_spec.rb
git commit -m "Add Support::Affix — shared affixed-name computation"
```

---

### Task 2: `Support::Affix` — scope capture and retirement

This is the machinery that lets an affixed macro call remove the default-named scopes the concern defined at include time. It is the riskiest code in the plan; the three guards exist so it can never remove a name it did not create, a scope inherited from a parent, or a scope the model redefined itself.

**Files:**
- Modify: `lib/concerns_on_rails/support/affix.rb`
- Test: `spec/concerns/support/affix_spec.rb`

**Interfaces:**
- Consumes: `Affix.name` from Task 1.
- Produces:
  - `Affix.capture(klass, names) -> Hash{Symbol => UnboundMethod}`
  - `Affix.retire!(klass, captured, label:) -> Array<Symbol>` (the names actually removed; raises `ArgumentError` on the STI case)

- [ ] **Step 1: Write the failing test**

Append to `spec/concerns/support/affix_spec.rb`, inside the top-level `describe`:

```ruby
  describe ".capture and .retire!" do
    before do
      ActiveRecord::Schema.define do
        create_table :affix_posts, force: true do |t|
          t.datetime :published_at
        end
      end

      stub_const("AffixPost", Class.new(TestModel) do
        self.table_name = "affix_posts"
        scope :published, -> { where.not(published_at: nil) }
      end)
    end

    after(:each) do
      ActiveRecord::Base.connection.tables.each do |table|
        next if table == "schema_migrations"

        ActiveRecord::Base.connection.drop_table(table)
      end
    end

    it "captures the named scopes as UnboundMethods" do
      captured = described_class.capture(AffixPost, %i[published])
      expect(captured.keys).to eq([:published])
      expect(captured[:published]).to be_a(UnboundMethod)
    end

    it "ignores names that are not defined" do
      captured = described_class.capture(AffixPost, %i[published nope])
      expect(captured.keys).to eq([:published])
    end

    it "removes a captured scope that is untouched" do
      captured = described_class.capture(AffixPost, %i[published])
      removed = described_class.retire!(AffixPost, captured, label: "Test")

      expect(removed).to eq([:published])
      expect(AffixPost.respond_to?(:published)).to be false
    end

    it "leaves a scope the model redefined itself" do
      captured = described_class.capture(AffixPost, %i[published])
      AffixPost.singleton_class.send(:define_method, :published) { :mine }

      removed = described_class.retire!(AffixPost, captured, label: "Test")

      expect(removed).to be_empty
      expect(AffixPost.published).to eq(:mine)
    end

    it "raises when the scope is owned by a parent class" do
      captured = described_class.capture(AffixPost, %i[published])
      subclass = stub_const("AffixSpecialPost", Class.new(AffixPost))

      expect do
        described_class.retire!(subclass, captured, label: "ConcernsOnRails::Models::Publishable")
      end.to raise_error(ArgumentError, /AffixPost/)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/support/affix_spec.rb -e "capture and .retire!"`
Expected: FAIL — `undefined method 'capture' for ConcernsOnRails::Support::Affix`

- [ ] **Step 3: Write minimal implementation**

Add to `lib/concerns_on_rails/support/affix.rb`, inside `module Affix` after `normalize`:

```ruby
      # Snapshot the scopes a concern just defined on `klass`: a
      # name => UnboundMethod map, captured immediately after definition.
      # Names that aren't defined are skipped (a concern may generate a scope
      # only under some configurations).
      def capture(klass, names)
        singleton = klass.singleton_class
        names.each_with_object({}) do |base, acc|
          name = base.to_sym
          next unless singleton.method_defined?(name)

          acc[name] = singleton.instance_method(name)
        end
      end

      # Remove the default-named scopes recorded by `capture` so their affixed
      # replacements are the only ones left. Returns the names removed.
      #
      # Three guards, all of which must pass before a name is removed:
      #   1. it is in the captured map (never a name the concern did not create);
      #   2. it is owned by THIS class's own singleton (never inherited);
      #   3. it is still the exact method captured (never a model's override).
      #
      # Guard 2 failing means the concern was configured on a parent and the
      # affix is being declared on a subclass — retiring nothing would hand
      # back an escape hatch that doesn't work, because the parent's colliding
      # scopes would survive. That raises instead.
      def retire!(klass, captured, label:)
        singleton = klass.singleton_class
        captured.each_with_object([]) do |(name, recorded), removed|
          next unless singleton.method_defined?(name)

          current = singleton.instance_method(name)
          retire_guard_owner!(current, singleton, klass, name, label)
          next unless current == recorded

          singleton.send(:remove_method, name)
          removed << name
        end
      end

      # Postfix private: keeps the public module_function methods above
      # callable as `Affix.foo` while hiding the helper.
      def retire_guard_owner!(current, singleton, klass, name, label)
        return if current.owner == singleton

        owner = current.owner.attached_object
        raise ArgumentError,
              "#{label}: cannot affix scopes on #{klass} because '#{name}' is defined on #{owner}. " \
              "Declare the prefix:/suffix: option on #{owner} itself — affixing here would leave " \
              "#{owner}'s unaffixed scopes in place and the collision unresolved."
      end
      private_class_method :retire_guard_owner!
```

Note: `Module#attached_object` is Ruby 3.2+, which is this gem's floor.

- [ ] **Step 4: Run test to verify it passes**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/support/affix_spec.rb`
Expected: PASS (15 examples, 0 failures)

- [ ] **Step 5: Commit**

```bash
git add lib/concerns_on_rails/support/affix.rb spec/concerns/support/affix_spec.rb
git commit -m "Add Support::Affix scope capture + guarded retirement"
```

---

### Task 3: Route the existing affixing concerns through `Support::Affix`

Behaviour-preserving refactor of the six duplicated call sites, plus a `<concern>_scope_names` map on the three scope-generating ones so later tasks can reference their scopes by base name. The concerns' current specs are the regression guard — no new specs, and none of them may change.

**Files:**
- Modify: `lib/concerns_on_rails/models/activatable.rb`
- Modify: `lib/concerns_on_rails/models/expirable.rb`
- Modify: `lib/concerns_on_rails/models/lockable.rb`
- Modify: `lib/concerns_on_rails/models/anonymizable.rb`
- Modify: `lib/concerns_on_rails/models/stateable.rb`
- Modify: `lib/concerns_on_rails/models/storable.rb`
- Test: existing specs only

**Interfaces:**
- Consumes: `Affix.name`, `Affix.normalize`.
- Produces:
  - `activatable_scope_names -> {active: Symbol, inactive: Symbol}`
  - `expirable_scope_names -> {active:, expired:, expiring_within:}`
  - `lockable_scope_names -> {locked:, unlocked:}`

- [ ] **Step 1: Run the existing specs to establish the green baseline**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/models/activatable_spec.rb spec/concerns/models/expirable_spec.rb spec/concerns/models/lockable_spec.rb spec/concerns/models/anonymizable_spec.rb spec/concerns/models/stateable_spec.rb spec/concerns/models/storable_spec.rb`
Expected: PASS. Record the example count — it must not change by the end of this task.

- [ ] **Step 2: Refactor Activatable**

In `lib/concerns_on_rails/models/activatable.rb`, add the require and the map, and drop the private helper.

Add after the existing `require`:

```ruby
require "concerns_on_rails/support/affix"
```

In `included do`, add below the existing `class_attribute`:

```ruby
        class_attribute :activatable_scope_names, instance_accessor: false,
                                                  default: { active: :active, inactive: :inactive }.freeze
```

Replace the body of `activatable_by` and delete `activatable_scope_name`:

```ruby
        def activatable_by(field = DEFAULT_FIELD, prefix: nil, suffix: nil)
          self.activatable_field = field.to_sym
          ensure_columns!("ConcernsOnRails::Models::Activatable", activatable_field, types: :boolean)

          prefix = ConcernsOnRails::Support::Affix.normalize(prefix, default: activatable_field)
          suffix = ConcernsOnRails::Support::Affix.normalize(suffix, default: activatable_field)
          self.activatable_scope_names = {
            active: ConcernsOnRails::Support::Affix.name(:active, prefix: prefix, suffix: suffix),
            inactive: ConcernsOnRails::Support::Affix.name(:inactive, prefix: prefix, suffix: suffix)
          }.freeze

          # Affix the scope names so two concerns that each define `.active`
          # (e.g. SoftDeletable / Expirable) can coexist on one model.
          scope activatable_scope_names[:active],   -> { where(activatable_field => true) }
          scope activatable_scope_names[:inactive], -> { where(activatable_field => [false, nil]) }
        end
```

- [ ] **Step 3: Refactor Expirable**

In `lib/concerns_on_rails/models/expirable.rb`, add `require "concerns_on_rails/support/affix"`, add to `included do`:

```ruby
        class_attribute :expirable_scope_names, instance_accessor: false,
                                                default: { active: :active, expired: :expired,
                                                           expiring_within: :expiring_within }.freeze
```

Replace `define_expirable_scopes` and delete `expirable_scope_name`:

```ruby
        def define_expirable_scopes(prefix, suffix)
          prefix = ConcernsOnRails::Support::Affix.normalize(prefix, default: expirable_field)
          suffix = ConcernsOnRails::Support::Affix.normalize(suffix, default: expirable_field)
          self.expirable_scope_names = %i[active expired expiring_within].to_h do |base|
            [base, ConcernsOnRails::Support::Affix.name(base, prefix: prefix, suffix: suffix)]
          end.freeze

          scope expirable_scope_names[:active], lambda {
            column = arel_table[expirable_field]
            where(column.eq(nil).or(column.gt(Time.zone.now)))
          }
          scope expirable_scope_names[:expired], lambda {
            where(arel_table[expirable_field].lteq(Time.zone.now))
          }
          scope expirable_scope_names[:expiring_within], lambda { |duration|
            column = arel_table[expirable_field]
            now = Time.zone.now
            where(column.gt(now)).where(column.lteq(now + duration))
          }
        end
```

- [ ] **Step 4: Refactor Lockable**

In `lib/concerns_on_rails/models/lockable.rb`, add `require "concerns_on_rails/support/affix"`, add to `included do`:

```ruby
        class_attribute :lockable_scope_names, instance_accessor: false,
                                               default: { locked: :locked, unlocked: :unlocked }.freeze
```

At the top of `define_lockable_scopes`, replace the name computation and delete `lockable_scope_name`:

```ruby
        def define_lockable_scopes(prefix, suffix)
          prefix = ConcernsOnRails::Support::Affix.normalize(prefix, default: lockable_locked_at_field)
          suffix = ConcernsOnRails::Support::Affix.normalize(suffix, default: lockable_locked_at_field)
          self.lockable_scope_names = {
            locked: ConcernsOnRails::Support::Affix.name(:locked, prefix: prefix, suffix: suffix),
            unlocked: ConcernsOnRails::Support::Affix.name(:unlocked, prefix: prefix, suffix: suffix)
          }.freeze

          scope lockable_scope_names[:locked], lambda {
```

(the two scope bodies are unchanged; only the two name expressions change, and
`scope lockable_scope_name(:unlocked, prefix, suffix)` becomes
`scope lockable_scope_names[:unlocked]`)

- [ ] **Step 5: Refactor Anonymizable, Stateable and Storable**

`lib/concerns_on_rails/models/anonymizable.rb` — replace the `affixed` lambda in `anonymizable_define_scopes`:

```ruby
          prefix = ConcernsOnRails::Support::Affix.normalize(prefix, default: anonymizable_stamp)
          suffix = ConcernsOnRails::Support::Affix.normalize(suffix, default: anonymizable_stamp)
          scope ConcernsOnRails::Support::Affix.name(:anonymized, prefix: prefix, suffix: suffix),
                -> { where.not(anonymizable_stamp => nil) }
          scope ConcernsOnRails::Support::Affix.name(:not_anonymized, prefix: prefix, suffix: suffix),
                -> { where(anonymizable_stamp => nil) }
```

`lib/concerns_on_rails/models/stateable.rb` — delete `stateable_affix` and `stateable_method_name` bodies, delegating:

```ruby
        def stateable_affix(option)
          ConcernsOnRails::Support::Affix.normalize(option, default: stateable_field)
        end

        def stateable_method_name(base)
          ConcernsOnRails::Support::Affix.name(base, prefix: stateable_prefix, suffix: stateable_suffix).to_s
        end
```

Note `stateable_method_name` must keep returning a **String** — it is interpolated into `"#{name}?"` and `"#{name}!"`.

`lib/concerns_on_rails/models/storable.rb` — in `storable_normalize_spec`, replace the inline join:

```ruby
            accessor: ConcernsOnRails::Support::Affix.name(key, prefix: prefix, suffix: suffix) }
```

Add `require "concerns_on_rails/support/affix"` to anonymizable.rb, stateable.rb and storable.rb.

- [ ] **Step 6: Run the same specs and confirm an identical green result**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/models/activatable_spec.rb spec/concerns/models/expirable_spec.rb spec/concerns/models/lockable_spec.rb spec/concerns/models/anonymizable_spec.rb spec/concerns/models/stateable_spec.rb spec/concerns/models/storable_spec.rb`
Expected: PASS with the same example count as Step 1. Any change in count or a single failure means the refactor was not behaviour-preserving — fix before committing.

- [ ] **Step 7: Run the full suite**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec`
Expected: PASS, 1173 examples, 0 failures.

- [ ] **Step 8: Commit**

```bash
git add lib/concerns_on_rails/models/
git commit -m "Route the six existing affix call sites through Support::Affix"
```

---

### Task 4: Affix Publishable

**Files:**
- Modify: `lib/concerns_on_rails/models/publishable.rb`
- Test: `spec/concerns/models/publishable_spec.rb`

**Interfaces:**
- Consumes: `Affix.name`, `Affix.normalize`, `Affix.capture`, `Affix.retire!`.
- Produces: `publishable_scope_names -> {published:, unpublished:, scheduled:, draft:}`; `publishable_by(field = nil, default_scope: false, prefix: nil, suffix: nil)`.

- [ ] **Step 1: Write the failing test**

Append to `spec/concerns/models/publishable_spec.rb`:

```ruby
  describe "scope affixing" do
    before do
      ActiveRecord::Schema.define do
        create_table :affixed_articles, force: true do |t|
          t.datetime :published_at
        end
      end
    end

    it "keeps the default scope names when no affix is given" do
      klass = Class.new(TestModel) do
        self.table_name = "affixed_articles"
        include ConcernsOnRails::Publishable
        publishable_by
      end

      expect(klass).to respond_to(:published)
      expect(klass).to respond_to(:draft)
    end

    it "keeps the default scope names when the macro is never called" do
      klass = Class.new(TestModel) do
        self.table_name = "affixed_articles"
        include ConcernsOnRails::Publishable
      end

      expect(klass).to respond_to(:published)
    end

    it "defines affixed names and removes the defaults" do
      klass = Class.new(TestModel) do
        self.table_name = "affixed_articles"
        include ConcernsOnRails::Publishable
        publishable_by :published_at, prefix: :article
      end

      expect(klass).to respond_to(:article_published)
      expect(klass).to respond_to(:article_draft)
      expect(klass).not_to respond_to(:published)
      expect(klass).not_to respond_to(:draft)
    end

    it "accepts prefix: true, meaning the field name" do
      klass = Class.new(TestModel) do
        self.table_name = "affixed_articles"
        include ConcernsOnRails::Publishable
        publishable_by :published_at, prefix: true
      end

      expect(klass).to respond_to(:published_at_published)
    end

    it "returns the right rows through the affixed scopes" do
      klass = Class.new(TestModel) do
        self.table_name = "affixed_articles"
        include ConcernsOnRails::Publishable
        publishable_by :published_at, suffix: :posts
      end
      live = klass.create!(published_at: 1.day.ago)
      klass.create!(published_at: nil)

      expect(klass.published_posts.pluck(:id)).to eq([live.id])
      expect(klass.draft_posts.count).to eq(1)
    end

    it "keeps default_scope: true working under an affix" do
      klass = Class.new(TestModel) do
        self.table_name = "affixed_articles"
        include ConcernsOnRails::Publishable
        publishable_by :published_at, prefix: :article, default_scope: true
      end
      live = klass.create!(published_at: 1.day.ago)
      klass.create!(published_at: nil)

      expect(klass.all.pluck(:id)).to eq([live.id])
      expect(klass.article_draft.count).to eq(1)
    end

    it "raises when affixing on a subclass whose parent owns the scopes" do
      parent = Class.new(TestModel) do
        self.table_name = "affixed_articles"
        include ConcernsOnRails::Publishable
        publishable_by
      end
      stub_const("AffixedParentArticle", parent)

      expect do
        Class.new(parent) { publishable_by :published_at, prefix: :child }
      end.to raise_error(ArgumentError, /AffixedParentArticle/)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/models/publishable_spec.rb -e "scope affixing"`
Expected: FAIL — `unknown keyword: :prefix`

- [ ] **Step 3: Write minimal implementation**

In `lib/concerns_on_rails/models/publishable.rb`, add `require "concerns_on_rails/support/affix"`.

Replace the whole `included do` block with:

```ruby
      SCOPE_BASES = %i[published unpublished scheduled draft].freeze

      included do
        class_attribute :publishable_field, instance_accessor: false, default: :published_at
        class_attribute :publishable_scope_names, instance_accessor: false,
                                                  default: SCOPE_BASES.to_h { |b| [b, b] }.freeze
        class_attribute :publishable_captured_scopes, instance_accessor: false, default: {}.freeze

        define_publishable_scopes(nil, nil)
        self.publishable_captured_scopes =
          ConcernsOnRails::Support::Affix.capture(self, SCOPE_BASES).freeze
      end
```

In the `class_methods do` block, change the macro signature and add the scope builder. `publishable_by` becomes:

```ruby
        def publishable_by(field = nil, default_scope: false, prefix: nil, suffix: nil)
          self.publishable_field = field || :published_at
          @publishable_boolean_column = nil
          ensure_columns!("ConcernsOnRails::Models::Publishable", publishable_field, types: :datetime)

          if prefix || suffix
            define_publishable_scopes(prefix, suffix)
            ConcernsOnRails::Support::Affix.retire!(self, publishable_captured_scopes,
                                                    label: "ConcernsOnRails::Models::Publishable")
          end

          enable_published_default_scope if default_scope
        end
```

Add to the `private` section of `class_methods`, moving the four scope bodies verbatim out of `included do`:

```ruby
        # Scopes are built here rather than inline in `included do` so their
        # names can be affixed. `included do` calls this with no affix, so a
        # model that only includes the concern keeps the default names; an
        # affixed macro call rebuilds them under new names and retires the
        # originals.
        #
        # All scopes branch on the column type: a boolean publishable column
        # needs equality predicates, not the timestamp `<= now` / `> now`
        # comparisons that produce nonsensical SQL against a boolean.
        def define_publishable_scopes(prefix, suffix)
          prefix = ConcernsOnRails::Support::Affix.normalize(prefix, default: publishable_field)
          suffix = ConcernsOnRails::Support::Affix.normalize(suffix, default: publishable_field)
          self.publishable_scope_names = SCOPE_BASES.to_h do |base|
            [base, ConcernsOnRails::Support::Affix.name(base, prefix: prefix, suffix: suffix)]
          end.freeze

          scope publishable_scope_names[:published], lambda {
            if publishable_boolean_column?
              where(publishable_field => true)
            else
              where(arel_table[publishable_field].lteq(Time.zone.now))
            end
          }
          scope publishable_scope_names[:unpublished], lambda {
            if publishable_boolean_column?
              unscope(where: publishable_field).where(publishable_field => [nil, false])
            else
              column = arel_table[publishable_field]
              unscope(where: publishable_field).where(column.eq(nil).or(column.gt(Time.zone.now)))
            end
          }
          # Set, but the publish time is still in the future (timestamp columns only).
          scope publishable_scope_names[:scheduled], lambda {
            next none if publishable_boolean_column?

            unscope(where: publishable_field).where(arel_table[publishable_field].gt(Time.zone.now))
          }
          # Never published — a true draft.
          scope publishable_scope_names[:draft], lambda {
            if publishable_boolean_column?
              unscope(where: publishable_field).where(publishable_field => [nil, false])
            else
              unscope(where: publishable_field).where(publishable_field => nil)
            end
          }
        end
```

Change `enable_published_default_scope` so it does not hard-code the scope name:

```ruby
        def enable_published_default_scope
          published_scope = publishable_scope_names.fetch(:published)
          default_scope { public_send(published_scope) }
        end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/models/publishable_spec.rb`
Expected: PASS — the seven new examples plus every pre-existing Publishable example.

- [ ] **Step 5: Commit**

```bash
git add lib/concerns_on_rails/models/publishable.rb spec/concerns/models/publishable_spec.rb
git commit -m "Add prefix:/suffix: to Publishable"
```

---

### Task 5: Affix SoftDeletable

The riskiest affix: SoftDeletable's `default_scope` and two of its scopes call other scopes by name, and its `default_scope` is what hides deleted rows from `.all`. A missed reference means a model that silently stops filtering.

**Files:**
- Modify: `lib/concerns_on_rails/models/soft_deletable.rb`
- Test: `spec/concerns/models/soft_deletable_spec.rb`

**Interfaces:**
- Produces: `soft_delete_scope_names -> {active:, without_deleted:, soft_deleted:, only_deleted:, with_deleted:, deleted_within:}`; `soft_deletable_by(field = nil, touch: true, default_scope: true, prefix: nil, suffix: nil)`.

- [ ] **Step 1: Write the failing test**

Append to `spec/concerns/models/soft_deletable_spec.rb`:

```ruby
  describe "scope affixing" do
    before do
      ActiveRecord::Schema.define do
        create_table :affixed_docs, force: true do |t|
          t.string :name
          t.datetime :deleted_at
        end
      end
    end

    def affixed_class(**options)
      Class.new(TestModel) do
        self.table_name = "affixed_docs"
        include ConcernsOnRails::SoftDeletable
        soft_deletable_by :deleted_at, **options
      end
    end

    it "keeps the default names with no affix" do
      klass = affixed_class
      expect(klass).to respond_to(:without_deleted)
      expect(klass).to respond_to(:only_deleted)
    end

    it "defines affixed names and removes the defaults" do
      klass = affixed_class(prefix: :doc)

      expect(klass).to respond_to(:doc_without_deleted)
      expect(klass).to respond_to(:doc_soft_deleted)
      expect(klass).not_to respond_to(:without_deleted)
      expect(klass).not_to respond_to(:active)
    end

    it "keeps the default_scope filtering deleted rows under an affix" do
      klass = affixed_class(prefix: :doc)
      live = klass.create!(name: "live")
      gone = klass.create!(name: "gone")
      gone.soft_delete!

      expect(klass.all.pluck(:id)).to eq([live.id])
      expect(klass.doc_with_deleted.count).to eq(2)
      expect(klass.doc_soft_deleted.pluck(:id)).to eq([gone.id])
    end

    it "keeps only_deleted delegating to soft_deleted under an affix" do
      klass = affixed_class(prefix: :doc)
      gone = klass.create!(name: "gone")
      gone.soft_delete!

      expect(klass.doc_only_deleted.pluck(:id)).to eq([gone.id])
    end

    it "keeps deleted_within working under an affix" do
      klass = affixed_class(prefix: :doc)
      gone = klass.create!(name: "gone")
      gone.soft_delete!

      expect(klass.doc_deleted_within(1.day).pluck(:id)).to eq([gone.id])
      expect(klass.doc_deleted_within(0.seconds).count).to eq(0)
    end

    it "honours default_scope: false under an affix" do
      klass = affixed_class(prefix: :doc, default_scope: false)
      klass.create!(name: "live")
      klass.create!(name: "gone").soft_delete!

      expect(klass.all.count).to eq(2)
      expect(klass.doc_without_deleted.count).to eq(1)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/models/soft_deletable_spec.rb -e "scope affixing"`
Expected: FAIL — `unknown keyword: :prefix`

- [ ] **Step 3: Write minimal implementation**

In `lib/concerns_on_rails/models/soft_deletable.rb`, add `require "concerns_on_rails/support/affix"` and replace `included do` with:

```ruby
      SCOPE_BASES = %i[active without_deleted soft_deleted only_deleted with_deleted deleted_within].freeze

      included do
        # declare class attributes and set default values
        class_attribute :soft_delete_field, instance_accessor: false, default: :deleted_at
        class_attribute :soft_delete_touch, instance_accessor: false, default: true
        # Whether `.all` hides soft-deleted rows via a default_scope. ON by default for
        # backwards compatibility; opt out with `soft_deletable_by ..., default_scope: false`.
        # A default_scope is sticky and breaks unscoped joins / uniqueness validations /
        # eager-loading, so new models are encouraged to disable it and chain `.without_deleted`.
        class_attribute :soft_delete_default_scope, instance_accessor: false, default: true
        class_attribute :soft_delete_scope_names, instance_accessor: false,
                                                  default: SCOPE_BASES.to_h { |b| [b, b] }.freeze
        class_attribute :soft_delete_captured_scopes, instance_accessor: false, default: {}.freeze

        define_soft_delete_scopes(nil, nil)
        self.soft_delete_captured_scopes =
          ConcernsOnRails::Support::Affix.capture(self, SCOPE_BASES).freeze

        # Hide soft-deleted rows from `.all` only when enabled (the default). The block is
        # evaluated lazily, so toggling `soft_delete_default_scope` via the macro takes effect —
        # and it resolves the scope through the names map, so an affixed model still filters.
        default_scope do
          soft_delete_default_scope ? public_send(soft_delete_scope_names.fetch(:without_deleted)) : all
        end
      end
```

Add `prefix:`/`suffix:` to the macro:

```ruby
        def soft_deletable_by(field = nil, touch: true, default_scope: true, prefix: nil, suffix: nil)
          self.soft_delete_field = field || :deleted_at
          self.soft_delete_touch = touch
          self.soft_delete_default_scope = default_scope
          ensure_columns!("ConcernsOnRails::Models::SoftDeletable", soft_delete_field, types: :datetime)
          return unless prefix || suffix

          define_soft_delete_scopes(prefix, suffix)
          ConcernsOnRails::Support::Affix.retire!(self, soft_delete_captured_scopes,
                                                  label: "ConcernsOnRails::Models::SoftDeletable")
        end
```

Add to the private section of `ClassMethods`, with every inter-scope reference routed through the map:

```ruby
        # Built here rather than inline in `included do` so the names can be
        # affixed. Every scope that references another scope resolves it
        # through soft_delete_scope_names — a hard-coded symbol would break
        # the moment a model affixes.
        def define_soft_delete_scopes(prefix, suffix)
          prefix = ConcernsOnRails::Support::Affix.normalize(prefix, default: soft_delete_field)
          suffix = ConcernsOnRails::Support::Affix.normalize(suffix, default: soft_delete_field)
          self.soft_delete_scope_names = SCOPE_BASES.to_h do |base|
            [base, ConcernsOnRails::Support::Affix.name(base, prefix: prefix, suffix: suffix)]
          end.freeze

          soft_deleted_name = soft_delete_scope_names.fetch(:soft_deleted)

          scope soft_delete_scope_names[:active],
                -> { unscope(where: soft_delete_field).where(soft_delete_field => nil) }
          scope soft_delete_scope_names[:without_deleted],
                -> { unscope(where: soft_delete_field).where(soft_delete_field => nil) }
          scope soft_delete_scope_names[:soft_deleted],
                -> { unscope(where: soft_delete_field).where.not(soft_delete_field => nil) }
          scope soft_delete_scope_names[:only_deleted],
                -> { public_send(soft_deleted_name) }
          # `with_deleted` peels off the default scope so deleted + non-deleted are both returned.
          scope soft_delete_scope_names[:with_deleted],
                -> { unscope(where: soft_delete_field) }
          # Records soft-deleted within the last `duration` (e.g. `deleted_within(7.days)`).
          # Arel `gteq` rather than an endless range (`x..`): AR only translates an
          # endless range to `>=` on Rails 6.0+, but this gem supports Rails >= 5.0.
          # arel_table also qualifies the column with the table name, so the scope
          # stays unambiguous inside joins against tables sharing the column.
          scope soft_delete_scope_names[:deleted_within], lambda { |duration|
            public_send(soft_deleted_name).where(arel_table[soft_delete_field].gteq(duration.ago))
          }
        end
```

Then update the three batch/class methods that call the scopes by literal name — `restore_all` and `really_destroy_all` reference `soft_deleted`:

```ruby
        def really_destroy_all
          all.unscope(where: soft_delete_field).delete_all
        end
```
(unchanged — it uses `unscope`, not a scope name)

```ruby
        def restore_all
          deleted = all.public_send(soft_delete_scope_names.fetch(:soft_deleted))
          return deleted.update_all(soft_delete_field => nil) if soft_delete_batch_fast_path?(:restore)

          transaction do
            count = 0
            deleted.find_each do |record|
              record.restore! ||
                raise(ActiveRecord::RecordNotSaved.new(
                        "ConcernsOnRails::Models::SoftDeletable: failed to restore record", record
                      ))
              count += 1
            end
            count
          end
        end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/models/soft_deletable_spec.rb`
Expected: PASS — the six new examples plus every pre-existing SoftDeletable example.

- [ ] **Step 5: Run the full suite**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec`
Expected: PASS. SoftDeletable's default_scope interacts with Lockable and Anonymizable specs, so a regression shows up outside its own file.

- [ ] **Step 6: Commit**

```bash
git add lib/concerns_on_rails/models/soft_deletable.rb spec/concerns/models/soft_deletable_spec.rb
git commit -m "Add prefix:/suffix: to SoftDeletable"
```

---

### Task 6: Affix Schedulable

**Files:**
- Modify: `lib/concerns_on_rails/models/schedulable.rb`
- Test: `spec/concerns/models/schedulable_spec.rb`

**Interfaces:**
- Produces: `schedulable_scope_names -> {active_at:, current:, upcoming:, expired:}`; `schedulable_by(starts_at:, ends_at:, prefix: nil, suffix: nil)`.

- [ ] **Step 1: Write the failing test**

Append to `spec/concerns/models/schedulable_spec.rb`:

```ruby
  describe "scope affixing" do
    before do
      ActiveRecord::Schema.define do
        create_table :affixed_events, force: true do |t|
          t.datetime :starts_at
          t.datetime :ends_at
        end
      end
    end

    def affixed_class(**options)
      Class.new(TestModel) do
        self.table_name = "affixed_events"
        include ConcernsOnRails::Schedulable
        schedulable_by(**options)
      end
    end

    it "keeps the default names with no affix" do
      klass = affixed_class
      expect(klass).to respond_to(:current)
      expect(klass).to respond_to(:expired)
    end

    it "defines affixed names and removes the defaults" do
      klass = affixed_class(prefix: :event)

      expect(klass).to respond_to(:event_current)
      expect(klass).to respond_to(:event_active_at)
      expect(klass).not_to respond_to(:current)
      expect(klass).not_to respond_to(:expired)
    end

    it "keeps current delegating to active_at under an affix" do
      klass = affixed_class(prefix: :event)
      live = klass.create!(starts_at: 1.day.ago, ends_at: 1.day.from_now)
      klass.create!(starts_at: 1.day.from_now, ends_at: 2.days.from_now)

      expect(klass.event_current.pluck(:id)).to eq([live.id])
    end

    it "keeps upcoming and expired correct under an affix" do
      klass = affixed_class(suffix: :window)
      soon = klass.create!(starts_at: 1.day.from_now, ends_at: 2.days.from_now)
      over = klass.create!(starts_at: 3.days.ago, ends_at: 1.day.ago)

      expect(klass.upcoming_window.pluck(:id)).to eq([soon.id])
      expect(klass.expired_window.pluck(:id)).to eq([over.id])
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/models/schedulable_spec.rb -e "scope affixing"`
Expected: FAIL — `unknown keyword: :prefix`

- [ ] **Step 3: Write minimal implementation**

In `lib/concerns_on_rails/models/schedulable.rb`, add `require "concerns_on_rails/support/affix"` and replace `included do`:

```ruby
      SCOPE_BASES = %i[active_at current upcoming expired].freeze

      included do
        class_attribute :schedulable_starts_at_field, instance_accessor: false, default: DEFAULT_STARTS_AT_FIELD
        class_attribute :schedulable_ends_at_field, instance_accessor: false, default: DEFAULT_ENDS_AT_FIELD
        class_attribute :schedulable_scope_names, instance_accessor: false,
                                                  default: SCOPE_BASES.to_h { |b| [b, b] }.freeze
        class_attribute :schedulable_captured_scopes, instance_accessor: false, default: {}.freeze

        define_schedulable_scopes(nil, nil)
        self.schedulable_captured_scopes =
          ConcernsOnRails::Support::Affix.capture(self, SCOPE_BASES).freeze
      end
```

Add the keywords to the macro (keeping the existing body, with the affix block appended before the `ensure_columns!` return):

```ruby
        def schedulable_by(starts_at: DEFAULT_STARTS_AT_FIELD, ends_at: DEFAULT_ENDS_AT_FIELD,
                           prefix: nil, suffix: nil)
          self.schedulable_starts_at_field = starts_at&.to_sym
          self.schedulable_ends_at_field = ends_at&.to_sym

          if schedulable_starts_at_field.nil? && schedulable_ends_at_field.nil?
            raise ArgumentError, "ConcernsOnRails::Models::Schedulable: at least one of starts_at: or ends_at: must be configured"
          end

          ensure_columns!("ConcernsOnRails::Models::Schedulable",
                          schedulable_starts_at_field, schedulable_ends_at_field, types: :datetime)
          return unless prefix || suffix

          define_schedulable_scopes(prefix, suffix)
          ConcernsOnRails::Support::Affix.retire!(self, schedulable_captured_scopes,
                                                  label: "ConcernsOnRails::Models::Schedulable")
        end

        private

        # Built here rather than inline in `included do` so the names can be
        # affixed. `current` resolves `active_at` through the names map — a
        # literal call would break under an affix.
        def define_schedulable_scopes(prefix, suffix)
          default_field = schedulable_starts_at_field || schedulable_ends_at_field
          prefix = ConcernsOnRails::Support::Affix.normalize(prefix, default: default_field)
          suffix = ConcernsOnRails::Support::Affix.normalize(suffix, default: default_field)
          self.schedulable_scope_names = SCOPE_BASES.to_h do |base|
            [base, ConcernsOnRails::Support::Affix.name(base, prefix: prefix, suffix: suffix)]
          end.freeze

          active_at_name = schedulable_scope_names.fetch(:active_at)

          scope active_at_name, lambda { |time|
            starts_field = schedulable_starts_at_field
            ends_field = schedulable_ends_at_field
            relation = all
            relation = relation.where(arel_table[starts_field].lteq(time)) if starts_field
            relation = relation.where(arel_table[ends_field].eq(nil).or(arel_table[ends_field].gt(time))) if ends_field
            relation
          }

          scope schedulable_scope_names[:current], -> { public_send(active_at_name, Time.zone.now) }

          scope schedulable_scope_names[:upcoming], lambda {
            field = schedulable_starts_at_field
            next none unless field

            where(arel_table[field].gt(Time.zone.now))
          }

          scope schedulable_scope_names[:expired], lambda {
            field = schedulable_ends_at_field
            next none unless field

            where(arel_table[field].lteq(Time.zone.now))
          }
        end
```

Note: `class_methods do` already contains `include ConcernsOnRails::Support::ColumnGuard` — keep it at the top of the block, and place the new `private` section after `schedulable_by`.

- [ ] **Step 4: Run test to verify it passes**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/models/schedulable_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/concerns_on_rails/models/schedulable.rb spec/concerns/models/schedulable_spec.rb
git commit -m "Add prefix:/suffix: to Schedulable"
```

---

### Task 7: Collision integration spec

The scenario the whole affixing feature exists for. No production code changes.

**Files:**
- Create: `spec/concerns/integration/scope_collisions_spec.rb`

**Interfaces:**
- Consumes: affixed Publishable, SoftDeletable, Schedulable, plus Activatable and Expirable.

- [ ] **Step 1: Write the test**

```ruby
require "spec_helper"

# Three concerns each define a `.active` scope. Before 1.27 the last one
# included silently won and there was no way out on SoftDeletable's side.
describe "scope-name collisions across concerns" do
  before do
    ActiveRecord::Schema.define do
      create_table :memberships, force: true do |t|
        t.boolean :active
        t.datetime :expires_at
        t.datetime :deleted_at
      end
    end

    stub_const("Membership", Class.new(TestModel) do
      self.table_name = "memberships"

      include ConcernsOnRails::SoftDeletable
      include ConcernsOnRails::Activatable
      include ConcernsOnRails::Expirable

      soft_deletable_by :deleted_at, prefix: :trash, default_scope: false
      activatable_by :active, prefix: :flag
      expirable_by :expires_at, prefix: :term
    end)
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  it "gives each concern its own non-colliding scopes" do
    expect(Membership).to respond_to(:trash_without_deleted)
    expect(Membership).to respond_to(:flag_active)
    expect(Membership).to respond_to(:term_active)
    expect(Membership).not_to respond_to(:active)
  end

  it "returns the right rows from each affixed scope" do
    healthy = Membership.create!(active: true, expires_at: 1.day.from_now, deleted_at: nil)
    flagged_off = Membership.create!(active: false, expires_at: 1.day.from_now, deleted_at: nil)
    lapsed = Membership.create!(active: true, expires_at: 1.day.ago, deleted_at: nil)
    trashed = Membership.create!(active: true, expires_at: 1.day.from_now, deleted_at: Time.zone.now)

    expect(Membership.flag_active.pluck(:id)).to match_array([healthy.id, lapsed.id, trashed.id])
    expect(Membership.flag_inactive.pluck(:id)).to eq([flagged_off.id])
    expect(Membership.term_active.pluck(:id)).to match_array([healthy.id, flagged_off.id, trashed.id])
    expect(Membership.term_expired.pluck(:id)).to eq([lapsed.id])
    expect(Membership.trash_soft_deleted.pluck(:id)).to eq([trashed.id])
    expect(Membership.trash_without_deleted.pluck(:id)).to match_array([healthy.id, flagged_off.id, lapsed.id])
  end

  it "composes the three affixed scopes in one chain" do
    healthy = Membership.create!(active: true, expires_at: 1.day.from_now, deleted_at: nil)
    Membership.create!(active: true, expires_at: 1.day.ago, deleted_at: nil)

    result = Membership.trash_without_deleted.flag_active.term_active
    expect(result.pluck(:id)).to eq([healthy.id])
  end
end
```

- [ ] **Step 2: Run it**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/integration/scope_collisions_spec.rb`
Expected: PASS (3 examples). If `Membership.active` still responds, the retirement guards are rejecting a removal they should allow — debug `Affix.retire!` before continuing.

- [ ] **Step 3: Commit**

```bash
git add spec/concerns/integration/scope_collisions_spec.rb
git commit -m "Add integration spec proving affixed concerns coexist"
```

---

### Task 8: `Support::BatchOps` and the SoftDeletable refactor

**Files:**
- Create: `lib/concerns_on_rails/support/batch_ops.rb`
- Modify: `lib/concerns_on_rails.rb` (Support autoload block)
- Modify: `lib/concerns_on_rails/models/soft_deletable.rb`
- Test: `spec/concerns/support/batch_ops_spec.rb`

**Interfaces:**
- Produces:
  - `BatchOps.fast_path?(klass, owner, *methods) -> Boolean`
  - `BatchOps.run(relation, label:, message: "failed to update record") { |record| truthy | falsey | :skip } -> Integer`

- [ ] **Step 1: Write the failing test**

Create `spec/concerns/support/batch_ops_spec.rb`:

```ruby
require "spec_helper"

describe ConcernsOnRails::Support::BatchOps do
  before do
    ActiveRecord::Schema.define do
      create_table :batch_items, force: true do |t|
        t.string :state
      end
    end

    stub_const("BatchItem", Class.new(TestModel) do
      self.table_name = "batch_items"
    end)
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  describe ".fast_path?" do
    it "is true when no listed method is overridden" do
      owner = Module.new { def touched; end }
      klass = Class.new { include(owner) }

      expect(described_class.fast_path?(klass, owner, :touched)).to be true
    end

    it "is false when the host overrode a listed method" do
      owner = Module.new { def touched; end }
      klass = Class.new do
        include(owner)
        def touched; end
      end

      expect(described_class.fast_path?(klass, owner, :touched)).to be false
    end
  end

  describe ".run" do
    it "returns the count of records the block accepted" do
      3.times { BatchItem.create!(state: "new") }

      count = described_class.run(BatchItem.all, label: "Test") { |r| r.update(state: "done") }

      expect(count).to eq(3)
      expect(BatchItem.where(state: "done").count).to eq(3)
    end

    it "does not count records the block skips" do
      BatchItem.create!(state: "new")
      BatchItem.create!(state: "keep")

      count = described_class.run(BatchItem.all, label: "Test") do |r|
        r.state == "keep" ? :skip : r.update(state: "done")
      end

      expect(count).to eq(1)
    end

    it "raises RecordNotSaved and rolls the batch back when the block returns falsey" do
      BatchItem.create!(state: "a")
      BatchItem.create!(state: "b")

      expect do
        described_class.run(BatchItem.all, label: "Test") do |r|
          r.state == "b" ? false : r.update(state: "done")
        end
      end.to raise_error(ActiveRecord::RecordNotSaved, /Test: failed to update record/)

      expect(BatchItem.where(state: "done").count).to eq(0)
    end

    it "uses a custom message when given" do
      BatchItem.create!(state: "a")

      expect do
        described_class.run(BatchItem.all, label: "Test", message: "failed to soft-delete record") { false }
      end.to raise_error(ActiveRecord::RecordNotSaved, /failed to soft-delete record/)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/support/batch_ops_spec.rb`
Expected: FAIL — `uninitialized constant ConcernsOnRails::Support::BatchOps`

- [ ] **Step 3: Write minimal implementation**

Create `lib/concerns_on_rails/support/batch_ops.rb`:

```ruby
module ConcernsOnRails
  module Support
    # Shared machinery for the concerns' `*_all` batch verbs.
    #
    # Every batch verb follows the contract established by SoftDeletable in
    # 1.22: it operates on the current relation, returns an Integer count,
    # runs in a transaction, rolls the whole batch back when a record fails,
    # filters already-transitioned rows DB-side, and collapses to a single
    # UPDATE when the host model has overridden none of the concern's hooks
    # or bang methods.
    module BatchOps
      module_function

      # True when every named instance method is still the concern's own — the
      # host model overrode none of them, so a bulk UPDATE cannot differ from
      # looping the per-record path.
      def fast_path?(klass, owner, *methods)
        methods.all? { |name| klass.instance_method(name).owner == owner }
      end

      # The streaming slow path. `find_each` pages forward by primary key, so
      # rows leaving the filtered set as they're updated are never skipped or
      # revisited, and the relation is never materialized in full.
      #
      # The block returns truthy (counted), `:skip` (not counted, not an
      # error — a record that legitimately can't transition), or falsey
      # (raises and rolls the whole batch back).
      def run(relation, label:, message: "failed to update record")
        relation.klass.transaction do
          count = 0
          relation.find_each do |record|
            result = yield(record)
            next if result == :skip

            raise ActiveRecord::RecordNotSaved.new("#{label}: #{message}", record) unless result

            count += 1
          end
          count
        end
      end
    end
  end
end
```

Add to the `module Support` autoload block in `lib/concerns_on_rails.rb`, after `:Affix`:

```ruby
    autoload :BatchOps,                "concerns_on_rails/support/batch_ops"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/support/batch_ops_spec.rb`
Expected: PASS (6 examples).

- [ ] **Step 5: Refactor SoftDeletable onto it**

In `lib/concerns_on_rails/models/soft_deletable.rb`, add `require "concerns_on_rails/support/batch_ops"` and replace the two slow-path loops and the fast-path predicate:

```ruby
        def soft_delete_all
          pending = all.where(soft_delete_field => nil)
          return pending.update_all(soft_delete_field => Time.zone.now) if soft_delete_batch_fast_path?(:soft_delete)

          ConcernsOnRails::Support::BatchOps.run(
            pending,
            label: "ConcernsOnRails::Models::SoftDeletable",
            message: "failed to soft-delete record"
          ) { |record| record.soft_delete! }
        end
```

```ruby
        def restore_all
          deleted = all.public_send(soft_delete_scope_names.fetch(:soft_deleted))
          return deleted.update_all(soft_delete_field => nil) if soft_delete_batch_fast_path?(:restore)

          ConcernsOnRails::Support::BatchOps.run(
            deleted,
            label: "ConcernsOnRails::Models::SoftDeletable",
            message: "failed to restore record"
          ) { |record| record.restore! }
        end
```

```ruby
        def soft_delete_batch_fast_path?(kind)
          return false if soft_delete_touch

          methods = if kind == :restore
                      %i[before_restore after_restore restore!]
                    else
                      %i[before_soft_delete after_soft_delete soft_delete!]
                    end
          ConcernsOnRails::Support::BatchOps.fast_path?(self, ConcernsOnRails::Models::SoftDeletable, *methods)
        end
```

- [ ] **Step 6: Run the SoftDeletable specs**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/models/soft_deletable_spec.rb`
Expected: PASS with the same example count as before the refactor — including the existing `/failed to soft-delete/` assertion.

- [ ] **Step 7: Commit**

```bash
git add lib/concerns_on_rails/support/batch_ops.rb lib/concerns_on_rails.rb lib/concerns_on_rails/models/soft_deletable.rb spec/concerns/support/batch_ops_spec.rb
git commit -m "Add Support::BatchOps and route SoftDeletable through it"
```

---

### Task 9: Publishable batch operations

**Files:**
- Modify: `lib/concerns_on_rails/models/publishable.rb`
- Test: `spec/concerns/models/publishable_spec.rb`

**Interfaces:**
- Produces: `publish_all -> Integer`, `unpublish_all -> Integer`.

**Semantics:** `publish_all` writes `Time.zone.now` (or `true` on a boolean column) to rows that are not currently published — which **includes scheduled rows**, overwriting a future timestamp. Because batch verbs respect the relation, the narrow case is `Post.draft.publish_all`. `unpublish_all` writes `nil` on both column types, matching what `unpublish!` writes.

- [ ] **Step 1: Write the failing test**

Append to `spec/concerns/models/publishable_spec.rb`:

```ruby
  describe "batch operations" do
    before do
      ActiveRecord::Schema.define do
        create_table :batch_articles, force: true do |t|
          t.datetime :published_at
        end
      end

      stub_const("BatchArticle", Class.new(TestModel) do
        self.table_name = "batch_articles"
        include ConcernsOnRails::Publishable
        publishable_by
      end)
    end

    def capture_sql
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
        statements << args.last[:sql].to_s
      end
      yield
      statements
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "publishes every unpublished record and returns the count" do
      BatchArticle.create!(published_at: nil)
      BatchArticle.create!(published_at: nil)
      already = BatchArticle.create!(published_at: 2.days.ago)

      expect(BatchArticle.publish_all).to eq(2)
      expect(BatchArticle.where(published_at: nil).count).to eq(0)
      expect(already.reload.published_at).to be_within(1.second).of(2.days.ago)
    end

    it "is idempotent — a second call transitions nothing" do
      BatchArticle.create!(published_at: nil)
      BatchArticle.publish_all

      expect(BatchArticle.publish_all).to eq(0)
    end

    it "respects the relation" do
      keep = BatchArticle.create!(published_at: nil)
      BatchArticle.create!(published_at: nil)

      expect(BatchArticle.where.not(id: keep.id).publish_all).to eq(1)
      expect(keep.reload.published_at).to be_nil
    end

    it "issues exactly one UPDATE on the fast path" do
      2.times { BatchArticle.create!(published_at: nil) }

      statements = capture_sql { BatchArticle.publish_all }

      expect(statements.grep(/^UPDATE/).length).to eq(1)
    end

    it "unpublishes every published record" do
      BatchArticle.create!(published_at: 1.day.ago)
      BatchArticle.create!(published_at: nil)

      expect(BatchArticle.unpublish_all).to eq(1)
      expect(BatchArticle.where.not(published_at: nil).count).to eq(0)
    end

    it "runs the hooks once per record when they are overridden" do
      stub_const("HookedArticle", Class.new(TestModel) do
        self.table_name = "batch_articles"
        include ConcernsOnRails::Publishable
        publishable_by

        cattr_accessor :published_ids
        self.published_ids = []

        def after_publish
          self.class.published_ids << id
        end
      end)
      a = HookedArticle.create!(published_at: nil)
      b = HookedArticle.create!(published_at: nil)

      expect(HookedArticle.publish_all).to eq(2)
      expect(HookedArticle.published_ids).to match_array([a.id, b.id])
    end

    it "rolls the whole batch back when a record fails" do
      stub_const("FailingArticle", Class.new(TestModel) do
        self.table_name = "batch_articles"
        include ConcernsOnRails::Publishable
        publishable_by

        def publish!
          false
        end
      end)
      FailingArticle.create!(published_at: nil)

      expect { FailingArticle.publish_all }.to raise_error(ActiveRecord::RecordNotSaved)
      expect(FailingArticle.where(published_at: nil).count).to eq(1)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/models/publishable_spec.rb -e "batch operations"`
Expected: FAIL — `undefined method 'publish_all'`

- [ ] **Step 3: Write minimal implementation**

Add `require "concerns_on_rails/support/batch_ops"` to `lib/concerns_on_rails/models/publishable.rb`, and add these to the public part of `class_methods do` (above the existing `private`):

```ruby
        # Publish every not-currently-published record in the relation.
        # Returns the Integer count. NOTE this includes *scheduled* rows,
        # whose future timestamp is overwritten with now — chain the draft
        # scope (`Post.draft.publish_all`) when that isn't what you want.
        def publish_all
          pending = all.public_send(publishable_scope_names.fetch(:unpublished))
          value = publishable_boolean_column? ? true : Time.zone.now
          return pending.update_all(publishable_field => value) if publishable_batch_fast_path?(:publish)

          ConcernsOnRails::Support::BatchOps.run(
            pending,
            label: "ConcernsOnRails::Models::Publishable",
            message: "failed to publish record"
          ) { |record| record.publish! }
        end

        # Unpublish every published record in the relation. Writes nil on both
        # column types, exactly as `unpublish!` does.
        def unpublish_all
          live = all.public_send(publishable_scope_names.fetch(:published))
          return live.update_all(publishable_field => nil) if publishable_batch_fast_path?(:unpublish)

          ConcernsOnRails::Support::BatchOps.run(
            live,
            label: "ConcernsOnRails::Models::Publishable",
            message: "failed to unpublish record"
          ) { |record| record.unpublish! }
        end
```

And in the private section:

```ruby
        def publishable_batch_fast_path?(kind)
          methods = if kind == :publish
                      %i[before_publish after_publish publish!]
                    else
                      %i[before_unpublish after_unpublish unpublish!]
                    end
          ConcernsOnRails::Support::BatchOps.fast_path?(self, ConcernsOnRails::Models::Publishable, *methods)
        end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/models/publishable_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/concerns_on_rails/models/publishable.rb spec/concerns/models/publishable_spec.rb
git commit -m "Add Publishable#publish_all / #unpublish_all"
```

---

### Task 10: Expirable and Activatable batch operations

Both concerns define no lifecycle hooks, so the only thing that can force the slow path is a host model overriding the bang method. This refines the spec's "fast path: always" — an overridden `expire!` or `activate!` must still be honoured.

**Files:**
- Modify: `lib/concerns_on_rails/models/expirable.rb`
- Modify: `lib/concerns_on_rails/models/activatable.rb`
- Test: `spec/concerns/models/expirable_spec.rb`, `spec/concerns/models/activatable_spec.rb`

**Interfaces:**
- Produces: `expire_all(time = Time.zone.now) -> Integer`, `activate_all -> Integer`, `deactivate_all -> Integer`.

- [ ] **Step 1: Write the failing tests**

Append to `spec/concerns/models/expirable_spec.rb`:

```ruby
  describe "batch operations" do
    before do
      ActiveRecord::Schema.define do
        create_table :batch_tokens, force: true do |t|
          t.datetime :expires_at
        end
      end

      stub_const("BatchToken", Class.new(TestModel) do
        self.table_name = "batch_tokens"
        include ConcernsOnRails::Expirable
        expirable_by
      end)
    end

    it "expires every active record and returns the count" do
      BatchToken.create!(expires_at: 1.day.from_now)
      BatchToken.create!(expires_at: nil)
      done = BatchToken.create!(expires_at: 1.day.ago)

      expect(BatchToken.expire_all).to eq(2)
      expect(BatchToken.expired.count).to eq(3)
      expect(done.reload.expires_at).to be_within(1.second).of(1.day.ago)
    end

    it "is idempotent" do
      BatchToken.create!(expires_at: 1.day.from_now)
      BatchToken.expire_all

      expect(BatchToken.expire_all).to eq(0)
    end

    it "accepts an explicit time" do
      BatchToken.create!(expires_at: nil)
      at = 2.days.ago

      BatchToken.expire_all(at)

      expect(BatchToken.first.expires_at).to be_within(1.second).of(at)
    end

    it "uses the per-record path when expire! is overridden" do
      stub_const("CountingToken", Class.new(TestModel) do
        self.table_name = "batch_tokens"
        include ConcernsOnRails::Expirable
        expirable_by

        cattr_accessor :calls
        self.calls = 0

        def expire!(time = Time.zone.now)
          self.class.calls += 1
          super
        end
      end)
      2.times { CountingToken.create!(expires_at: nil) }

      expect(CountingToken.expire_all).to eq(2)
      expect(CountingToken.calls).to eq(2)
    end
  end
```

Append to `spec/concerns/models/activatable_spec.rb`:

```ruby
  describe "batch operations" do
    before do
      ActiveRecord::Schema.define do
        create_table :batch_flags, force: true do |t|
          t.boolean :active
        end
      end

      stub_const("BatchFlag", Class.new(TestModel) do
        self.table_name = "batch_flags"
        include ConcernsOnRails::Activatable
        activatable_by
      end)
    end

    it "activates every inactive record and returns the count" do
      BatchFlag.create!(active: false)
      BatchFlag.create!(active: nil)
      BatchFlag.create!(active: true)

      expect(BatchFlag.activate_all).to eq(2)
      expect(BatchFlag.active.count).to eq(3)
    end

    it "deactivates every active record" do
      BatchFlag.create!(active: true)
      BatchFlag.create!(active: false)

      expect(BatchFlag.deactivate_all).to eq(1)
      expect(BatchFlag.inactive.count).to eq(2)
    end

    it "is idempotent" do
      BatchFlag.create!(active: false)
      BatchFlag.activate_all

      expect(BatchFlag.activate_all).to eq(0)
    end

    it "respects the relation" do
      keep = BatchFlag.create!(active: false)
      BatchFlag.create!(active: false)

      expect(BatchFlag.where.not(id: keep.id).activate_all).to eq(1)
      expect(keep.reload.active).to be false
    end
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/models/expirable_spec.rb spec/concerns/models/activatable_spec.rb -e "batch operations"`
Expected: FAIL — `undefined method 'expire_all'` / `undefined method 'activate_all'`

- [ ] **Step 3: Write the Expirable implementation**

Add `require "concerns_on_rails/support/batch_ops"` to `lib/concerns_on_rails/models/expirable.rb` and add to the public part of `class_methods do` (above `private`):

```ruby
        # Expire every currently-active record in the relation. Returns the
        # Integer count. Expirable defines no lifecycle hooks, so this is a
        # single UPDATE unless the model overrode `expire!`.
        def expire_all(time = Time.zone.now)
          active = all.public_send(expirable_scope_names.fetch(:active))
          if ConcernsOnRails::Support::BatchOps.fast_path?(self, ConcernsOnRails::Models::Expirable, :expire!)
            return active.update_all(expirable_field => time)
          end

          ConcernsOnRails::Support::BatchOps.run(
            active,
            label: "ConcernsOnRails::Models::Expirable",
            message: "failed to expire record"
          ) { |record| record.expire!(time) }
        end
```

- [ ] **Step 4: Write the Activatable implementation**

Add `require "concerns_on_rails/support/batch_ops"` to `lib/concerns_on_rails/models/activatable.rb` and add to `class_methods do` (above `private`):

```ruby
        # Activate every inactive record in the relation; returns the count.
        def activate_all
          inactive = all.public_send(activatable_scope_names.fetch(:inactive))
          if ConcernsOnRails::Support::BatchOps.fast_path?(self, ConcernsOnRails::Models::Activatable, :activate!)
            return inactive.update_all(activatable_field => true)
          end

          ConcernsOnRails::Support::BatchOps.run(
            inactive,
            label: "ConcernsOnRails::Models::Activatable",
            message: "failed to activate record"
          ) { |record| record.activate! }
        end

        # Deactivate every active record in the relation; returns the count.
        def deactivate_all
          active = all.public_send(activatable_scope_names.fetch(:active))
          if ConcernsOnRails::Support::BatchOps.fast_path?(self, ConcernsOnRails::Models::Activatable, :deactivate!)
            return active.update_all(activatable_field => false)
          end

          ConcernsOnRails::Support::BatchOps.run(
            active,
            label: "ConcernsOnRails::Models::Activatable",
            message: "failed to deactivate record"
          ) { |record| record.deactivate! }
        end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/models/expirable_spec.rb spec/concerns/models/activatable_spec.rb`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/concerns_on_rails/models/expirable.rb lib/concerns_on_rails/models/activatable.rb spec/concerns/models/expirable_spec.rb spec/concerns/models/activatable_spec.rb
git commit -m "Add Expirable#expire_all and Activatable#activate_all / #deactivate_all"
```

---

### Task 11: Lockable `unlock_expired`

**Files:**
- Modify: `lib/concerns_on_rails/models/lockable.rb`
- Test: `spec/concerns/models/lockable_spec.rb`

**Interfaces:**
- Produces: `unlock_expired -> Integer`.

**Semantics:** targets rows whose `locked_at <= Time.zone.now - unlock_in` — the same inclusive boundary as `lock_expired?` and the `.locked`/`.unlocked` scopes. Clears `locked_at` **and** zeroes the attempts counter, mirroring `unlock_access!`. Returns `0` without querying when `unlock_in` is nil (manual-unlock-only models have nothing that expires).

- [ ] **Step 1: Write the failing test**

Append to `spec/concerns/models/lockable_spec.rb`:

```ruby
  describe "#unlock_expired" do
    before do
      ActiveRecord::Schema.define do
        create_table :batch_accounts, force: true do |t|
          t.integer :failed_attempts, default: 0
          t.datetime :locked_at
        end
      end
    end

    def lockable_class(**options)
      Class.new(TestModel) do
        self.table_name = "batch_accounts"
        include ConcernsOnRails::Lockable
        lockable_by(attempts: :failed_attempts, locked_at: :locked_at, **options)
      end
    end

    it "unlocks only the rows whose window has elapsed, and returns the count" do
      klass = lockable_class(unlock_in: 15.minutes)
      stale = klass.create!(failed_attempts: 5, locked_at: 1.hour.ago)
      fresh = klass.create!(failed_attempts: 5, locked_at: 1.minute.ago)
      never = klass.create!(failed_attempts: 2, locked_at: nil)

      expect(klass.unlock_expired).to eq(1)

      expect(stale.reload.locked_at).to be_nil
      expect(stale.failed_attempts).to eq(0)
      expect(fresh.reload.locked_at).not_to be_nil
      expect(fresh.failed_attempts).to eq(5)
      expect(never.reload.failed_attempts).to eq(2)
    end

    it "returns 0 when unlock_in is nil" do
      klass = lockable_class(unlock_in: nil)
      klass.create!(failed_attempts: 5, locked_at: 1.year.ago)

      expect(klass.unlock_expired).to eq(0)
      expect(klass.first.locked_at).not_to be_nil
    end

    it "is idempotent" do
      klass = lockable_class(unlock_in: 15.minutes)
      klass.create!(failed_attempts: 5, locked_at: 1.hour.ago)
      klass.unlock_expired

      expect(klass.unlock_expired).to eq(0)
    end

    it "fires the unlock hooks once per record when they are overridden" do
      klass = Class.new(TestModel) do
        self.table_name = "batch_accounts"
        include ConcernsOnRails::Lockable
        lockable_by attempts: :failed_attempts, locked_at: :locked_at, unlock_in: 15.minutes

        cattr_accessor :unlocked_ids
        self.unlocked_ids = []

        def after_unlock
          self.class.unlocked_ids << id
        end
      end
      stub_const("HookedAccount", klass)
      a = HookedAccount.create!(failed_attempts: 5, locked_at: 1.hour.ago)

      expect(HookedAccount.unlock_expired).to eq(1)
      expect(HookedAccount.unlocked_ids).to eq([a.id])
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/models/lockable_spec.rb -e "unlock_expired"`
Expected: FAIL — `undefined method 'unlock_expired'`

- [ ] **Step 3: Write minimal implementation**

Add `require "concerns_on_rails/support/batch_ops"` to `lib/concerns_on_rails/models/lockable.rb` and add to the public part of `module ClassMethods` (above `private`):

```ruby
        # Unlock every row whose lock window has fully elapsed, clearing
        # locked_at and zeroing the attempts counter exactly as
        # unlock_access! does. Returns the Integer count.
        #
        # Nothing expires when unlock_in is nil (manual unlock only), so that
        # case returns 0 without touching the database. The boundary instant
        # counts as expired, matching lock_expired? and the scopes.
        def unlock_expired
          unlock_in = lockable_unlock_in
          return 0 unless unlock_in

          locked_field = lockable_locked_at_field
          attempts_field = lockable_attempts_field
          # `lteq` on a NULL locked_at is NULL, so never-locked rows are
          # excluded without an extra predicate.
          expired = all.where(arel_table[locked_field].lteq(Time.zone.now - unlock_in))

          if ConcernsOnRails::Support::BatchOps.fast_path?(self, ConcernsOnRails::Models::Lockable,
                                                           :before_unlock, :after_unlock, :unlock_access!)
            return expired.update_all(locked_field => nil, attempts_field => 0)
          end

          ConcernsOnRails::Support::BatchOps.run(
            expired,
            label: LABEL,
            message: "failed to unlock record"
          ) { |record| record.unlock_access! }
        end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/models/lockable_spec.rb`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/concerns_on_rails/models/lockable.rb spec/concerns/models/lockable_spec.rb
git commit -m "Add Lockable#unlock_expired"
```

---

### Task 12: Stateable `transition_all`

**Files:**
- Modify: `lib/concerns_on_rails/models/stateable.rb`
- Test: `spec/concerns/models/stateable_spec.rb`

**Interfaces:**
- Produces: `transition_all(event) -> Integer`.

**Semantics — no fast path, ever.** The per-record path (`stateable_execute_transition!`) uses `update!`, which runs **validations**; every other concern's per-record path uses `update_column`/`update_columns`, which do not. Collapsing Stateable to `update_all` would therefore silently skip validations the single-record call runs. It always streams. Guard membership is still filtered DB-side (`where(field => from)`) so the query is cheap, and records that fail `may_<event>?` at call time are **skipped, not errors**.

- [ ] **Step 1: Write the failing test**

Append to `spec/concerns/models/stateable_spec.rb`:

```ruby
  describe "#transition_all" do
    before do
      ActiveRecord::Schema.define do
        create_table :batch_orders, force: true do |t|
          t.string :status
        end
      end

      stub_const("BatchOrder", Class.new(TestModel) do
        self.table_name = "batch_orders"
        include ConcernsOnRails::Stateable
        stateable_by :status,
                     states: %i[draft submitted approved],
                     default: :draft,
                     transitions: {
                       submit: { from: :draft, to: :submitted },
                       approve: { from: :submitted, to: :approved }
                     }
      end)
    end

    it "transitions every eligible record and returns the count" do
      BatchOrder.create!(status: "draft")
      BatchOrder.create!(status: "draft")
      other = BatchOrder.create!(status: "submitted")

      expect(BatchOrder.transition_all(:submit)).to eq(2)
      expect(BatchOrder.where(status: "submitted").count).to eq(3)
      expect(other.reload.status).to eq("submitted")
    end

    it "skips records the guard rejects rather than raising" do
      BatchOrder.create!(status: "draft")
      BatchOrder.create!(status: "approved")

      expect(BatchOrder.transition_all(:submit)).to eq(1)
    end

    it "is idempotent" do
      BatchOrder.create!(status: "draft")
      BatchOrder.transition_all(:submit)

      expect(BatchOrder.transition_all(:submit)).to eq(0)
    end

    it "respects the relation" do
      keep = BatchOrder.create!(status: "draft")
      BatchOrder.create!(status: "draft")

      expect(BatchOrder.where.not(id: keep.id).transition_all(:submit)).to eq(1)
      expect(keep.reload.status).to eq("draft")
    end

    it "fires the transition hooks once per record" do
      stub_const("HookedOrder", Class.new(TestModel) do
        self.table_name = "batch_orders"
        include ConcernsOnRails::Stateable
        stateable_by :status, states: %i[draft submitted],
                              transitions: { submit: { from: :draft, to: :submitted } }

        cattr_accessor :events
        self.events = []

        def after_transition(event, from, to)
          self.class.events << [event, from, to]
        end
      end)
      HookedOrder.create!(status: "draft")

      expect(HookedOrder.transition_all(:submit)).to eq(1)
      expect(HookedOrder.events).to eq([[:submit, "draft", "submitted"]])
    end

    it "raises on an unknown event" do
      expect { BatchOrder.transition_all(:nope) }
        .to raise_error(ArgumentError, /unknown transition 'nope'/)
    end

    it "honours affixed event names" do
      stub_const("AffixedOrder", Class.new(TestModel) do
        self.table_name = "batch_orders"
        include ConcernsOnRails::Stateable
        stateable_by :status, states: %i[draft submitted], prefix: :order,
                              transitions: { submit: { from: :draft, to: :submitted } }
      end)
      AffixedOrder.create!(status: "draft")

      expect(AffixedOrder.transition_all(:submit)).to eq(1)
      expect(AffixedOrder.where(status: "submitted").count).to eq(1)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/models/stateable_spec.rb -e "transition_all"`
Expected: FAIL — `undefined method 'transition_all'`

- [ ] **Step 3: Write minimal implementation**

Add `require "concerns_on_rails/support/batch_ops"` to `lib/concerns_on_rails/models/stateable.rb` and add to the public part of `module ClassMethods` (above `private`):

```ruby
        # Run one declared transition across the relation. Returns the Integer
        # count of records transitioned; records whose current state the
        # event's guard rejects are skipped, not errors.
        #
        # There is deliberately NO single-UPDATE fast path here: the
        # per-record path goes through `update!`, which runs validations,
        # while every fast path in this gem uses `update_all`, which does not.
        # Collapsing would silently skip validations that `<event>!` runs.
        # Guard membership is still filtered DB-side, so the scan is cheap.
        def transition_all(event)
          name = event.to_sym
          config = stateable_transitions[name] || stateable_transitions[event.to_s]
          raise ArgumentError, "#{LABEL}: unknown transition '#{event}'" unless config

          from = Array(config[:from]).map(&:to_s)
          to = config.fetch(:to).to_s
          field = stateable_field
          method_base = stateable_method_name(name)

          eligible = from.empty? ? all : all.where(field => from)
          eligible = eligible.where.not(field => to)

          ConcernsOnRails::Support::BatchOps.run(
            eligible,
            label: LABEL,
            message: "failed to transition record"
          ) do |record|
            record.public_send(:"may_#{method_base}?") ? record.public_send(:"#{method_base}!") : :skip
          end
        end
```

Note: `stateable_method_name` is private on `ClassMethods`; `transition_all` is in the same module, so the implicit-receiver call is legal.

- [ ] **Step 4: Run test to verify it passes**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec spec/concerns/models/stateable_spec.rb`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `ASDF_RUBY_VERSION=3.2.2 bundle exec rspec`
Expected: PASS, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add lib/concerns_on_rails/models/stateable.rb spec/concerns/models/stateable_spec.rb
git commit -m "Add Stateable#transition_all"
```

---

### Task 13: Documentation and 1.27.0 release preparation

Per the project release process every one of these files moves together — README omission is how Encryptable once shipped undocumented.

**Files:**
- Modify: `lib/concerns_on_rails/version.rb`
- Modify: `Gemfile.lock` (PATH pin, line 4)
- Modify: `CHANGELOG.md`
- Modify: `README.md`
- Modify: `docs/assets/js/concerns.js`

- [ ] **Step 1: Bump the version and the lockfile pin**

```bash
sed -i '' 's/VERSION = "1.26.0"/VERSION = "1.27.0"/' lib/concerns_on_rails/version.rb
sed -i '' 's/concerns_on_rails (1.26.0)/concerns_on_rails (1.27.0)/' Gemfile.lock
grep -n "1.27.0" lib/concerns_on_rails/version.rb Gemfile.lock
```

- [ ] **Step 2: Add the CHANGELOG entry**

Insert directly below the `<!-- CHANGELOG.md -->` line:

```markdown
## 1.27.0 (2026-08-29)

Scope-name collisions finally have an escape hatch on every concern that
generates scopes, and the 1.22 batch-operation contract reaches five more
concerns. No new columns, migrations or dependencies.

### Added
- **Models::Publishable / SoftDeletable / Schedulable**: `prefix:`/`suffix:` on
  `publishable_by` / `soft_deletable_by` / `schedulable_by` rename the generated
  scopes, so a model can include SoftDeletable (`.active`) alongside Activatable
  or Expirable (also `.active`) without one silently clobbering the other. With
  no affix passed the scope names, default scopes and emitted SQL are unchanged.
  `prefix: true` (use the configured field name), previously honoured only by
  Stateable, now works on every affixing concern.
- **Models::Publishable**: `publish_all` / `unpublish_all`. `publish_all` targets
  every not-currently-published row — *including scheduled ones*, whose future
  timestamp it overwrites; chain the draft scope (`Post.draft.publish_all`) to
  narrow it. Both respect the relation, return an Integer count, run in a
  transaction, and collapse to one UPDATE unless a hook or bang method is
  overridden.
- **Models::Expirable**: `expire_all(time = Time.zone.now)`.
- **Models::Activatable**: `activate_all` / `deactivate_all`.
- **Models::Lockable**: `unlock_expired` — clears `locked_at` and zeroes the
  attempts counter on every row whose `unlock_in` window has elapsed, mirroring
  `unlock_access!`. Returns 0 without querying when `unlock_in` is nil.
- **Models::Stateable**: `transition_all(event)` — runs one declared transition
  across the relation, skipping (not failing) records the guard rejects.
  Deliberately has no single-UPDATE fast path: the per-record path runs
  validations through `update!` and a bulk UPDATE would skip them.

### Internal
- New `Support::Affix` (affixed-name computation, `prefix: true` normalization,
  and the guarded scope capture/retirement used by the three newly affixable
  concerns) replaces six duplicated implementations across Activatable,
  Expirable, Lockable, Anonymizable, Stateable and Storable.
- New `Support::BatchOps` (hook-ownership fast-path predicate + the
  transactional `find_each` runner); SoftDeletable's `soft_delete_all` /
  `restore_all` now route through it, so the contract has one definition.
- Retiring a default-named scope is guarded three ways — the name must have been
  recorded by the concern, be owned by the class's own singleton, and still be
  the exact method captured — so a model's own override survives and a parent's
  scopes are never removed from a subclass (that case raises with a pointer to
  the parent).
```

- [ ] **Step 3: Update the README**

Three edits:

1. In each of the Publishable, SoftDeletable and Schedulable sections, add the new
   option to the options list: `prefix:` / `suffix:` — affix the generated scope
   names so they don't collide with another concern's; `true` means the
   configured field name.
2. In the Publishable, Expirable, Activatable, Lockable and Stateable sections,
   document the new batch verb with a one-line example, e.g.
   `Post.draft.publish_all   # => 12` and
   `Account.unlock_expired    # => 3`.
3. Add a short note where `prefix:` is first documented, distinguishing its three
   meanings: scope-name affix (Activatable, Expirable, Lockable, Stateable,
   Anonymizable, Publishable, SoftDeletable, Schedulable), accessor-name affix
   (Storable), and a literal string prepended to the generated value
   (Sequenceable). Searchable's `match: :prefix` is a LIKE mode, unrelated to
   either.

- [ ] **Step 4: Bump the docs-site version**

```bash
grep -n "1\.26\.0" docs/assets/js/concerns.js
```
Update the version string to `1.27.0`.

- [ ] **Step 5: Verify everything**

```bash
ASDF_RUBY_VERSION=3.2.2 bundle exec rspec
ASDF_RUBY_VERSION=3.2.2 bundle exec rubocop
```
Expected: RSpec 0 failures; RuboCop clean. If RuboCop flags offences, fix them by hand — do **not** run `rubocop -A` on files containing lambda literals.

- [ ] **Step 6: Commit**

```bash
git add lib/concerns_on_rails/version.rb Gemfile.lock CHANGELOG.md README.md docs/assets/js/concerns.js
git commit -m "Release 1.27.0: scope affixing + batch operations"
```

Do not tag or push — releasing is a separate, explicitly-authorized step.
