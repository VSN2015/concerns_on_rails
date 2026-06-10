require "spec_helper"

describe "Legacy top-level concern aliases (pre-1.6 paths)" do
  {
    "Sluggable" => "Models::Sluggable",
    "Sortable" => "Models::Sortable",
    "Publishable" => "Models::Publishable",
    "SoftDeletable" => "Models::SoftDeletable",
    "Hashable" => "Models::Hashable",
    "Schedulable" => "Models::Schedulable",
    "Expirable" => "Models::Expirable",
    "Normalizable" => "Models::Normalizable",
    "Searchable" => "Models::Searchable",
    "Activatable" => "Models::Activatable",
    "Sanitizable" => "Models::Sanitizable",
    "Maskable" => "Models::Maskable",
    "Monetizable" => "Models::Monetizable",
    "Auditable" => "Models::Auditable",
    "Lockable" => "Models::Lockable"
  }.each do |legacy, canonical|
    it "ConcernsOnRails::#{legacy} is the same module as ConcernsOnRails::#{canonical}" do
      legacy_mod    = ConcernsOnRails.const_get(legacy)
      canonical_mod = canonical.split("::").inject(ConcernsOnRails) { |ns, name| ns.const_get(name) }

      expect(legacy_mod).to equal(canonical_mod)
    end
  end
end
