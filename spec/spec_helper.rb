require "bundler/setup"
require "active_record"
require "concerns_on_rails"
require "faker"
require "simplecov"
require "support/database"
require "support/controller_test_harness"
require "active_support/core_ext/time"
require "active_support/core_ext/numeric/time"
require "active_support/testing/time_helpers"

Time.zone = "UTC"

SimpleCov.start do
  add_filter "/spec/"
end

# Rails <= 6.1 resolves `class_name:` through ActiveSupport::Dependencies,
# whose Reference store memoises the constant it resolved. `stub_const` swaps
# the constant underneath that cache, so an association declared with
# `class_name: "CascComment"` keeps handing back the ORIGINAL class and a
# stubbed-in subclass never takes effect. Prepended (not included) so this
# runs before RSpec::Mocks' own definition and can call it through `super`.
module StubConstClearsDependencyCache
  def stub_const(*, **, &)
    super.tap do
      ActiveSupport::Dependencies::Reference.clear! if defined?(ActiveSupport::Dependencies::Reference)
    end
  end
end

RSpec.configure do |config|
  config.prepend StubConstClearsDependencyCache

  config.include ActiveSupport::Testing::TimeHelpers

  # Every spec drops and recreates its tables in a `before`, and neighbouring
  # files reuse the same table names (`posts`, `users`, `widgets`) with
  # DIFFERENT columns. Rails 6.1 added the `schema_cache.clear_data_source_cache!`
  # call that `create_table` makes on 6.1+; on 6.0 the connection happily serves
  # the PREVIOUS file's column list, so a model defined against the new table
  # sees the old one's columns — `unknown attribute 'name' for Widget`, or a
  # ColumnGuard ArgumentError for columns that are demonstrably there. Clearing
  # here (before each example, hence before that example's own table creation)
  # makes every line read the schema it just wrote.
  config.before do
    ActiveRecord::Base.connection.schema_cache.clear!

    # Rails <= 6.1 resolves a model's `class_name` through
    # ActiveSupport::Dependencies, whose Reference store MEMOISES the constant
    # it resolved. These specs remove their model constants in an `after` and
    # redefine them in the next `before`, so without this the second example
    # gets the FIRST example's discarded class back: `book.writer` returns an
    # Author that is `==`-unequal to an identical Author, because
    # `instance_of?(self.class)` compares two same-named class objects. The
    # store is gone on Rails 7+ (zeitwerk only), hence the guard.
    ActiveSupport::Dependencies::Reference.clear! if defined?(ActiveSupport::Dependencies::Reference)
  end

  # Version gate for examples whose FEATURE is gated in lib/ — not a licence to
  # hide a bug. Tag an example, context or describe with `min_rails: "6.1"` and
  # it is skipped on older lines. Sortable's `nulls:` is the reason it exists:
  # the macro itself raises below 6.1, because Arel gained ordering nodes with
  # NULLS FIRST/LAST support there.
  running_rails = Gem::Version.new(ActiveRecord::VERSION::STRING)
  config.filter_run_excluding(min_rails: ->(version) { running_rails < Gem::Version.new(version) })

  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
end
