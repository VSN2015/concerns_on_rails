require "active_support/concern"
require "active_support/deprecation"
require "concerns_on_rails/version"

module ConcernsOnRails
  # Raised (as a LoadError subclass, so a bare `rescue LoadError` still works)
  # when a concern needs a third-party gem that isn't available. friendly_id
  # and acts_as_list load lazily with the concern that uses them (Sluggable /
  # Sortable), so hosts that never touch those concerns never load them.
  class MissingDependency < LoadError; end

  # Everything below is autoloaded on first constant reference instead of
  # eagerly required: an app that uses two concerns loads two files (plus
  # their support helpers), not all forty — and friendly_id / acts_as_list
  # stay unloaded unless Sluggable / Sortable is actually included.
  # Each concern file requires the Support helpers it uses, so a direct
  # `require "concerns_on_rails/models/sluggable"` keeps working too.

  module Models
    autoload :Sluggable,        "concerns_on_rails/models/sluggable"
    autoload :Sortable,         "concerns_on_rails/models/sortable"
    autoload :Publishable,      "concerns_on_rails/models/publishable"
    autoload :SoftDeletable,    "concerns_on_rails/models/soft_deletable"
    autoload :Hashable,         "concerns_on_rails/models/hashable"
    autoload :Schedulable,      "concerns_on_rails/models/schedulable"
    autoload :Expirable,        "concerns_on_rails/models/expirable"
    autoload :Normalizable,     "concerns_on_rails/models/normalizable"
    autoload :Searchable,       "concerns_on_rails/models/searchable"
    autoload :Activatable,      "concerns_on_rails/models/activatable"
    autoload :Tokenizable,      "concerns_on_rails/models/tokenizable"
    autoload :Stateable,        "concerns_on_rails/models/stateable"
    autoload :Addressable,      "concerns_on_rails/models/addressable"
    autoload :Sequenceable,     "concerns_on_rails/models/sequenceable"
    autoload :Taggable,         "concerns_on_rails/models/taggable"
    autoload :Sanitizable,      "concerns_on_rails/models/sanitizable"
    autoload :Maskable,         "concerns_on_rails/models/maskable"
    autoload :Monetizable,      "concerns_on_rails/models/monetizable"
    autoload :Auditable,        "concerns_on_rails/models/auditable"
    autoload :Lockable,         "concerns_on_rails/models/lockable"
    autoload :Aliasable,        "concerns_on_rails/models/aliasable"
    autoload :Storable,         "concerns_on_rails/models/storable"
    autoload :CounterCacheable, "concerns_on_rails/models/counter_cacheable"
    autoload :Encryptable,      "concerns_on_rails/models/encryptable"
    autoload :Anonymizable,     "concerns_on_rails/models/anonymizable"
    autoload :Duplicable,       "concerns_on_rails/models/duplicable"
  end

  module Controllers
    autoload :Paginatable,       "concerns_on_rails/controllers/paginatable"
    autoload :Filterable,        "concerns_on_rails/controllers/filterable"
    autoload :Sortable,          "concerns_on_rails/controllers/sortable"
    autoload :Respondable,       "concerns_on_rails/controllers/respondable"
    autoload :ErrorHandleable,   "concerns_on_rails/controllers/error_handleable"
    autoload :Includable,        "concerns_on_rails/controllers/includable"
    autoload :SecureHeadable,    "concerns_on_rails/controllers/secure_headable"
    autoload :Localizable,       "concerns_on_rails/controllers/localizable"
    autoload :Authorizable,      "concerns_on_rails/controllers/authorizable"
    autoload :Throttleable,      "concerns_on_rails/controllers/throttleable"
    autoload :Timezoneable,      "concerns_on_rails/controllers/timezoneable"
    autoload :Idempotentable,    "concerns_on_rails/controllers/idempotentable"
    autoload :WebhookVerifiable, "concerns_on_rails/controllers/webhook_verifiable"
    autoload :CursorPaginatable, "concerns_on_rails/controllers/cursor_paginatable"
    autoload :Deprecatable,      "concerns_on_rails/controllers/deprecatable"
    autoload :Cacheable,         "concerns_on_rails/controllers/cacheable"
  end

  module Support
    autoload :ColumnGuard,             "concerns_on_rails/support/column_guard"
    autoload :ScalarParam,             "concerns_on_rails/support/scalar_param"
    autoload :UniqueRetry,             "concerns_on_rails/support/unique_retry"
    autoload :ErrorEnvelope,           "concerns_on_rails/support/error_envelope"
    autoload :FilterParameterRegistry, "concerns_on_rails/support/filter_parameter_registry"
    autoload :RandomValue,             "concerns_on_rails/support/random_value"
    autoload :AddressData,             "concerns_on_rails/support/address_data"
    autoload :SequenceCalculator,      "concerns_on_rails/support/sequence_calculator"
    autoload :HtmlSanitizers,          "concerns_on_rails/support/html_sanitizers"
    autoload :Masker,                  "concerns_on_rails/support/masker"
    autoload :Money,                   "concerns_on_rails/support/money"
    autoload :Encryptor,               "concerns_on_rails/support/encryptor"
  end

  # Encryption config + error types (Support::Encryptor requires it itself)
  autoload :Encryption, "concerns_on_rails/encryption"
  # Gem-wide configuration object behind ConcernsOnRails.setup
  autoload :Configuration, "concerns_on_rails/configuration"

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

  # Gem-wide configuration (see Configuration), set from an initializer:
  #
  #   ConcernsOnRails.setup do |config|
  #     config.cache_store = -> { Rails.cache }
  #   end
  def self.config
    @config || @config_mutex.synchronize { @config ||= Configuration.new }
  end

  def self.setup
    yield config if block_given?
    config
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

# Backwards compatibility (lazy top-level aliases for pre-1.6 module paths)
require "concerns_on_rails/legacy_aliases"

# Boot-time integration (filter_parameters registration), Rails apps only
require "concerns_on_rails/railtie" if defined?(Rails::Railtie)
