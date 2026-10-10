require "spec_helper"

# Audit 2026-10-10 (STATE-9, and the expire! half of STATE-6): expiring
# must never push an existing expiry LATER.
#   * expire_all(future) wrote `future` into every currently-live row, so a
#     token due to expire in 5 minutes was extended to the requested hour —
#     mass revocation lengthened credentials.
#   * expire! on an already-expired record rewrote its expiry to now (later)
#     and fired before/after_expire again, while expire_all skips such rows.
describe "Expirable never pushes an existing expiry later" do
  before do
    ActiveRecord::Schema.define do
      create_table :ene_tokens, force: true do |t|
        t.string :value
        t.datetime :expires_at
      end
    end
  end

  after do
    ActiveRecord::Base.connection.drop_table(:ene_tokens, if_exists: true)
  end

  let(:model) do
    Class.new(TestModel) do
      self.table_name = "ene_tokens"
      include ConcernsOnRails::Expirable

      expirable_by :expires_at
    end
  end

  # Overriding a hook moves expire_all to the per-record path.
  let(:hooked) do
    Class.new(model) do
      attr_reader :log

      def before_expire
        (@log ||= []) << :before_expire
      end

      def after_expire
        (@log ||= []) << :after_expire
      end
    end
  end

  let(:now) { Time.utc(2026, 10, 10, 12) }

  describe ".expire_all(time)" do
    %i[model hooked].each do |which|
      context "on the #{which == :model ? 'single-UPDATE' : 'per-record'} path" do
        let(:klass) { public_send(which) }

        it "leaves an earlier expiry alone when the requested time is in the future" do
          travel_to(now) do
            soon = klass.create!(expires_at: now + 1.hour)
            never = klass.create!(expires_at: nil)
            late = klass.create!(expires_at: now + 1.month)

            expect(klass.expire_all(now + 1.week)).to eq(2)
            expect(soon.reload.expires_at).to eq(now + 1.hour)
            expect(never.reload.expires_at).to eq(now + 1.week)
            expect(late.reload.expires_at).to eq(now + 1.week)
          end
        end

        it "still expires every live row now, and leaves already-expired rows alone" do
          travel_to(now) do
            live = klass.create!(expires_at: now + 1.hour)
            never = klass.create!(expires_at: nil)
            gone = klass.create!(expires_at: now - 1.day)

            expect(klass.expire_all).to eq(2)
            expect(live.reload.expires_at).to eq(now)
            expect(never.reload.expires_at).to eq(now)
            expect(gone.reload.expires_at).to eq(now - 1.day)
          end
        end
      end
    end
  end

  describe "#expire!" do
    it "keeps an already-expired record's expiry and fires no hook" do
      token = hooked.create!
      travel_to(Time.utc(2026, 1, 1, 10)) { token.expire! }
      expect(token.log).to eq(%i[before_expire after_expire])
      token.instance_variable_set(:@log, nil)
      original = token.reload.expires_at

      travel_to(now) do
        expect(token.expire!).to be(true)
        expect(token.log).to be_nil
      end
      expect(token.reload.expires_at).to eq(original)
    end

    it "does not push a scheduled expiry later" do
      travel_to(now) do
        token = hooked.create!(expires_at: now + 1.hour)

        expect(token.expire!(now + 1.week)).to be(true)
        expect(token.reload.expires_at).to eq(now + 1.hour)
      end
    end

    it "still brings an expiry forward, firing the hooks when that expires the record" do
      travel_to(now) do
        token = hooked.create!(expires_at: now + 1.week)

        expect(token.expire!(now + 1.hour)).to be(true)
        expect(token.reload.expires_at).to eq(now + 1.hour)
        expect(token.log).to be_nil # scheduling, not expiring

        expect(token.expire!).to be(true)
        expect(token.reload.expires_at).to eq(now)
        expect(token.log).to eq(%i[before_expire after_expire])
      end
    end

    it "still writes an expiry assigned but not yet saved" do
      travel_to(now) do
        token = model.create!(expires_at: now + 1.day)
        token.expires_at = now - 1.hour

        expect(token.expire!).to be(true)
        expect(token.reload.expires_at).to eq(now)
      end
    end
  end

  describe "#expire_in!" do
    it "still sets an absolute lifetime from now, whatever the current expiry" do
      travel_to(now) do
        token = model.create!(expires_at: now + 5.minutes)
        token.expire_in!(1.hour)
        expect(token.reload.expires_at).to eq(now + 1.hour)

        expired = model.create!(expires_at: now - 1.day)
        expired.expire_in!(1.hour)
        expect(expired.reload.expires_at).to eq(now + 1.hour)
      end
    end
  end
end
