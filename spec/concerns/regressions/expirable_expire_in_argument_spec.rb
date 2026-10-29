require "spec_helper"

# Audit 2026-10-29 (STATE-10): expire_in!'s argument guard was
# `respond_to?(:to_i) && !String`, which nil satisfies, so
# `token.expire_in!(params[:ttl])` with the param absent raised a bare
# TypeError from `Time.zone.now + nil`. Only a Duration or a Numeric is a
# lifetime; anything else raises the concern's ArgumentError before any hook.
describe "Expirable#expire_in! argument checking" do
  before do
    ActiveRecord::Schema.define do
      create_table :eia_tokens, force: true do |t|
        t.datetime :expires_at
      end
    end
  end

  after do
    ActiveRecord::Base.connection.drop_table(:eia_tokens, if_exists: true)
  end

  let(:model) do
    Class.new(TestModel) do
      self.table_name = "eia_tokens"
      include ConcernsOnRails::Expirable

      expirable_by :expires_at

      attr_accessor :fired

      def before_expire
        (self.fired ||= []) << :before_expire
      end
    end
  end

  [nil, "15", "soon", :soon, [], {}, true, Object.new].each do |bad|
    it "raises the concern's ArgumentError for #{bad.inspect}, writing nothing and firing no hook" do
      token = model.create!

      expect { token.expire_in!(bad) }.to raise_error(ArgumentError, /expire_in! takes a duration/)
      expect(token.reload.expires_at).to be_nil
      expect(token.fired).to be_nil
    end
  end

  describe "extend_expiry!(by:)" do
    [nil, "15", "soon", :soon, [], Object.new].each do |bad|
      it "raises the concern's ArgumentError for #{bad.inspect}, writing nothing" do
        future = Time.zone.now + 2.days
        token = model.create!(expires_at: future)

        expect { token.extend_expiry!(by: bad) }.to raise_error(ArgumentError, /extend_expiry! takes a duration/)
        expect(token.reload.expires_at).to be_within(1).of(future)
      end
    end

    it "still takes a Duration or a Numeric number of seconds" do
      token = model.create!(expires_at: Time.zone.now + 1.day)

      expect(token.extend_expiry!(by: 1.day)).to be(true)
      expect(token.expires_at).to be_within(2).of(Time.zone.now + 2.days)
      expect(token.extend_expiry!(by: 3600)).to be(true)
      expect(token.expires_at).to be_within(2).of(Time.zone.now + 2.days + 1.hour)
    end
  end

  it "still takes a Duration" do
    token = model.create!

    expect(token.expire_in!(15.minutes)).to be(true)
    expect(token.expires_at).to be_within(2).of(15.minutes.from_now)
    expect(token.fired).to be_nil
  end

  it "still takes a Numeric number of seconds (Integer, Float, BigDecimal)" do
    token = model.create!

    [90, 90.5, BigDecimal("90")].each do |seconds|
      expect(token.expire_in!(seconds)).to be(true)
      expect(token.expires_at).to be_within(2).of(Time.zone.now + 90)
    end
  end

  it "expires now, with the hooks, for a zero or negative duration" do
    token = model.create!

    expect(token.expire_in!(0)).to be(true)
    expect(token).to be_expired
    expect(token.fired).to eq([:before_expire])
  end
end
