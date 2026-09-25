require "active_support/concern"
require "concerns_on_rails/version"
# MissingDependency + the gem-level singletons (deprecator, config/setup,
# encryption, filter_parameter_registry)
require "concerns_on_rails/core"

module ConcernsOnRails
  # Everything below is autoloaded on first constant reference instead of
  # eagerly required: an app that uses two concerns loads two files (plus
  # their support helpers), not all forty — and friendly_id / acts_as_list
  # stay unloaded unless Sluggable / Sortable is actually included.
  # Each concern file requires the Support helpers it uses — and
  # concerns_on_rails/core when it touches a gem-level singleton — so a direct
  # `require "concerns_on_rails/models/sluggable"` keeps working too
  # (spec/concerns/direct_require_spec.rb loads every file that way).

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
    autoload :Permittable,       "concerns_on_rails/controllers/permittable"
  end

  module Support
    autoload :ColumnGuard,             "concerns_on_rails/support/column_guard"
    autoload :IncludeTree,             "concerns_on_rails/support/include_tree"
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
    autoload :Affix,                   "concerns_on_rails/support/affix"
    autoload :BatchOps,                "concerns_on_rails/support/batch_ops"
    autoload :HookedWrite,             "concerns_on_rails/support/hooked_write"
    autoload :LinkHeader,              "concerns_on_rails/support/link_header"
    autoload :VaryHeader,              "concerns_on_rails/support/vary_header"
    autoload :NumericOperand,          "concerns_on_rails/support/numeric_operand"
    autoload :SlugSources,             "concerns_on_rails/support/slug_sources"
  end
end

# Backwards compatibility (lazy top-level aliases for pre-1.6 module paths)
require "concerns_on_rails/legacy_aliases"

# Boot-time integration (filter_parameters registration), Rails apps only
require "concerns_on_rails/railtie" if defined?(Rails::Railtie)
