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

    # The plain predicates keep master's delegation: an app overriding
    # `expired?` (a grace period, say) still moves `active?` with it.
    it "derives active? from an overridden expired?" do
      graced = Class.new(TestModel) do
        self.table_name = "api_tokens"
        include ConcernsOnRails::Expirable

        expirable_by :expires_at, prefix: :term

        def expired?
          false
        end
      end
      token = graced.create!(expires_at: 1.hour.ago)

      expect(token.active?).to be(true)
      expect(token.term_active?).to be(false) # the affixed predicate is Expirable's own answer
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

    # The affix used to cover only the scopes: `active?`/`expired?` kept their
    # plain names, so on a model that also includes Activatable or
    # Schedulable one concern's predicate silently replaced the other's.
    it "defines affixed predicates alongside the plain ones" do
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
      lapsed = klass.create!(expires_at: 1.hour.ago)
      expect([live.coupon_active?, live.coupon_expired?]).to eq([true, false])
      expect([lapsed.coupon_active?, lapsed.coupon_expired?]).to eq([false, true])
      expect([lapsed.active?, lapsed.expired?]).to eq([false, true])
    end

    # Re-declaring the macro with a different affix used to leave the old
    # affix's predicates defined alongside the new ones.
    it "retires the previous affix's predicates when the macro is re-declared" do
      klass = Class.new(TestModel) do
        self.table_name = "api_tokens"
        include ConcernsOnRails::Expirable

        expirable_by :expires_at, prefix: :old
        expirable_by :expires_at, prefix: :new
      end
      token = klass.create!(expires_at: 1.hour.ago)

      expect(token.new_expired?).to be(true)
      expect(token).not_to respond_to(:old_expired?)
      expect(token).not_to respond_to(:old_active?)

      bare = Class.new(klass) { expirable_by :expires_at }
      expect(bare.new).not_to respond_to(:new_expired?)
      expect(bare.new.expired?).to be(false)
    end

    it "retires an inherited affix's predicates on a subclass only" do
      parent = Class.new(TestModel) do
        self.table_name = "api_tokens"
        include ConcernsOnRails::Expirable

        expirable_by :expires_at, prefix: :old
      end
      child = Class.new(parent) { expirable_by :expires_at, prefix: :new }

      expect(child.new).to respond_to(:new_expired?)
      expect(child.new).not_to respond_to(:old_expired?)
      expect(parent.new).to respond_to(:old_expired?)
      expect(parent.new).not_to respond_to(:new_expired?)
    end

    it "affixes predicates with suffix: and prefix: true too" do
      ActiveRecord::Schema.define do
        create_table :coupons, force: true do |t|
          t.datetime :expires_at
        end
      end

      suffixed = Class.new(TestModel) do
        self.table_name = "coupons"
        include ConcernsOnRails::Expirable

        expirable_by :expires_at, suffix: :term
      end
      field_prefixed = Class.new(TestModel) do
        self.table_name = "coupons"
        include ConcernsOnRails::Expirable

        expirable_by :expires_at, prefix: true
      end

      expect(suffixed.create!(expires_at: 1.hour.ago).expired_term?).to be(true)
      expect(field_prefixed.create!(expires_at: 1.hour.ago).expires_at_expired?).to be(true)
      expect(ApiToken.new).not_to respond_to(:_active?)
    end
  end

  # An after hook vetoing with ActiveRecord::Rollback used to be swallowed by a
  # bare `transaction` that joined the caller's (or expire_all's): the expiry
  # committed, expire! returned true, and expire_all counted the row.
  describe "ActiveRecord::Rollback from after_expire" do
    let(:vetoing) do
      Class.new(TestModel) do
        self.table_name = "api_tokens"
        include ConcernsOnRails::Expirable

        expirable_by

        def after_expire
          raise ActiveRecord::Rollback
        end
      end
    end

    it "expire! returns false and leaves the record (row and memory) unexpired" do
      token = vetoing.create!(value: "t")

      expect(token.expire!).to be(false)
      expect(token.expires_at).to be_nil
      expect(token.reload.expires_at).to be_nil
    end

    it "rolls back inside a caller transaction, keeping the caller's own writes" do
      token = vetoing.create!(value: "t")
      other = vetoing.create!(value: "other")

      ActiveRecord::Base.transaction do
        other.update!(value: "renamed")
        token.expire!
      end

      expect(other.reload.value).to eq("renamed")
      expect(token.reload.expires_at).to be_nil
    end

    it "expire_all raises RecordNotSaved and commits nothing" do
      vetoing.create!(value: "a")
      vetoing.create!(value: "b")

      expect { vetoing.expire_all }.to raise_error(ActiveRecord::RecordNotSaved, /failed to expire/)
      expect(vetoing.where.not(expires_at: nil).count).to eq(0)
    end
  end

  # `update` returning false (validation) used to leave before_expire's own
  # writes committed.
  it "rolls before_expire's side effects back when the write fails validation" do
    klass = Class.new(TestModel) do
      self.table_name = "api_tokens"
      include ConcernsOnRails::Expirable

      expirable_by
      validates :value, presence: true

      def before_expire
        self.class.where(id: id).update_all(value: "touched-by-hook")
      end
    end
    token = klass.create!(value: "ok")
    token.value = nil

    expect(token.expire!).to be(false)
    expect(token.reload.value).to eq("ok")
    expect(token.expires_at).to be_nil
  end

  # nil / blank / unparseable input fired the expiry hooks and then wrote
  # the raw value — which AR casts to nil, i.e. "never expires": the exact
  # opposite of what the caller asked for.
  describe "degenerate expiry times" do
    let(:hooked) do
      Class.new(TestModel) do
        self.table_name = "api_tokens"
        include ConcernsOnRails::Expirable

        expirable_by

        attr_reader :log

        def before_expire
          (@log ||= []) << :before_expire
        end
      end
    end

    [nil, "", "   ", false, []].each do |blank|
      it "expire!(#{blank.inspect}) expires now" do
        token = hooked.create!(value: "t")
        freeze_time do
          expect(token.expire!(blank)).to be(true)
          expect(token.reload.expires_at).to eq(Time.zone.now)
        end
        expect(token).to be_expired
        expect(token.log).to eq(%i[before_expire])
      end
    end

    ["not a time", "2026-13-45 99:99", 42, 1.hour].each do |bad|
      it "expire!(#{bad.inspect}) raises ArgumentError before any hook runs" do
        token = hooked.create!(value: "t")

        expect { token.expire!(bad) }.to raise_error(ArgumentError, /cannot be parsed as a time/)
        expect(token.log).to be_nil
        expect(token.reload.expires_at).to be_nil
      end
    end

    it "still accepts a parseable String" do
      token = hooked.create!(value: "t")

      expect(token.expire!("2020-01-01 00:00:00")).to be(true)
      expect(token.reload.expires_at).to eq(Time.utc(2020, 1, 1))
    end

    it "expire_all(nil) expires now on the fast path" do
      2.times { ApiToken.create!(value: "t") }
      freeze_time do
        expect(ApiToken.expire_all(nil)).to eq(2)
        expect(ApiToken.pluck(:expires_at)).to all(eq(Time.zone.now))
      end
    end

    it "expire_all(nil) expires now on the per-record path" do
      2.times { hooked.create!(value: "t") }
      freeze_time do
        expect(hooked.expire_all(nil)).to eq(2)
        expect(hooked.pluck(:expires_at)).to all(eq(Time.zone.now))
      end
    end

    it "expire_all rejects an unparseable time on both paths before writing anything" do
      ApiToken.create!(value: "t")

      expect { ApiToken.expire_all("garbage") }.to raise_error(ArgumentError, /cannot be parsed as a time/)
      expect { hooked.expire_all("garbage") }.to raise_error(ArgumentError, /cannot be parsed as a time/)
      expect(ApiToken.where.not(expires_at: nil).count).to eq(0)
    end
  end

  describe "batch operations" do
    before do
      ActiveRecord::Schema.define do
        create_table :batch_tokens, force: true do |t|
          t.datetime :expires_at
          t.string :title
        end
      end

      stub_const("BatchToken", Class.new(TestModel) do
        self.table_name = "batch_tokens"
        include ConcernsOnRails::Expirable

        expirable_by
      end)
    end

    it "expires every active record and returns the count" do
      BatchToken.create!(expires_at: 1.day.from_now)
      BatchToken.create!(expires_at: nil)
      done = BatchToken.create!(expires_at: 1.day.ago)

      expect(BatchToken.expire_all).to eq(2)
      expect(BatchToken.expired.count).to eq(3)
      expect(done.reload.expires_at).to be_within(1.second).of(1.day.ago)
    end

    it "is idempotent" do
      BatchToken.create!(expires_at: 1.day.from_now)
      BatchToken.expire_all

      expect(BatchToken.expire_all).to eq(0)
    end

    it "accepts an explicit time" do
      BatchToken.create!(expires_at: nil)
      at = 2.days.ago

      BatchToken.expire_all(at)

      expect(BatchToken.first.expires_at).to be_within(1.second).of(at)
    end

    it "uses the per-record path when expire! is overridden" do
      stub_const("CountingToken", Class.new(TestModel) do
        self.table_name = "batch_tokens"
        include ConcernsOnRails::Expirable

        expirable_by

        cattr_accessor :calls
        self.calls = 0

        def expire!(time = Time.zone.now)
          self.class.calls += 1
          super
        end
      end)
      2.times { CountingToken.create!(expires_at: nil) }

      expect(CountingToken.expire_all).to eq(2)
      expect(CountingToken.calls).to eq(2)
    end

    it "cannot take the fast path when the model has validations — an invalid record rolls the whole batch back" do
      stub_const("ValidatedToken", Class.new(TestModel) do
        self.table_name = "batch_tokens"
        include ConcernsOnRails::Expirable

        expirable_by

        validates :title, presence: true
      end)
      valid = ValidatedToken.create!(title: "ok", expires_at: nil)
      invalid = ValidatedToken.create!(title: "temporary", expires_at: nil)
      invalid.update_column(:title, nil)

      expect { ValidatedToken.expire_all }.to raise_error(ActiveRecord::RecordNotSaved)
      expect(valid.reload.expires_at).to be_nil
      expect(invalid.reload.expires_at).to be_nil
    end

    # Regression: `validate :method` leaves `validators` EMPTY (only `validates`
    # / `validates_with` populate it), so the old `validators.empty?` gate took
    # the fast path and expired invalid rows.
    it "cannot take the fast path when the model has a custom validate method" do
      stub_const("CallbackValidatedToken", Class.new(TestModel) do
        self.table_name = "batch_tokens"
        include ConcernsOnRails::Expirable

        expirable_by
        validate :title_must_be_present

        def title_must_be_present
          errors.add(:title, "can't be blank") if title.blank?
        end
      end)
      valid = CallbackValidatedToken.create!(title: "ok", expires_at: nil)
      invalid = CallbackValidatedToken.create!(title: "temporary", expires_at: nil)
      invalid.update_column(:title, nil)

      expect(CallbackValidatedToken.validators).to be_empty
      expect { CallbackValidatedToken.expire_all }.to raise_error(ActiveRecord::RecordNotSaved)
      expect(valid.reload.expires_at).to be_nil
      expect(invalid.reload.expires_at).to be_nil
    end
  end
  describe "lifecycle hooks (before_expire / after_expire)" do
    let(:hooked) do
      Class.new(TestModel) do
        self.table_name = "api_tokens"
        include ConcernsOnRails::Expirable

        expirable_by

        attr_reader :log

        def before_expire
          (@log ||= []) << :before_expire
        end

        def after_expire
          (@log ||= []) << :after_expire
        end
      end
    end

    it "fires when a write actually expires the record, not when one schedules it" do
      token = hooked.create!
      token.expire!
      expect(token.log).to eq(%i[before_expire after_expire])

      token.instance_variable_set(:@log, nil)
      token.expire!(1.hour.ago) # a past time expires it too
      expect(token.log).to eq(%i[before_expire after_expire])

      # Scheduling is not expiring: after_expire { account.downgrade! } must
      # not run the moment a 14-day trial is set up.
      token.instance_variable_set(:@log, nil)
      token.expire_in!(1.hour)
      expect(token.log).to be_nil
      expect(token.expire!(1.day.from_now)).to be(true)
      expect(token.log).to be_nil

      token.instance_variable_set(:@log, nil)
      token.extend_expiry!(by: 1.day)
      token.clear_expiry!
      expect(token.log).to be_nil
    end

    it "expire_in! rejects a non-duration instead of raising NoMethodError" do
      expect { hooked.create!.expire_in!("soon") }
        .to raise_error(ArgumentError, /expire_in! takes a duration/)
    end

    it "shares one transaction — a raising after_expire rolls the expiry back" do
      failing = Class.new(hooked) do
        def after_expire
          raise "boom"
        end
      end
      token = failing.create!(expires_at: nil)
      expect { token.expire! }.to raise_error("boom")
      expect(token.reload.expires_at).to be_nil
    end

    it "skips after_expire and returns false when the write fails validation" do
      invalid = Class.new(hooked) do
        validates :value, presence: true
      end
      token = invalid.new(value: "ok").tap { |t| t.save!(validate: false) }
      token.value = nil
      expect(token.expire!).to be(false)
      expect(token.log).to eq(%i[before_expire])
      expect(token.reload.expires_at).to be_nil
    end

    it "expire_all takes the per-record path when a hook is overridden, firing it once per record" do
      stub_const("HookedToken", hooked)
      2.times { HookedToken.create!(expires_at: nil) }
      seen = 0
      counting = Class.new(HookedToken) do
        define_method(:after_expire) { seen += 1 }
      end
      expect(counting.expire_all).to eq(2)
      expect(seen).to eq(2)
    end

    it "expire_all still collapses to a single UPDATE when the hooks are not overridden" do
      2.times { ApiToken.create!(expires_at: nil) }
      sql = []
      callback = ->(*, payload) { sql << payload[:sql] if payload[:sql] =~ /\AUPDATE/i }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        expect(ApiToken.expire_all).to eq(2)
      end
      expect(sql.size).to eq(1)
    end
  end

  describe "#expire_in! and #clear_expiry!" do
    it "expire_in!(duration) sets an absolute lifetime from now, whatever the current expiry" do
      token = ApiToken.create!(expires_at: 10.days.from_now)
      travel_to(Time.utc(2026, 7, 1, 12)) { token.expire_in!(15.minutes) }
      expect(token.reload.expires_at).to eq(Time.utc(2026, 7, 1, 12, 15))

      expired = ApiToken.create!(expires_at: 1.day.ago)
      travel_to(Time.utc(2026, 7, 1, 12)) { expired.expire_in!(1.hour) }
      expect(expired.reload.expires_at).to eq(Time.utc(2026, 7, 1, 13))
    end

    it "clear_expiry! makes the record never expire" do
      token = ApiToken.create!(expires_at: 1.day.ago)
      expect(token.expired?).to be(true)
      expect(token.clear_expiry!).to be(true)
      expect(token.reload.expires_at).to be_nil
      expect(token.active?).to be(true)
      expect(token.time_until_expiry).to be_nil
    end
  end
end
