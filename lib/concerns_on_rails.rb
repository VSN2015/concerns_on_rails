require "active_support/concern"
require "concerns_on_rails/version"

module ConcernsOnRails
  module Models; end
  module Controllers; end
end

# Model concerns
require "concerns_on_rails/models/sluggable"
require "concerns_on_rails/models/sortable"
require "concerns_on_rails/models/publishable"
require "concerns_on_rails/models/soft_deletable"
require "concerns_on_rails/models/hashable"
require "concerns_on_rails/models/schedulable"
require "concerns_on_rails/models/expirable"
require "concerns_on_rails/models/normalizable"

# Controller concerns
require "concerns_on_rails/controllers/paginatable"
require "concerns_on_rails/controllers/filterable"
require "concerns_on_rails/controllers/sortable"
require "concerns_on_rails/controllers/respondable"

# Backwards compatibility (top-level aliases for pre-1.6 module paths)
require "concerns_on_rails/legacy_aliases"
