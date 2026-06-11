module ConcernsOnRails
  # Backwards-compatibility aliases for pre-1.6 module paths.
  # Existing apps doing `include ConcernsOnRails::Sluggable` continue to work;
  # new code is encouraged to use the namespaced form: `ConcernsOnRails::Models::Sluggable`.
  Sluggable     = Models::Sluggable
  Sortable      = Models::Sortable
  Publishable   = Models::Publishable
  SoftDeletable = Models::SoftDeletable
  Hashable      = Models::Hashable
  Schedulable   = Models::Schedulable
  Expirable     = Models::Expirable
  Normalizable  = Models::Normalizable
  Searchable    = Models::Searchable
  Activatable   = Models::Activatable
  Tokenizable   = Models::Tokenizable
  Stateable     = Models::Stateable
  Addressable   = Models::Addressable
  Sequenceable  = Models::Sequenceable
  Taggable      = Models::Taggable
  Sanitizable   = Models::Sanitizable
  Maskable      = Models::Maskable
  Monetizable   = Models::Monetizable
  Auditable     = Models::Auditable
  Lockable      = Models::Lockable
  Aliasable     = Models::Aliasable
end
