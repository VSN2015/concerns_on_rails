require "spec_helper"

describe ConcernsOnRails::Expirable do
  before do
    ActiveRecord::Schema.define do
      create_table :api_tokens, force: true do |t|
        t.string :value
        t.datetime :expires_at
      end
    end

    class ApiToken < TestModel
      include ConcernsOnRails::Expirable

      expirable_by
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  describe "predicates" do
    it "is active when expires_at is nil (never expires)" do
      token = ApiToken.create!(value: "perm")
      expect(token.active?).to be true
      expect(token.expired?).to be false
    end

    it "is active when expires_at is in the future" do
      token = ApiToken.create!(value: "soon", expires_at: 1.hour.from_now)
      expect(token.active?).to be true
      expect(token.expired?).to be false
    end

    it "is expired when expires_at is in the past" do
      token = ApiToken.create!(value: "stale", expires_at: 1.hour.ago)
      expect(token.expired?).to be true
      expect(token.active?).to be false
    end

    it "is expired at exactly the expiry instant (exclusive boundary)" do
      freeze_time do
        token = ApiToken.create!(value: "boundary", expires_at: Time.zone.now)
        expect(token.expired?).to be true
      end
    end
  end

  describe "scopes" do
    it ".active returns nil-expiry and future-expiry records" do
      perm = ApiToken.create!(value: "perm")
      fut = ApiToken.create!(value: "future", expires_at: 1.hour.from_now)
      ApiToken.create!(value: "past", expires_at: 1.hour.ago)
      expect(ApiToken.active.map(&:value)).to match_array([perm.value, fut.value])
    end

    it ".expired returns only past-expiry records" do
      ApiToken.create!(value: "perm")
      ApiToken.create!(value: "future", expires_at: 1.hour.from_now)
      past = ApiToken.create!(value: "past", expires_at: 1.hour.ago)
      expect(ApiToken.expired.map(&:value)).to eq([past.value])
    end

    it ".expiring_within returns only records expiring inside the window" do
      ApiToken.create!(value: "perm")
      soon = ApiToken.create!(value: "soon", expires_at: 30.minutes.from_now)
      ApiToken.create!(value: "later", expires_at: 1.day.from_now)
      ApiToken.create!(value: "past", expires_at: 1.hour.ago)
      expect(ApiToken.expiring_within(1.hour).map(&:value)).to eq([soon.value])
    end
  end

  describe "#expire!" do
    it "sets expires_at to now by default" do
      token = ApiToken.create!(value: "x")
      freeze_time do
        token.expire!
        expect(token.expires_at).to eq(Time.zone.now)
        expect(token.expired?).to be true
      end
    end

    it "accepts an explicit time" do
      token = ApiToken.create!(value: "x")
      time = 1.day.from_now.change(usec: 0)
      token.expire!(time)
      expect(token.expires_at.to_i).to eq(time.to_i)
    end
  end

  describe "#extend_expiry!" do
    it "from never-expires sets to now + by" do
      token = ApiToken.create!(value: "perm")
      freeze_time do
        token.extend_expiry!(by: 1.day)
        expect(token.expires_at).to eq(Time.zone.now + 1.day)
      end
    end

    it "from past expiry resets relative to now" do
      token = ApiToken.create!(value: "stale", expires_at: 1.hour.ago)
      freeze_time do
        token.update(expires_at: 1.hour.ago) # ensure value is set against frozen now
        token.extend_expiry!(by: 1.day)
        expect(token.expires_at).to eq(Time.zone.now + 1.day)
      end
    end

    it "from future expiry adds to the existing value" do
      original = 1.hour.from_now.change(usec: 0)
      token = ApiToken.create!(value: "live", expires_at: original)
      token.extend_expiry!(by: 1.day)
      expect(token.expires_at.to_i).to eq((original + 1.day).to_i)
    end
  end

  describe "#time_until_expiry" do
    it "returns nil when there is no expiry" do
      expect(ApiToken.create!(value: "perm").time_until_expiry).to be_nil
    end

    it "returns an ActiveSupport::Duration when expiry is in the future" do
      token = ApiToken.create!(value: "future", expires_at: 1.hour.from_now)
      duration = token.time_until_expiry
      expect(duration).to be_a(ActiveSupport::Duration)
      expect(duration.to_i).to be_within(2).of(1.hour.to_i)
    end

    it "returns 0.seconds when already expired" do
      token = ApiToken.create!(value: "past", expires_at: 1.hour.ago)
      expect(token.time_until_expiry).to eq(0.seconds)
    end
  end

  describe "custom field configuration" do
    it "supports a custom expirable field" do
      ActiveRecord::Schema.define do
        create_table :licenses, force: true do |t|
          t.string :key
          t.datetime :valid_until
        end
      end

      class License < TestModel
        include ConcernsOnRails::Expirable

        expirable_by :valid_until
      end

      active = License.create!(key: "OK", valid_until: 1.day.from_now)
      License.create!(key: "EXPIRED", valid_until: 1.day.ago)
      expect(License.active.map(&:key)).to eq([active.key])
    end
  end

  describe "validation" do
    it "raises ArgumentError when the configured column does not exist" do
      ActiveRecord::Schema.define do
        create_table :bad_tokens, force: true do |t|
          t.string :value
        end
      end

      expect do
        class BadToken < TestModel
          include ConcernsOnRails::Expirable

          expirable_by :expires_at
        end
      end.to raise_error(ArgumentError, /does not exist/)
    end
  end

  it "allows reconfiguration on the same model" do
    ActiveRecord::Schema.define do
      create_table :reconfig_tokens, force: true do |t|
        t.string :value
        t.datetime :expires_at
        t.datetime :valid_until
      end
    end

    class ReconfigToken < TestModel
      include ConcernsOnRails::Expirable
    end

    ReconfigToken.expirable_by
    expect(ReconfigToken.expirable_field).to eq(:expires_at)

    ReconfigToken.expirable_by :valid_until
    expect(ReconfigToken.expirable_field).to eq(:valid_until)
  end

  describe "prefix / suffix scope names" do
    it "affixes the scope names to avoid collisions" do
      ActiveRecord::Schema.define do
        create_table :coupons, force: true do |t|
          t.datetime :expires_at
        end
      end

      klass = Class.new(TestModel) do
        self.table_name = "coupons"
        include ConcernsOnRails::Expirable

        expirable_by :expires_at, prefix: :coupon
      end

      live = klass.create!(expires_at: 1.hour.from_now)
      klass.create!(expires_at: 1.hour.ago)
      expect(klass.coupon_active.to_a).to eq([live])
      expect(klass.respond_to?(:active)).to be(false)
    end
  end
end
