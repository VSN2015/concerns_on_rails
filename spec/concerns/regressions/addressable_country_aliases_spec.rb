require "spec_helper"

# Audit 2026-10-10, TRANS-6. normalize_country: only knew COUNTRY_DATA's short
# English names, so "UK" stayed "UK" and was then REJECTED as an invalid ISO
# code, and "United States of America" stayed an unknown country, which
# skipped ZIP validation and fingerprinted differently from "US". ISO's own
# official short names ("Viet Nam", "Russian Federation") and former names
# ("Czech Republic") were missed the same way.
describe ConcernsOnRails::Models::Addressable do
  before do
    ActiveRecord::Schema.define do
      create_table :country_alias_locations, force: true do |t|
        t.string :line1
        t.string :city
        t.string :postal_code
        t.string :country
      end
    end
  end

  after do
    ActiveRecord::Base.connection.drop_table(:country_alias_locations, if_exists: true)
  end

  let(:klass) do
    Class.new(TestModel) do
      self.table_name = "country_alias_locations"
      include ConcernsOnRails::Models::Addressable

      addressable_by required: %i[line1], normalize_country: true
    end
  end

  it "normalizes 'UK', ISO official names and the usual long and former forms" do
    {
      "UK" => "GB", "uk" => "GB", "Great Britain" => "GB", "United States of America" => "US",
      "Viet Nam" => "VN", "Russian Federation" => "RU", "Czech Republic" => "CZ", "Republic of Korea" => "KR",
      "Korea, Republic of" => "KR", "Iran, Islamic Republic of" => "IR", "Bolivia (Plurinational State of)" => "BO",
      "Swaziland" => "SZ", "Burma" => "MM", "Ivory Coast" => "CI", "Holland" => "NL", "Türkiye" => "TR"
    }.each do |input, expected|
      record = klass.new(line1: "1 Main St", country: input)
      record.valid?
      expect(record.country).to eq(expected), "#{input.inspect} normalized to #{record.country.inspect}"
    end
  end

  it "accepts a UK address typed with 'UK'" do
    uk = klass.new(line1: "10 Downing St", city: "London", postal_code: "SW1A 2AA", country: "UK")

    expect(uk.valid?).to be(true), uk.errors.full_messages.inspect
    expect(uk.country).to eq("GB")
  end

  it "applies US rules and the US fingerprint to 'United States of America'" do
    long_us = klass.new(line1: "1 Main St", city: "Springfield", postal_code: "ABCDE", country: "United States of America")
    expect(long_us.valid?).to be(false)
    expect(long_us.errors[:postal_code]).to include("is not a valid postal code")

    long_us.postal_code = "62701"
    short_us = klass.new(line1: "1 Main St", city: "Springfield", postal_code: "62701", country: "US")
    expect(long_us.address_fingerprint).to eq(short_us.address_fingerprint)
  end

  describe ConcernsOnRails::Support::AddressData do
    it "folds diacritics and typographic apostrophes in names" do
      { "Cote d'Ivoire" => "CI", "Côte d’Ivoire" => "CI", "Curacao" => "CW", "Reunion" => "RE",
        "Sao Tome and Principe" => "ST", "Aland Islands" => "AX", "turkiye" => "TR" }.each do |input, expected|
        expect(described_class.normalize_country_code(input)).to eq(expected), input.inspect
      end
    end

    it "keeps every alias pointing at a real country, never shadowing a code or another country's name" do
      names = described_class::COUNTRY_DATA.to_h { |code, (name, _a3)| [described_class.country_key(name), code] }

      described_class::COUNTRY_ALIASES.each do |key, code|
        expect(described_class::ISO_COUNTRY_CODES).to include(code)
        expect(described_class.country_key(key)).to eq(key)
        expect(described_class::ISO_COUNTRY_CODES).not_to include(key.upcase)
        expect(described_class::ALPHA3_TO_ALPHA2).not_to have_key(key.upcase)
        expect(names).not_to have_key(key)
      end
    end

    it "leaves the one-name-per-country lookup alone, and unknown values untouched" do
      expect(described_class::NAME_TO_ALPHA2.size).to eq(described_class::COUNTRY_DATA.size)
      expect(described_class.normalize_country_code("Freedonia")).to eq("Freedonia")
      expect(described_class.normalize_country_code("Korea")).to eq("Korea")
      expect(described_class.normalize_country_code("\xFF".b)).to eq("\xFF".b)
    end
  end
end
