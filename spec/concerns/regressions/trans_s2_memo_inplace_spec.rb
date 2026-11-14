require "spec_helper"

# TRANS-S2 (audit v1.35.2): memos keyed by the raw String object went stale on in-place mutation.
RSpec.describe "memo keys survive in-place mutation of the attribute String" do
  before do
    ActiveRecord::Schema.define do
      create_table :ts2_prefs, force: true do |t|
        t.text :settings
        t.string :country
        t.string :postal_code
      end
    end
  end

  after { ActiveRecord::Base.connection.drop_table(:ts2_prefs, if_exists: true) }

  it "Storable re-decodes after settings is edited in place" do
    model = Class.new(TestModel) do
      self.table_name = "ts2_prefs"
      include ConcernsOnRails::Storable

      storable_by :settings, theme: { type: :string }
    end
    pref = model.find(model.create!(theme: "dark").id)
    expect(pref.theme).to eq("dark")
    pref.settings.replace('{"theme":"light"}')
    expect(pref.theme).to eq("light")
  end

  it "Addressable re-resolves the country after it is edited in place" do
    model = Class.new(TestModel) do
      self.table_name = "ts2_prefs"
      include ConcernsOnRails::Addressable

      addressable_by country: :country, postal_code: :postal_code, required: []
    end
    rec = model.new(country: "US")
    expect(rec.send(:resolved_country)).to eq("US")
    rec.country.replace("GB")
    expect(rec.send(:resolved_country)).to eq("GB")
  end
end
