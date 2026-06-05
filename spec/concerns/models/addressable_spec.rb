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

      it "rejects an unknown Canadian province when validate_state is on" do
        define_location(required: %i[country], validate_state: true)
        loc = Location.new(country: "CA", state: "ZZ")
        expect(loc.valid?).to be false
        expect(loc.errors[:state]).to include("is not a valid state/province")
      end

      it "accepts a known Canadian province when validate_state is on" do
        define_location(required: %i[country], validate_state: true)
        loc = Location.new(country: "CA", state: "ON")
        expect(loc.valid?).to be true
      end

      it "ignores the state by default" do
        define_location(required: %i[country])
        loc = Location.new(country: "US", state: "ZZ")
        expect(loc.valid?).to be true
      end
    end

    describe "country resolution for postal/state format" do
      it "does not reject a valid foreign postal code when the country is a full name" do
        define_location
        loc = Location.new(line1: "1 Main St", city: "Ottawa", postal_code: "K1A 0B1", country: "Canada")
        expect(loc.valid?).to be true
      end

      it "does not apply default-country state rules to an unrecognized country" do
        define_location(required: %i[country], validate_state: true)
        loc = Location.new(country: "Canada", state: "ON")
        expect(loc.valid?).to be true
      end

      it "still validates a blank country's postal code against default_country" do
        define_location(required: %i[line1 city], default_country: "DE")
        expect(Location.new(line1: "x", city: "y", postal_code: "12345").valid?).to be true

        loc = Location.new(line1: "x", city: "y", postal_code: "1234")
        expect(loc.valid?).to be false
        expect(loc.errors[:postal_code]).to include("is not a valid postal code")
      end
    end
  end

  describe "length validation" do
    it "rejects a value longer than an Integer maximum" do
      define_location(required: [], lengths: { line1: 5 })
      loc = Location.new(line1: "way too long")
      expect(loc.valid?).to be false
      expect(loc.errors[:line1]).to include("is too long (maximum is 5 characters)")
    end

    it "accepts a value within an Integer maximum" do
      define_location(required: [], lengths: { line1: 5 })
      expect(Location.new(line1: "short").valid?).to be true
    end

    it "treats a blank value as valid for a maximum-only rule" do
      define_location(required: [], lengths: { line1: 5 })
      expect(Location.new(line1: "").valid?).to be true
      expect(Location.new(line1: nil).valid?).to be true
    end

    it "enforces both bounds of a Range" do
      define_location(required: [], lengths: { city: 3..8 })
      expect(Location.new(city: "ab").valid?).to be false
      expect(Location.new(city: "abcdefghi").valid?).to be false
      expect(Location.new(city: "abcd").valid?).to be true
    end

    it "reports too short with the minimum in the message" do
      define_location(required: [], lengths: { city: 3..8 })
      loc = Location.new(city: "ab")
      loc.valid?
      expect(loc.errors[:city]).to include("is too short (minimum is 3 characters)")
    end

    it "measures length on the normalized (squished) value" do
      define_location(required: [], lengths: { city: 3 })
      expect(Location.new(city: "  abcd  ").valid?).to be false
      expect(Location.new(city: "  ab  ").valid?).to be true
    end

    it "supports an exclusive Range" do
      define_location(required: [], lengths: { state: 2...4 })
      expect(Location.new(state: "ab").valid?).to be true
      expect(Location.new(state: "abcd").valid?).to be false
    end

    it "supports an endless Range (minimum only, no maximum)" do
      define_location(required: [], lengths: { line1: 3.. })
      expect(Location.new(line1: "ab").valid?).to be false
      loc = Location.new(line1: "a" * 1000)
      expect(loc.valid?).to be true
      expect(loc.errors[:line1]).to be_empty
    end

    it "supports a beginless Range (maximum only, blank allowed)" do
      define_location(required: [], lengths: { city: ..8 })
      expect(Location.new(city: "").valid?).to be true
      expect(Location.new(city: "123456789").valid?).to be false
    end

    it "pluralizes the message: singular 'character' for a bound of 1" do
      define_location(required: [], lengths: { state: 1 })
      loc = Location.new(state: "ab")
      expect(loc.valid?).to be false
      expect(loc.errors[:state]).to include("is too long (maximum is 1 character)")
    end

    it "counts characters, not bytes, for multibyte values" do
      define_location(required: [], lengths: { city: 4 })
      expect(Location.new(city: "café").valid?).to be true
      expect(Location.new(city: "caféx").valid?).to be false
    end

    it "measures postal_code length after CA canonical-spacing normalization" do
      define_location(required: [], lengths: { postal_code: 6 })
      # "k1a0b1" normalizes to the 7-char "K1A 0B1"
      expect(Location.new(country: "CA", postal_code: "k1a0b1").valid?).to be false

      define_location(required: [], lengths: { postal_code: 7 })
      expect(Location.new(country: "CA", postal_code: "k1a0b1").valid?).to be true
    end

    it "checks the mapped column for a custom mapping" do
      klass = Class.new(TestModel) do
        self.table_name = "places"
        include ConcernsOnRails::Models::Addressable

        addressable_by line1: :street, postal_code: :zip, country: :country_code,
                       required: [], lengths: { line1: 4 }
      end
      Object.const_set(:Place, klass)
      loc = Place.new(street: "toolong")
      expect(loc.valid?).to be false
      expect(loc.errors[:street]).to include("is too long (maximum is 4 characters)")
    end

    describe "allow_blank (per-field, independent of required)" do
      it "fails a blank value against a minimum by default" do
        define_location(required: [], lengths: { city: 3..8 })
        loc = Location.new(city: "")
        expect(loc.valid?).to be false
        expect(loc.errors[:city]).to include("is too short (minimum is 3 characters)")
      end

      it "skips the length check for a blank value when the part is in allow_blank" do
        define_location(required: [], lengths: { city: 3..8 }, allow_blank: %i[city])
        expect(Location.new(city: "").valid?).to be true
        expect(Location.new(city: nil).valid?).to be true
      end

      it "still checks a present value when the part is in allow_blank" do
        define_location(required: [], lengths: { city: 3..8 }, allow_blank: %i[city])
        loc = Location.new(city: "ab")
        expect(loc.valid?).to be false
        expect(loc.errors[:city]).to include("is too short (minimum is 3 characters)")
      end

      it "allow_blank: true exempts every part from the blank check" do
        define_location(required: [], lengths: { line1: 3..8, city: 3..8 }, allow_blank: true)
        expect(Location.new.valid?).to be true
      end

      it "is independent of required: a blank min-length part errors even when not required" do
        define_location(required: %i[country], lengths: { city: 3..8 })
        loc = Location.new(country: "US")
        expect(loc.valid?).to be false
        expect(loc.errors[:city]).to include("is too short (minimum is 3 characters)")
      end

      it "is independent of required: a required blank part with a minimum gets both errors" do
        define_location(required: %i[city], lengths: { city: 3..8 })
        loc = Location.new(city: "")
        expect(loc.valid?).to be false
        expect(loc.errors[:city]).to include("can't be blank", "is too short (minimum is 3 characters)")
      end

      it "is a harmless no-op when allow_blank lists a part with no length rule" do
        define_location(required: [], lengths: { city: 3..8 }, allow_blank: %i[state])
        expect(Location.new(city: "abcd").valid?).to be true
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

    it "treats a length rule for an absent column as a no-op" do
      klass = Class.new(TestModel) do
        self.table_name = "minimal_spots"
        include ConcernsOnRails::Models::Addressable

        addressable_by required: [], lengths: { postal_code: 5 }
      end
      Object.const_set(:MinimalSpot, klass)
      expect(MinimalSpot.new(line1: "1 Main St", city: "Anywhere").valid?).to be true
    end
  end

  describe "configuration errors" do
    it "raises for an unknown address part" do
      expect do
        define_location(unit: :line2)
      end.to raise_error(ArgumentError, /unknown address part/)
    end

    it "raises when lengths: is not a Hash" do
      expect { define_location(lengths: [1, 2]) }.to raise_error(ArgumentError, /lengths: must be a Hash/)
    end

    it "raises for an unknown address part in lengths" do
      expect { define_location(lengths: { citi: 50 }) }.to raise_error(ArgumentError, /unknown address part in lengths/)
    end

    it "raises for a non-positive Integer length" do
      expect { define_location(lengths: { city: 0 }) }.to raise_error(ArgumentError, /must be a positive Integer/)
    end

    it "raises for a length bound that is neither Integer nor Range" do
      expect { define_location(lengths: { city: "50" }) }.to raise_error(ArgumentError, /must be an Integer or Range/)
    end

    it "raises for an inverted Range" do
      expect { define_location(lengths: { city: 8..3 }) }.to raise_error(ArgumentError, /empty or inverted/)
    end

    it "raises for an empty exclusive Range" do
      expect { define_location(lengths: { city: 3...3 }) }.to raise_error(ArgumentError, /empty or inverted/)
    end

    it "raises for a Range with a negative bound" do
      expect { define_location(lengths: { city: -5..10 }) }.to raise_error(ArgumentError, /non-negative Integer bounds/)
    end

    it "raises for a Range with non-Integer endpoints" do
      expect { define_location(lengths: { city: "a".."z" }) }.to raise_error(ArgumentError, /non-negative Integer bounds/)
      expect { define_location(lengths: { city: 1.5..3.5 }) }.to raise_error(ArgumentError, /non-negative Integer bounds/)
    end

    it "raises for an unknown address part in allow_blank" do
      expect { define_location(allow_blank: %i[citi]) }.to raise_error(ArgumentError, /unknown address part\(s\) in allow_blank/)
    end

    it "raises for an allow_blank that is not true/false/Array" do
      expect { define_location(allow_blank: :city) }.to raise_error(ArgumentError, /allow_blank: must be true, false, or an Array/)
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

  describe "country normalization (normalize_country:)" do
    it "leaves a full country name untouched by default" do
      define_location(required: [])
      expect(Location.new(country: "Canada").tap(&:valid?).country).to eq("Canada")
    end

    it "maps a recognized English name to its ISO alpha-2 code" do
      define_location(required: [], normalize_country: true)
      expect(Location.new(country: "Canada").tap(&:valid?).country).to eq("CA")
      expect(Location.new(country: "United States").tap(&:valid?).country).to eq("US")
      expect(Location.new(country: "Germany").tap(&:valid?).country).to eq("DE")
    end

    it "maps a 3-letter alpha-3 code to its alpha-2" do
      define_location(required: [], normalize_country: true)
      expect(Location.new(country: "USA").tap(&:valid?).country).to eq("US")
      expect(Location.new(country: "DEU").tap(&:valid?).country).to eq("DE")
    end

    it "is case-insensitive for names and upcases a bare alpha-2" do
      define_location(required: [], normalize_country: true)
      expect(Location.new(country: "  canada ").tap(&:valid?).country).to eq("CA")
      expect(Location.new(country: "us").tap(&:valid?).country).to eq("US")
    end

    it "leaves an unrecognized value untouched" do
      define_location(required: [], normalize_country: true)
      expect(Location.new(country: "Freedonia").tap(&:valid?).country).to eq("Freedonia")
    end

    it "makes postal-code validation recognize a named country (with CA spacing)" do
      define_location(required: [], normalize_country: true)
      loc = Location.new(country: "Canada", postal_code: "k1a0b1")
      expect(loc.valid?).to be true
      expect(loc.country).to eq("CA")
      expect(loc.postal_code).to eq("K1A 0B1")
    end

    it "makes state validation recognize a named country" do
      define_location(required: [], normalize_country: true, validate_state: true)
      expect(Location.new(country: "Canada", state: "ON").valid?).to be true

      loc = Location.new(country: "Canada", state: "ZZ")
      expect(loc.valid?).to be false
      expect(loc.errors[:state]).to include("is not a valid state/province")
    end
  end

  describe ConcernsOnRails::Support::AddressData do
    it "covers every ISO 3166-1 country exactly once" do
      expect(described_class::ISO_COUNTRY_CODES.size).to eq(249)
      expect(described_class::ISO_COUNTRY_CODES).to include("US", "CA", "GB", "DE", "FR", "AU", "BR")
      expect(described_class::ISO_COUNTRY_CODES).not_to include("ZZ")
    end

    it "has no duplicate alpha-3 codes or names (lossless lookups)" do
      expect(described_class::ALPHA3_TO_ALPHA2.size).to eq(described_class::COUNTRY_DATA.size)
      expect(described_class::NAME_TO_ALPHA2.size).to eq(described_class::COUNTRY_DATA.size)
    end

    it "stores a 3-uppercase-letter alpha-3 and a non-empty name for every country" do
      described_class::COUNTRY_DATA.each do |code, (name, alpha3)|
        expect(code).to match(/\A[A-Z]{2}\z/)
        expect(alpha3).to match(/\A[A-Z]{3}\z/)
        expect(name).not_to be_empty
      end
    end

    it "canonicalizes names, alpha-3, and alpha-2; leaves unknown values alone" do
      expect(described_class.normalize_country_code("United States")).to eq("US")
      expect(described_class.normalize_country_code("USA")).to eq("US")
      expect(described_class.normalize_country_code("canada")).to eq("CA")
      expect(described_class.normalize_country_code("us")).to eq("US")
      expect(described_class.normalize_country_code("Freedonia")).to eq("Freedonia")
      expect(described_class.normalize_country_code(nil)).to be_nil
    end
  end

  describe "conditional validation (if: / unless:)" do
    it "runs the address validation only when an if: condition holds" do
      define_location(required: %i[country], if: :line2?)
      expect(Location.new.valid?).to be true

      loc = Location.new(line2: "Apt 1")
      expect(loc.valid?).to be false
      expect(loc.errors[:country]).to include("can't be blank")
    end

    it "skips the address validation when an unless: condition holds" do
      define_location(required: %i[country], unless: :line2?)
      expect(Location.new(line2: "Apt 1").valid?).to be true

      loc = Location.new
      expect(loc.valid?).to be false
      expect(loc.errors[:country]).to include("can't be blank")
    end

    it "supports a proc condition" do
      define_location(required: %i[country], if: -> { city == "CHECK" })
      expect(Location.new(city: "skip").valid?).to be true

      loc = Location.new(city: "CHECK")
      expect(loc.valid?).to be false
      expect(loc.errors[:country]).to include("can't be blank")
    end

    it "supports an array of conditions (all must hold)" do
      define_location(required: %i[country], if: %i[line2? city?])
      expect(Location.new(line2: "Apt 1").valid?).to be true

      loc = Location.new(line2: "Apt 1", city: "Town")
      expect(loc.valid?).to be false
      expect(loc.errors[:country]).to include("can't be blank")
    end

    it "treats if:/unless: as conditions, not as address-part columns" do
      expect { define_location(required: [], if: :line2?, unless: :persisted?) }.not_to raise_error
    end

    it "still normalizes even when the validation condition is false" do
      define_location(required: [], if: :line2?, normalize_country: true)
      loc = Location.new(country: "canada", city: "  Town  ")
      loc.valid?
      expect(loc.country).to eq("CA")
      expect(loc.city).to eq("Town")
    end
  end
end
