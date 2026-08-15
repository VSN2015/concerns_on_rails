module ConcernsOnRails
  # Backwards-compatibility aliases for pre-1.6 module paths, resolved lazily:
  # eager `Sluggable = Models::Sluggable` assignments would force-load every
  # concern file at boot and defeat the loader's autoload laziness. The first
  # reference to `ConcernsOnRails::<Name>` loads the real module and pins the
  # alias constant, so `include ConcernsOnRails::Sluggable` works unchanged.
  # New code is encouraged to use the namespaced form:
  # `ConcernsOnRails::Models::Sluggable`.
  #
  # Note `Sortable` resolves to Models::Sortable (as it always has) — the
  # controller concern is only reachable as Controllers::Sortable.
  LEGACY_MODEL_ALIASES = %i[
    Sluggable Sortable Publishable SoftDeletable Hashable Schedulable
    Expirable Normalizable Searchable Activatable Tokenizable Stateable
    Addressable Sequenceable Taggable Sanitizable Maskable Monetizable
    Auditable Lockable Aliasable Storable CounterCacheable Encryptable
    Anonymizable Duplicable
  ].freeze

  def self.const_missing(name)
    return super unless LEGACY_MODEL_ALIASES.include?(name)

    # Idempotent under a concurrent first reference: both threads pin the
    # same module object, and once pinned const_missing never fires again.
    const_set(name, Models.const_get(name))
  end
end
