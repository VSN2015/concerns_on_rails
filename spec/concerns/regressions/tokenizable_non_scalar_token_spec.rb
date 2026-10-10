require "action_controller"

# Regression (audit 2026-10-10, SCOPE-6): authenticate_by_<field> /
# consume_<field> passed any non-blank value to find_by, so a crafted request
# (`?token[a]=b` → a Hash or ActionController::Parameters) raised
# `TypeError: can't cast Hash` — a 500 on an authentication endpoint instead of
# a 401. Only a String or an Integer is looked up now; anything else answers nil.
RSpec.describe "Tokenizable finders with a non-scalar token" do
  before do
    ActiveRecord::Schema.define do
      create_table :non_scalar_keys, force: true do |t|
        t.string :api_token
        t.string :pin
      end
    end
    stub_const("NonScalarKey", Class.new(TestModel) do
      self.table_name = "non_scalar_keys"
      include ConcernsOnRails::Models::Tokenizable

      tokenizable_by :api_token
      tokenizable_by :pin, type: :numeric, length: 6
    end)
  end

  after do
    ActiveRecord::Base.connection.drop_table(:non_scalar_keys, if_exists: true)
  end

  let!(:key) { NonScalarKey.create! }

  [
    ["a Hash", { "a" => "b" }],
    ["an ActionController::Parameters", ActionController::Parameters.new("a" => "b")],
    ["an Array", %w[x y]],
    ["a Symbol", :token]
  ].each do |label, value|
    it "authenticate_by_<field> answers nil for #{label}" do
      expect(NonScalarKey.authenticate_by_api_token(value)).to be_nil
    end

    it "consume_<field> answers nil for #{label} and leaves the token in place" do
      expect(NonScalarKey.consume_api_token(value)).to be_nil
      expect(key.reload.api_token).to be_present
    end
  end

  it "still authenticates and consumes a String token" do
    expect(NonScalarKey.authenticate_by_api_token(key.api_token)).to eq(key)
    expect(NonScalarKey.consume_api_token(key.api_token)).to eq(key)
    expect(key.reload.api_token).to be_nil
  end

  it "still authenticates an Integer (a numeric code from a JSON body)" do
    key.update!(pin: "482913")
    expect(NonScalarKey.authenticate_by_pin(482_913)).to eq(key)
    expect(NonScalarKey.authenticate_by_pin(482_914)).to be_nil
  end
end
