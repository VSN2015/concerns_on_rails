require "active_record"
require "sqlite3"
require "logger"

# Configure ActiveRecord to use an in-memory SQLite database
ActiveRecord::Base.establish_connection(
  adapter: "sqlite3",
  database: ":memory:"
)

# Optional: log SQL to STDOUT during test run
ActiveRecord::Base.logger = Logger.new(STDOUT)

# Base class for test models
class TestModel < ActiveRecord::Base
  self.abstract_class = true
end