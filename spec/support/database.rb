require "active_record"
require "logger"

# Which database the suite runs against, chosen by the DB env var:
#
#   bundle exec rspec                 # sqlite3, in memory (the default)
#   DB=postgresql bundle exec rspec
#   DB=mysql2     bundle exec rspec
#
# SQLite stays the default so a plain checkout needs no services. CI also runs
# PostgreSQL and MySQL, because SQLite is the most PERMISSIVE of the three and
# a green SQLite run proves very little about the other two: it accepts
# SELECT DISTINCT ordered by a column outside the select list (which Postgres
# rejects outright), has no NULLS FIRST/LAST semantics to get wrong, folds
# LIKE differently, and has no native JSON operators. Every one of those has
# already produced a real bug in this gem.
#
# See gemfiles/ for the Rails-version half of the matrix.
module TestDatabase
  ADAPTERS = %w[sqlite3 postgresql mysql2].freeze
  # ActiveRecord adapter name => the driver gem to require.
  DRIVERS = { "sqlite3" => "sqlite3", "postgresql" => "pg", "mysql2" => "mysql2" }.freeze

  module_function

  def adapter
    @adapter ||= ENV.fetch("DB", "sqlite3").tap do |name|
      next if ADAPTERS.include?(name)

      raise ArgumentError, "unknown DB=#{name.inspect} (expected one of: #{ADAPTERS.join(', ')})"
    end
  end

  def config
    case adapter
    when "sqlite3"    then { adapter: "sqlite3", database: ":memory:" }
    when "postgresql" then postgresql_config
    when "mysql2"     then mysql2_config
    end
  end

  # Defaults match the service containers in .github/workflows/ci.yml, which
  # use trust / empty-password auth — so the password defaults are blank rather
  # than a literal. Point PGPASSWORD / MYSQL_PASSWORD at your own server when
  # running locally against one that wants credentials.
  def postgresql_config
    {
      adapter: "postgresql",
      database: ENV.fetch("PGDATABASE", "concerns_on_rails_test"),
      host: ENV.fetch("PGHOST", "127.0.0.1"),
      port: Integer(ENV.fetch("PGPORT", "5432")),
      username: ENV.fetch("PGUSER", "postgres"),
      password: ENV.fetch("PGPASSWORD", ""),
      encoding: "utf8"
    }
  end

  def mysql2_config
    {
      adapter: "mysql2",
      database: ENV.fetch("MYSQL_DATABASE", "concerns_on_rails_test"),
      host: ENV.fetch("MYSQL_HOST", "127.0.0.1"),
      port: Integer(ENV.fetch("MYSQL_PORT", "3306")),
      username: ENV.fetch("MYSQL_USER", "root"),
      password: ENV.fetch("MYSQL_PASSWORD", ""),
      encoding: "utf8mb4"
    }
  end

  def sqlite?
    adapter == "sqlite3"
  end

  def postgresql?
    adapter == "postgresql"
  end

  def mysql?
    adapter == "mysql2"
  end

  # Identifier quoting is per adapter — "posts"."title" on SQLite and
  # PostgreSQL, `posts`.`title` on MySQL — so an example that asserts on
  # generated SQL has to build its expected fragment from the connection
  # rather than hard-code one adapter's quote character. Dropping the quotes
  # instead would assert far less: a bare "title" matches the SELECT list too.
  def quoted_table(name)
    ActiveRecord::Base.connection.quote_table_name(name)
  end

  def quoted_column(name)
    ActiveRecord::Base.connection.quote_column_name(name)
  end

  # The qualified form — "posts"."title" / `posts`.`title`. Assembled from the
  # two halves rather than leaning on quote_table_name("posts.title")'s
  # dot-splitting, so the call site says which half is the table.
  def qualified(table, column)
    "#{quoted_table(table)}.#{quoted_column(column)}"
  end

  # Specs create their tables in a `before` and drop them in an `after`, but a
  # server-backed database survives the process — so a run interrupted midway
  # (or a spec that raised before its `after`) leaves tables behind that the
  # next run's `create_table force: true` may trip over. Harmless on SQLite,
  # where the whole database is thrown away with the process.
  def drop_leftover_tables!
    return if adapter == "sqlite3"

    connection = ActiveRecord::Base.connection
    connection.tables.each do |table|
      next if table == "schema_migrations"

      connection.drop_table(table, force: :cascade)
    end
  end
end

require TestDatabase::DRIVERS.fetch(TestDatabase.adapter)

ActiveRecord::Base.establish_connection(TestDatabase.config)

# Quiet by default under CI, where six matrix jobs each echoing every INSERT
# buries the actual failures; VERBOSE_SQL=1 restores the local firehose.
ActiveRecord::Base.logger =
  if ENV["CI"] && !ENV["VERBOSE_SQL"]
    Logger.new(File::NULL)
  else
    Logger.new($stdout)
  end

TestDatabase.drop_leftover_tables!

# Base class for test models
class TestModel < ActiveRecord::Base
  self.abstract_class = true

  # Most spec models are `Class.new(TestModel)` — anonymous. On Rails 6.0 the
  # first failing validation on such a class raises
  # `ArgumentError: Class name cannot be blank. You need to supply a name
  # argument when anonymous class given`, because ActiveModel::Name demands a
  # name to build the error message from (6.1+ tolerates it). Derive one from
  # the table the spec set, so an anonymous model behaves the same on every
  # line in the matrix.
  def self.model_name
    return super if name

    @model_name ||=
      ActiveModel::Name.new(self, nil, (table_name.presence || "TestModel").classify)
  end
end
