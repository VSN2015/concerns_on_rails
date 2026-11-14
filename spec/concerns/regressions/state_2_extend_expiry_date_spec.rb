require "spec_helper"

# STATE-2 (audit v1.35.2): extend_expiry! judged a date expiry "already expired"
# with Date <=> TimeWithZone (UTC midnight), not the predicates' Time.zone bound.
describe "Expirable#extend_expiry! on a date column" do
  before do
    ActiveRecord::Schema.define do
      create_table :s2_tokens, force: true do |t|
        t.date :expires_on
      end
    end
  end

  after { ActiveRecord::Base.connection.drop_table(:s2_tokens, if_exists: true) }

  let(:model) do
    Class.new(TestModel) do
      self.table_name = "s2_tokens"
      include ConcernsOnRails::Expirable

      expirable_by :expires_on
    end
  end

  it "extends a still-live expiry from that expiry, in a zone behind UTC" do
    Time.use_zone("America/Los_Angeles") do
      travel_to(Time.utc(2026, 11, 14, 4, 0, 0)) do # 20:00 on 2026-11-13 in Los Angeles
        token = model.create!(expires_on: Date.new(2026, 11, 14))
        expect(token).not_to be_expired
        token.extend_expiry!(by: 30.days)
        expect(token.reload.expires_on).to eq(Date.new(2026, 12, 14))
      end
    end
  end

  it "extends an already-expired date expiry from today in Time.zone" do
    Time.use_zone("America/Los_Angeles") do
      travel_to(Time.utc(2026, 11, 14, 4, 0, 0)) do
        token = model.create!(expires_on: Date.new(2026, 11, 13)) # today: expired
        expect(token).to be_expired
        token.extend_expiry!(by: 30.days)
        expect(token.reload.expires_on).to eq(Date.new(2026, 12, 13))
      end
    end
  end
end
