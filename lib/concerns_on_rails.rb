require "active_support/concern"
require "active_support/deprecation"
require "concerns_on_rails/version"

module ConcernsOnRails
  module Models; end
  module Controllers; end
  module Support; end

  # Guards the lazy singletons below: the first encrypted attribute read (or
  # deprecation warning) can happen on any request thread, and an unsynchronized
  # `@x ||=` lets two threads each build an instance — a `configure_encryption`
  # applied to one is then invisible to the other.
  @config_mutex = Mutex.new

  # Gem-wide deprecator backing `alias_association ..., deprecated:` (and any
  # future deprecation surface). A dedicated instance — not the global
  # ActiveSupport::Deprecation singleton, whose direct use is itself
  # deprecated on Rails 7.1+. Default behavior prints to $stderr; Rails apps
  # can re-route it (e.g. `config.active_support.deprecation` style):
  #
  #   ConcernsOnRails.deprecator.behavior = :log
  def self.deprecator
    @deprecator || @config_mutex.synchronize do
      @deprecator ||= ActiveSupport::Deprecation.new("2.0", "concerns_on_rails")
    end
  end

  # Gem-wide encryption configuration backing Models::Encryptable. Memoized like
  # `deprecator`; the host app supplies the key (see ConcernsOnRails::Encryption):
  #
  #   ConcernsOnRails.configure_encryption do |c|
  #     c.key = -> { Rails.application.credentials.dig(:encryption, :key) }
  #   end
  def self.encryption
    @encryption || @config_mutex.synchronize { @encryption ||= Encryption::Config.new }
  end

  def self.configure_encryption
    yield encryption if block_given?
    # Purge PBKDF2-derived keys built from the previous configuration; purely
    # memory hygiene (a changed key/salt is a different cache entry anyway).
    Support::Encryptor.reset_key_cache!
    encryption
  end

  # Live registry of sensitive field names (populated by Models::Encryptable)
  # consulted at filter time by the proc ConcernsOnRails::Railtie appends to
  # `config.filter_parameters`.
  def self.filter_parameter_registry
    @filter_parameter_registry || @config_mutex.synchronize do
      @filter_parameter_registry ||= Support::FilterParameterRegistry.new
    end
  end
end

# Encryption config + error types (loaded before the support codec that uses them)
require "concerns_on_rails/encryption"

# Shared internal helpers (must load before the concerns that use them)
require "concerns_on_rails/support/column_guard"
require "concerns_on_rails/support/scalar_param"
require "concerns_on_rails/support/unique_retry"
require "concerns_on_rails/support/error_envelope"
require "concerns_on_rails/support/filter_parameter_registry"
require "concerns_on_rails/support/random_value"
require "concerns_on_rails/support/address_data"
require "concerns_on_rails/support/sequence_calculator"
require "concerns_on_rails/support/html_sanitizers"
require "concerns_on_rails/support/masker"
require "concerns_on_rails/support/money"
require "concerns_on_rails/support/encryptor"

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
require "concerns_on_rails/models/encryptable"
require "concerns_on_rails/models/anonymizable"
require "concerns_on_rails/models/duplicable"

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

# Boot-time integration (filter_parameters registration), Rails apps only
require "concerns_on_rails/railtie" if defined?(Rails::Railtie)
