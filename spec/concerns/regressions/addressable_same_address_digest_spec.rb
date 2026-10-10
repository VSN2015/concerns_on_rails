require "spec_helper"

# Audit 2026-10-10, TRANS-13. same_address_as? is documented as tolerant like
# its sibling with_address, which accepts a record, a digest String or nil,
# but it returned false for anything that does not respond to
# address_fingerprint. A digest String was therefore never "the same
# address", not even the record's own digest, while with_address(digest)
# found the record.
describe ConcernsOnRails::Models::Addressable do
  before do
    ActiveRecord::Schema.define do
      create_table :same_address_locations, force: true do |t|
        t.string :line1
        t.string :city
        t.string :postal_code
        t.string :country
        t.string :fp
      end
    end
  end

  after do
    ActiveRecord::Base.connection.drop_table(:same_address_locations, if_exists: true)
  end

  let(:klass) do
    Class.new(TestModel) do
      self.table_name = "same_address_locations"
      include ConcernsOnRails::Models::Addressable

      addressable_by fingerprint: :fp
    end
  end

  let(:apple) { { line1: "1 Infinite Loop", city: "Cupertino", postal_code: "95014", country: "US" } }

  it "matches a digest String, as with_address does" do
    location = klass.create!(apple)
    shouty = klass.new(line1: " 1 INFINITE LOOP ", city: "cupertino", postal_code: "95014", country: "us")

    expect(location.same_address_as?(location.address_fingerprint)).to be(true)
    expect(shouty.same_address_as?(location.fp)).to be(true)
    expect(klass.with_address(location.fp)).to contain_exactly(location)
  end

  it "answers false for a different digest, nil, a non-String and a blank address" do
    location = klass.new(apple)

    expect(location.same_address_as?("deadbeef")).to be(false)
    expect(location.same_address_as?(nil)).to be(false)
    expect(location.same_address_as?(42)).to be(false)
    expect(location.same_address_as?(:digest)).to be(false)
    expect(klass.new.same_address_as?(klass.new.address_fingerprint)).to be(false)
    expect(klass.new.same_address_as?("")).to be(false)
  end

  it "still compares records" do
    expect(klass.new(apple).same_address_as?(klass.new(apple))).to be(true)
    expect(klass.new(apple).same_address_as?(klass.new(apple.merge(city: "Palo Alto")))).to be(false)
  end
end
