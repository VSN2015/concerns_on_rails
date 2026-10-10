require "spec_helper"

# Audit 2026-10-10, TRANS-1. The README promised the `fingerprint:` column is
# "stamped in before_validation, after normalization", but it was stamped only
# in before_save. Every validation therefore saw nil (a new record) or the
# PREVIOUS address's digest (an update), so a dedupe validation on the
# fingerprint could never work.
describe ConcernsOnRails::Models::Addressable do
  before do
    ActiveRecord::Schema.define do
      create_table :fingerprint_validation_locations, force: true do |t|
        t.string :line1
        t.string :city
        t.string :postal_code
        t.string :country
        t.string :fp
      end
    end
  end

  after do
    ActiveRecord::Base.connection.drop_table(:fingerprint_validation_locations, if_exists: true)
  end

  let(:apple) { { line1: "1 Infinite Loop", city: "Cupertino", postal_code: "95014", country: "US" } }

  it "stamps the column before the app's validations, so a uniqueness validation on it dedupes" do
    klass = Class.new(TestModel) do
      self.table_name = "fingerprint_validation_locations"
      include ConcernsOnRails::Models::Addressable

      addressable_by fingerprint: :fp, required: %i[line1]
      validates :fp, uniqueness: true
    end

    first = klass.create!(apple)
    second = klass.new(line1: " 1 infinite  loop ", city: "cupertino", postal_code: "95014", country: "us")

    expect(second.valid?).to be(false)
    expect(second.fp).to eq(first.fp)
    expect(second.errors[:fp]).to include("has already been taken")
    expect(klass.with_address(first).count).to eq(1)
  end

  it "stamps ahead of a validation declared before the concern was included" do
    seen = :unset
    klass = Class.new(TestModel) do
      self.table_name = "fingerprint_validation_locations"
      validate { seen = fp }
      include ConcernsOnRails::Models::Addressable

      addressable_by fingerprint: :fp, required: %i[line1]
    end

    record = klass.new(apple)
    record.valid?

    expect(seen).to eq(record.address_fingerprint)
    expect(seen).to match(/\A\h{64}\z/)
  end

  it "validates an update against the NEW address's digest, not the stored one" do
    seen = nil
    klass = Class.new(TestModel) do
      self.table_name = "fingerprint_validation_locations"
      include ConcernsOnRails::Models::Addressable

      addressable_by fingerprint: :fp, required: %i[line1]
      validate { seen = fp }
    end

    record = klass.create!(apple)
    old_digest = record.fp
    record.line1 = "2 Infinite Loop"
    record.valid?

    expect(seen).to eq(record.address_fingerprint)
    expect(seen).not_to eq(old_digest)
  end

  it "still stamps on a save that skips validation" do
    klass = Class.new(TestModel) do
      self.table_name = "fingerprint_validation_locations"
      include ConcernsOnRails::Models::Addressable

      addressable_by fingerprint: :fp, required: %i[line1]
    end

    record = klass.new(apple)
    record.save(validate: false)

    expect(record.reload.fp).to eq(record.address_fingerprint)
  end
end
