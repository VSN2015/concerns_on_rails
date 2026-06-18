require "active_support/concern"
require "active_support/deprecation"
require "concerns_on_rails/version"

module ConcernsOnRails
  module Models; end
  module Controllers; end
  module Support; end

  # Gem-wide deprecator backing `alias_association ..., deprecated:` (and any
  # future deprecation surface). A dedicated instance — not the global
  # ActiveSupport::Deprecation singleton, whose direct use is itself
  # deprecated on Rails 7.1+. Default behavior prints to $stderr; Rails apps
  # can re-route it (e.g. `config.active_support.deprecation` style):
  #
  #   ConcernsOnRails.deprecator.behavior = :log
  def self.deprecator
    @deprecator ||= ActiveSupport::Deprecation.new("2.0", "concerns_on_rails")
  end
end

# Shared internal helpers (must load before the concerns that use them)
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/random_value"
require "concerns_on_rails/support/address_data"
require "concerns_on_rails/support/sequence_calculator"
require "concerns_on_rails/support/html_sanitizers"
require "concerns_on_rails/support/masker"
require "concerns_on_rails/support/money"

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
require "concerns_on_rails/models/sequenceable"
require "concerns_on_rails/models/taggable"
require "concerns_on_rails/models/sanitizable"
require "concerns_on_rails/models/maskable"
require "concerns_on_rails/models/monetizable"
require "concerns_on_rails/models/auditable"
require "concerns_on_rails/models/lockable"
require "concerns_on_rails/models/aliasable"
require "concerns_on_rails/models/storable"
require "concerns_on_rails/models/counter_cacheable"

# Controller concerns
require "concerns_on_rails/controllers/paginatable"
require "concerns_on_rails/controllers/filterable"
require "concerns_on_rails/controllers/sortable"
require "concerns_on_rails/controllers/respondable"
require "concerns_on_rails/controllers/error_handleable"
require "concerns_on_rails/controllers/includable"
require "concerns_on_rails/controllers/secure_headable"
require "concerns_on_rails/controllers/localizable"
require "concerns_on_rails/controllers/authorizable"
require "concerns_on_rails/controllers/throttleable"
require "concerns_on_rails/controllers/timezoneable"
require "concerns_on_rails/controllers/idempotentable"
require "concerns_on_rails/controllers/webhook_verifiable"
require "concerns_on_rails/controllers/cursor_paginatable"
require "concerns_on_rails/controllers/deprecatable"
require "concerns_on_rails/controllers/cacheable"

# Backwards compatibility (top-level aliases for pre-1.6 module paths)
require "concerns_on_rails/legacy_aliases"
