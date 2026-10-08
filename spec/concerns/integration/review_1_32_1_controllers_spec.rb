require "spec_helper"
require "base64"
require "json"

# Regressions caught by the adversarial review of the 1.32.1 audit fixes
# (controller/request side), kept as permanent specs.
describe "1.32.1 review regressions: controllers" do
  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  # ---------------------------------------------------------------- Throttleable
  describe "Throttleable seed" do
    ReviewThrottleRequest = Struct.new(:remote_ip, :headers) unless defined?(ReviewThrottleRequest)

    # A hand-written store with an explicit keyword signature (the documented
    # contract: atomic increment-with-expiry + write with unless_exist), whose
    # increment returns nil on a missing key — exactly the case the seed exists for.
    # The explicit keyword signature IS the case under test.
    let(:strict_store) do
      Class.new do
        def initialize
          @counts = {}
        end

        def increment(key, amount = 1, expires_in: nil)
          @expiry = expires_in
          return nil unless @counts.key?(key)

          @counts[key] += amount
        end

        def write(key, value, expires_in: nil, unless_exist: false) # rubocop:disable Naming/PredicateMethod
          @expiry = expires_in
          return false if unless_exist && @counts.key?(key)

          @counts[key] = value
          true
        end
      end.new
    end

    it "RC-01: a custom store whose #write takes explicit keywords keeps working (no ArgumentError from raw:)" do
      store = strict_store
      klass = Class.new(FakeController) do
        def self.before_action(*); end
        include ConcernsOnRails::Controllers::Throttleable

        throttle_by limit: 2, period: 60
      end
      klass.throttleable_store = store
      c = klass.new
      req = ReviewThrottleRequest.new("1.2.3.4", {})
      c.define_singleton_method(:request) { req }
      c.define_singleton_method(:action_name) { "index" }

      expect { c.send(:enforce_throttles) }.not_to raise_error
      expect(c.response.headers["X-RateLimit-Remaining"]).to eq("1")
    end
  end

  # ------------------------------------------------------------------ Filterable
  describe "Filterable temporal operands" do
    before do
      ActiveRecord::Schema.define do
        create_table :review_events, force: true do |t|
          t.string :title
          t.date :happened_on
          t.datetime :happened_at
        end
      end
      stub_const("ReviewEvent", Class.new(TestModel) { self.table_name = "review_events" })
      ReviewEvent.create!(title: "a", happened_on: Date.new(2026, 1, 1), happened_at: Time.utc(2026, 1, 1))
      ReviewEvent.create!(title: "b", happened_on: Date.new(2026, 6, 1), happened_at: Time.utc(2026, 6, 1))
    end

    let(:controller_class) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable

        filter_by :happened_on, :happened_at, operators: true
      end
    end

    def filtered(params)
      controller_class.new(params: params).filtered(ReviewEvent.all)
    end

    # The fix made a non-temporal operand fail closed on the comparison path;
    # the equality path (direct-where / not / in / not_in) still binds a JSON
    # body's Integer raw against the date column — `happened_on = 1767225600` (an epoch),
    # which PostgreSQL rejects (a 500); MySQL coerces it to a date, SQLite never matches.
    it "RC-02: a JSON-body Integer on a date column's equality filter is not bound raw (fails closed like gte)" do
      expect(filtered(happened_on_gte: 1_767_225_600).to_a).to be_empty # the fixed comparison path
      rel = filtered(happened_on: 1_767_225_600)
      expect(rel.to_sql).not_to include("1767225600")
      rel_in = filtered(happened_on_in: [1_767_225_600])
      expect(rel_in.to_sql).not_to include("1767225600")
    end

    # Rails 6.0–7.0 only: a >128-char String is now DROPPED from the equality
    # list ("no stored value equals it"), so `not` answers every non-NULL row;
    # a 128-char garbage String (cast nil) — and the same 129-char one on 7.1+
    # — answers none. One request, two answers by length/Rails line.
    it "RC-03: `not` with an unparseable date answers the same for a 128- and a 129-character operand" do
      short = filtered(happened_on_not: "x" * 128).pluck(:title).sort
      long = filtered(happened_on_not: "x" * 129).pluck(:title).sort
      expect(long).to eq(short)
    end

    # `type: :date` on a with: lambda: an unreadable String now reaches the
    # lambda as nil (filterable_lambda_cast), but a JSON-body Integer still
    # reaches it unchanged — the lambda's `where("happened_on >= ?", v)`
    # repeats PARAM-03 (every row on SQLite, a 500 on PostgreSQL).
    it "RC-04: a with: lambda declared `type: :date` never receives a non-date Integer" do
      received = []
      klass = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable

        filter_by :since, with: lambda { |rel, v|
          received << v
          rel.where("happened_on >= ?", v)
        }, type: :date
      end
      klass.new(params: { since: 1_767_225_600 }).filtered(ReviewEvent.all).to_a
      expect(received).to all(satisfy { |v| v.nil? || v.is_a?(Date) })
    end
  end

  # ----------------------------------------------------------- CursorPaginatable
  describe "Localizable separator equivalence" do
    ReviewLocaleRequest = Struct.new(:headers) unless defined?(ReviewLocaleRequest)

    around do |example|
      saved = [I18n.available_locales, I18n.default_locale]
      I18n.available_locales = %i[en pt_BR pt-BR]
      I18n.default_locale = :en
      example.run
    ensure
      I18n.available_locales = saved[0]
      I18n.default_locale = saved[1]
    end

    def locale_controller(accept_language: nil, params: {})
      request = accept_language && ReviewLocaleRequest.new({ "Accept-Language" => accept_language })
      klass = Class.new(FakeController) do
        def self.around_action(*); end
        include ConcernsOnRails::Controllers::Localizable

        localizable available: %i[en pt_BR pt-BR], default: :en
        define_method(:request) { request }
      end
      klass.new(params: params)
    end

    it "RC-06: an exact spelling still wins over its separator twin (header and param)" do
      expect(locale_controller(accept_language: "pt-BR").resolved_locale).to eq(:'pt-BR')
      expect(locale_controller(params: { locale: "pt-BR" }).resolved_locale).to eq(:'pt-BR')
    end
  end
end
