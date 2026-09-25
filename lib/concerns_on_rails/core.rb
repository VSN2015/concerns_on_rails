require "active_support/deprecation"

# The gem-level singletons every concern may reach for, kept apart from the
# autoload catalogue in lib/concerns_on_rails.rb. Each concern or support file
# that calls one of them requires this file itself, so a direct
# `require "concerns_on_rails/models/lockable"` (no top-level loader) still
# finds `ConcernsOnRails.filter_parameter_registry` — it used to raise
# NoMethodError there, or was swallowed and the sensitive field silently
# skipped log filtering.
module ConcernsOnRails
  # Raised (as a LoadError subclass, so a bare `rescue LoadError` still works)
  # when a concern needs a third-party gem that isn't available. friendly_id
  # and acts_as_list load lazily with the concern that uses them (Sluggable /
  # Sortable), so hosts that never touch those concerns never load them.
  class MissingDependency < LoadError; end

  # Encryption config + error types (Support::Encryptor requires it itself)
  autoload :Encryption, "concerns_on_rails/encryption"
  # Gem-wide configuration object behind ConcernsOnRails.setup
  autoload :Configuration, "concerns_on_rails/configuration"

  module Support
    autoload :FilterParameterRegistry, "concerns_on_rails/support/filter_parameter_registry"
    autoload :Encryptor,               "concerns_on_rails/support/encryptor"
  end

  # Guards the lazy singletons below: the first encrypted attribute read (or
  # deprecation warning) can happen on any request thread, and an unsynchronized
  # `@x ||=` lets two threads each build an instance — a `configure_encryption`
  # applied to one is then invisible to the other. `||=` so re-requiring this
  # file (a second path spelling) never swaps the mutex out from under a holder.
  @config_mutex ||= Mutex.new

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
