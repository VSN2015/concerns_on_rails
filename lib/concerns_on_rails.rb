require "active_support/concern"
require "concerns_on_rails/version"

module ConcernsOnRails
  module Models; end
  module Controllers; end
  module Support; end
end

# Shared internal helpers (must load before the concerns that use them)
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/random_value"
require "concerns_on_rails/support/address_data"

# Model concerns
require "concerns_on_rails/models/sluggable"
require "concerns_on_rails/models/sortable"
require "concerns_on_rails/models/publishable"
require "concerns_on_rails/models/soft_deletable"
require "concerns_on_rails/models/hashable"
require "concerns_on_rails/models/schedulable"
require "concerns_on_rails/models/expirable"
require "concerns_on_rails/models/normalizable"
require "concerns_on_rails/models/searchable"
require "concerns_on_rails/models/activatable"
require "concerns_on_rails/models/tokenizable"
require "concerns_on_rails/models/stateable"
require "concerns_on_rails/models/addressable"

# Controller concerns
require "concerns_on_rails/controllers/paginatable"
require "concerns_on_rails/controllers/filterable"
require "concerns_on_rails/controllers/sortable"
require "concerns_on_rails/controllers/respondable"
require "concerns_on_rails/controllers/error_handleable"
require "concerns_on_rails/controllers/includable"

# Backwards compatibility (top-level aliases for pre-1.6 module paths)
require "concerns_on_rails/legacy_aliases"
