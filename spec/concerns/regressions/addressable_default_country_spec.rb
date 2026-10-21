require "spec_helper"

# Audit 2026-10-10, TRANS-4. `default_country:` was only upcased, never
# canonicalized or checked, and resolved_country returned it verbatim for a
# blank country. "Canada" / "USA" (or a typo) therefore made every
# blank-country record an "unknown" country: permissive postal rules, no
# state check, no CA postal spacing, and a fingerprint that differed from the
# same address with the country spelled out.
describe ConcernsOnRails::Models::Addressable do
  before do
    ActiveRecord::Schema.define do
      create_table :default_country_locations, force: true do |t|
        t.string :line1
        t.string :city
        t.string :state
        t.string :postal_code
        t.string :country
        t.string :fp
      end
    end
  end

  after do
    ActiveRecord::Base.connection.drop_table(:default_country_locations, if_exists: true)
  end

  def location_class(**options)
    Class.new(TestModel) do
      self.table_name = "default_country_locations"
      include ConcernsOnRails::Models::Addressable

      addressable_by(required: %i[line1], **options)
    end
  end

  it "canonicalizes a country name, so it drives postal formatting and the fingerprint" do
    klass = location_class(default_country: "Canada", normalize_country: true, fingerprint: :fp)

    implicit = klass.create!(line1: "1 Main St", city: "Ottawa", postal_code: "k1a0b1")
    explicit = klass.create!(line1: "1 Main St", city: "Ottawa", postal_code: "k1a0b1", country: "CA")

    expect(klass.addressable_default_country).to eq("CA")
    expect(implicit.postal_code).to eq("K1A 0B1")
    expect(implicit.same_address_as?(explicit)).to be(true)
    expect(implicit.fp).to eq(explicit.fp)
    expect(klass.with_address(explicit).count).to eq(2)
  end

  it "canonicalizes an alpha-3 code, so a blank country gets that country's rules" do
    klass = location_class(default_country: "USA", validate_state: true)

    expect(klass.addressable_default_country).to eq("US")
    expect(klass.new(line1: "1 Main St", postal_code: "ABC").valid?).to be(false)
    expect(klass.new(line1: "1 Main St", state: "ZZ").valid?).to be(false)
    expect(klass.new(line1: "1 Main St", postal_code: "94105", state: "CA").valid?).to be(true)
  end

  it "canonicalizes whether or not normalize_country: is on" do
    expect(location_class(default_country: "Canada").addressable_default_country).to eq("CA")
    expect(location_class(default_country: " gb ").addressable_default_country).to eq("GB")
    expect(location_class(default_country: :de).addressable_default_country).to eq("DE")
  end

  it "raises at the macro for a default_country that is no country" do
    ["Narnia", "XX", "U.S.A.!"].each do |bad|
      expect { location_class(default_country: bad) }
        .to raise_error(ArgumentError, /default_country must be an ISO 3166-1 alpha-2 code/), bad.inspect
    end
  end

  it "leaves the class configuration untouched when the default_country is refused" do
    klass = location_class(default_country: "GB")

    expect { klass.addressable_by(required: %i[line1 city], default_country: "Narnia") }.to raise_error(ArgumentError)
    expect(klass.addressable_default_country).to eq("GB")
    expect(klass.addressable_required).to eq(%i[line1])
  end

  it "treats a nil default_country as none: a blank country gets the permissive rules" do
    klass = location_class(default_country: nil)

    expect(klass.addressable_default_country).to be_nil
    expect(klass.new(line1: "1 Main St", postal_code: "AB12").valid?).to be(true)
  end
end
