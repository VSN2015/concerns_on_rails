require "spec_helper"

describe ConcernsOnRails::Models::Addressable do
  before do
    ActiveRecord::Schema.define do
      create_table :locations, force: true do |t|
        t.string :line1
        t.string :line2
        t.string :city
        t.string :state
        t.string :postal_code
        t.string :country
      end

      create_table :places, force: true do |t|
        t.string :street
        t.string :city
        t.string :region
        t.string :zip
        t.string :country_code
      end

      create_table :minimal_spots, force: true do |t|
        t.string :line1
        t.string :city
      end
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end

    %i[Location Place MinimalSpot].each do |const|
      Object.send(:remove_const, const) if Object.const_defined?(const)
    end
  end

  def define_location(**opts)
    klass = Class.new(TestModel) do
      self.table_name = "locations"
      include ConcernsOnRails::Models::Addressable

      addressable_by(**opts)
    end
    Object.const_set(:Location, klass)
  end

  describe "normalization" do
    it "strips and squishes text parts" do
      define_location
      loc = Location.new(line1: "  123   Main   St ", city: "  San   Francisco ", country: "US", postal_code: "94105")
      loc.valid?
      expect(loc.line1).to eq("123 Main St")
      expect(loc.city).to eq("San Francisco")
    end

    it "upcases a 2-letter country code but leaves full names alone" do
      define_location
      Location.new(country: "us").tap(&:valid?).tap { |l| expect(l.country).to eq("US") }
      Location.new(country: "Canada").tap(&:valid?).tap { |l| expect(l.country).to eq("Canada") }
    end

    it "upcases a 2-letter state code" do
      define_location
      loc = Location.new(state: "ca")
      loc.valid?
      expect(loc.state).to eq("CA")
    end

    it "upcases and squishes the postal code" do
      define_location
      loc = Location.new(country: "GB", postal_code: " sw1a  1aa ")
      loc.valid?
      expect(loc.postal_code).to eq("SW1A 1AA")
    end

    it "adds canonical spacing to a Canadian postal code" do
      define_location
      loc = Location.new(country: "ca", postal_code: "k1a0b1")
      loc.valid?
      expect(loc.postal_code).to eq("K1A 0B1")
    end

    it "leaves nil values alone" do
      define_location(required: [])
      loc = Location.new(line1: nil)
      loc.valid?
      expect(loc.line1).to be_nil
    end
  end

  describe "validation" do
    it "accepts a well-formed US address" do
      define_location
      loc = Location.new(line1: "1 Infinite Loop", city: "Cupertino", state: "CA", postal_code: "95014", country: "US")
      expect(loc.valid?).to be true
    end

    it "requires the configured required parts" do
      define_location
      loc = Location.new(line1: "1 Main St", city: "", postal_code: "95014", country: "US")
      expect(loc.valid?).to be false
      expect(loc.errors[:city]).to include("can't be blank")
    end

    it "rejects an unknown ISO country code" do
      define_location(required: %i[country])
      loc = Location.new(country: "ZZ")
      expect(loc.valid?).to be false
      expect(loc.errors[:country]).to include("is not a valid ISO 3166-1 country code")
    end

    it "rejects a malformed US postal code" do
      define_location
      loc = Location.new(line1: "1 Main St", city: "Cupertino", postal_code: "123", country: "US")
      expect(loc.valid?).to be false
      expect(loc.errors[:postal_code]).to include("is not a valid postal code")
    end

    it "accepts a valid Canadian postal code" do
      define_location
      loc = Location.new(line1: "1 Main St", city: "Ottawa", postal_code: "K1A 0B1", country: "CA")
      expect(loc.valid?).to be true
    end

    it "falls back to a permissive pattern for unmapped countries" do
      define_location
      loc = Location.new(line1: "1 Rua", city: "Sao Paulo", postal_code: "12345-678", country: "BR")
      expect(loc.valid?).to be true
    end

    describe "opt-in state validation" do
      it "rejects an unknown US state when validate_state is on" do
        define_location(required: %i[country], validate_state: true)
        loc = Location.new(country: "US", state: "ZZ")
        expect(loc.valid?).to be false
        expect(loc.errors[:state]).to include("is not a valid state/province")
      end

      it "accepts a known US state when validate_state is on" do
        define_location(required: %i[country], validate_state: true)
        loc = Location.new(country: "US", state: "CA")
        expect(loc.valid?).to be true
      end

      it "ignores the state by default" do
        define_location(required: %i[country])
        loc = Location.new(country: "US", state: "ZZ")
        expect(loc.valid?).to be true
      end
    end
  end

  describe "verify_with hook" do
    def location_with_verifier(verifier)
      define_location(required: %i[country], verify_with: verifier)
    end

    it "adds a generic error when the verifier returns false" do
      location_with_verifier(->(_rec) { false })
      loc = Location.new(country: "US")
      expect(loc.valid?).to be false
      expect(loc.errors[:base]).to include("address could not be verified")
    end

    it "uses a returned String as the base error" do
      location_with_verifier(->(_rec) { "undeliverable address" })
      loc = Location.new(country: "US")
      expect(loc.valid?).to be false
      expect(loc.errors[:base]).to include("undeliverable address")
    end

    it "uses a returned Array as multiple base errors" do
      location_with_verifier(->(_rec) { ["bad zip", "bad street"] })
      loc = Location.new(country: "US")
      expect(loc.valid?).to be false
      expect(loc.errors[:base]).to include("bad zip", "bad street")
    end

    it "treats true as success" do
      location_with_verifier(->(_rec) { true })
      loc = Location.new(country: "US")
      expect(loc.valid?).to be true
    end

    it "lets the verifier add errors directly to the record" do
      location_with_verifier(->(rec) { rec.errors.add(:country, "is on a blocklist") })
      loc = Location.new(country: "US")
      expect(loc.valid?).to be false
      expect(loc.errors[:country]).to include("is on a blocklist")
    end

    it "does not run the verifier when structural validation already failed" do
      define_location(verify_with: ->(rec) { rec.errors.add(:base, "verifier ran") })
      loc = Location.new(line1: "1 Main St", city: "Cupertino", postal_code: "123", country: "US")
      expect(loc.valid?).to be false
      expect(loc.errors[:base]).not_to include("verifier ran")
    end
  end

  describe "custom column mapping" do
    def define_place
      klass = Class.new(TestModel) do
        self.table_name = "places"
        include ConcernsOnRails::Models::Addressable

        addressable_by line1: :street, state: :region, postal_code: :zip, country: :country_code,
                       required: %i[line1 city postal_code country]
      end
      Object.const_set(:Place, klass)
    end

    it "normalizes and validates against the mapped columns" do
      define_place
      place = Place.new(street: "  10   Downing  St ", city: "London", region: "ENG",
                        zip: " sw1a 2aa ", country_code: "gb")
      expect(place.valid?).to be true
      expect(place.street).to eq("10 Downing St")
      expect(place.zip).to eq("SW1A 2AA")
      expect(place.country_code).to eq("GB")
    end

    it "raises when an explicit mapping points at a missing column" do
      expect do
        Class.new(TestModel) do
          self.table_name = "places"
          include ConcernsOnRails::Models::Addressable

          addressable_by line1: :nonexistent
        end
      end.to raise_error(ArgumentError, /does not exist/)
    end
  end

  describe "partial schema" do
    def define_minimal
      klass = Class.new(TestModel) do
        self.table_name = "minimal_spots"
        include ConcernsOnRails::Models::Addressable

        addressable_by required: %i[line1 city]
      end
      Object.const_set(:MinimalSpot, klass)
    end

    it "ignores parts whose columns are absent" do
      define_minimal
      spot = MinimalSpot.new(line1: "1 Main St", city: "Anywhere")
      expect(spot.valid?).to be true
      expect(spot.full_address).to eq("1 Main St, Anywhere")
    end

    it "raises when a required part has no matching column" do
      expect do
        Class.new(TestModel) do
          self.table_name = "minimal_spots"
          include ConcernsOnRails::Models::Addressable

          addressable_by required: %i[postal_code]
        end
      end.to raise_error(ArgumentError, /no matching column/)
    end
  end

  describe "configuration errors" do
    it "raises for an unknown address part" do
      expect do
        define_location(unit: :line2)
      end.to raise_error(ArgumentError, /unknown address part/)
    end
  end

  describe "instance helpers" do
    before { define_location }

    let(:loc) do
      Location.new(line1: "1 Infinite Loop", line2: "Suite 100", city: "Cupertino",
                   state: "CA", postal_code: "95014", country: "US")
    end

    it "joins present parts in canonical order via full_address" do
      loc.valid?
      expect(loc.full_address).to eq("1 Infinite Loop, Suite 100, Cupertino, CA, 95014, US")
    end

    it "skips blank parts and honors a custom separator" do
      loc.line2 = nil
      expect(loc.full_address(separator: " / ")).to eq("1 Infinite Loop / Cupertino / CA / 95014 / US")
    end

    it "exposes address_lines as an ordered array" do
      loc.line2 = nil
      expect(loc.address_lines).to eq(["1 Infinite Loop", "Cupertino", "CA", "95014", "US"])
    end

    it "reports address_present? and address_complete?" do
      expect(loc.address_present?).to be true
      expect(loc.address_complete?).to be true
      expect(Location.new.address_present?).to be false
      expect(Location.new(line1: "1 Main St").address_complete?).to be false
    end

    it "returns present parts as a hash via address_attributes" do
      loc.line2 = nil
      expect(loc.address_attributes).to eq(
        line1: "1 Infinite Loop", city: "Cupertino", state: "CA", postal_code: "95014", country: "US"
      )
    end
  end
end
