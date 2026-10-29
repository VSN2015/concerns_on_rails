require "spec_helper"

# Audit 2026-10-29 (STATE-2): expire!/expire_in! decided "this write only
# schedules" with `time.to_time > Time.zone.now`. On a `date` column the
# written value is a Date, and Date#to_time is midnight in the PROCESS zone
# (ENV["TZ"]), so with the process zone behind Time.zone today's date read as
# later than now: the record was `expired?` afterwards but before_expire /
# after_expire never fired. The decision now uses the predicates' own bound
# (Support::TimeValue.predicate_bound): the hooks fire whenever the written
# value makes the record expired.
describe "Expirable hooks on a date column, whatever the process time zone" do
  around do |example|
    old_tz = ENV.fetch("TZ", nil)
    old_zone = Time.zone
    begin
      example.run
    ensure
      ENV["TZ"] = old_tz
      Time.zone = old_zone
    end
  end

  before do
    ActiveRecord::Schema.define do
      create_table :edh_tokens, force: true do |t|
        t.date :expires_on
        t.datetime :expires_at
      end
    end
  end

  after do
    ActiveRecord::Base.connection.drop_table(:edh_tokens, if_exists: true)
  end

  def model_for(column)
    klass = Class.new(TestModel) do
      self.table_name = "edh_tokens"
      include ConcernsOnRails::Expirable

      attr_accessor :fired

      def before_expire
        (self.fired ||= []) << :before_expire
      end

      def after_expire
        (self.fired ||= []) << :after_expire
      end
    end
    klass.expirable_by(column)
    klass
  end

  let(:date_model) { model_for(:expires_on) }
  let(:datetime_model) { model_for(:expires_at) }
  # 01:00 UTC Oct 29: still Oct 28 in Los Angeles, already Oct 29 in UTC.
  let(:clock) { Time.utc(2026, 10, 29, 1, 0, 0) }

  { "behind Time.zone" => %w[America/Los_Angeles UTC],
    "ahead of Time.zone" => %w[Asia/Tokyo UTC],
    "equal to Time.zone" => %w[UTC UTC] }.each do |label, (process_tz, app_zone)|
    context "with the process zone #{label}" do
      before do
        ENV["TZ"] = process_tz
        Time.zone = app_zone
      end

      it "fires the hooks when expire! writes today's date" do
        travel_to(clock) do
          token = date_model.create!

          expect(token.expire!).to be(true)
          expect(token.expired?).to be(true)
          expect(token.fired).to eq(%i[before_expire after_expire])
        end
      end

      it "fires the hooks when expire_in!(0) writes today's date" do
        travel_to(clock) do
          token = date_model.create!

          expect(token.expire_in!(0)).to be(true)
          expect(token.expired?).to be(true)
          expect(token.fired).to eq(%i[before_expire after_expire])
        end
      end

      it "fires the hooks when expire_in! writes a date that is already expired" do
        travel_to(clock) do
          token = date_model.create!

          expect(token.expire_in!(-2.days)).to be(true)
          expect(token.expired?).to be(true)
          expect(token.fired).to eq(%i[before_expire after_expire])
        end
      end

      it "fires nothing when expire_in! only schedules a later date" do
        travel_to(clock) do
          token = date_model.create!

          expect(token.expire_in!(3.days)).to be(true)
          expect(token.expired?).to be(false)
          expect(token.fired).to be_nil
        end
      end

      it "fires nothing when expire!(future date) only schedules" do
        travel_to(clock) do
          token = date_model.create!

          expect(token.expire!(Time.zone.now + 2.days)).to be(true)
          expect(token.expired?).to be(false)
          expect(token.fired).to be_nil
        end
      end

      it "still fires the hooks on a datetime column for now, and nothing for a future time" do
        travel_to(clock) do
          now_token = datetime_model.create!
          later_token = datetime_model.create!

          expect(now_token.expire!).to be(true)
          expect(now_token.fired).to eq(%i[before_expire after_expire])
          expect(later_token.expire_in!(15.minutes)).to be(true)
          expect(later_token.fired).to be_nil
        end
      end
    end
  end
end
