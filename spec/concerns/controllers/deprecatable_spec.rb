require "spec_helper"

describe ConcernsOnRails::Controllers::Deprecatable do
  # before_action is stubbed so including the concern does not blow up outside a
  # real Rails stack; specs then drive #apply_api_deprecations directly.
  let(:base_class) do
    Class.new(FakeController) do
      def self.before_action(*); end
    end
  end

  def deprecatable_class(&declaration)
    Class.new(base_class) do
      include ConcernsOnRails::Controllers::Deprecatable

      class_eval(&declaration) if declaration
    end
  end

  def instance(klass, action: "index")
    c = klass.new
    c.define_singleton_method(:action_name) { action }
    c
  end

  # Build + run in one step for the common case.
  def run(action: "index", &declaration)
    c = instance(deprecatable_class(&declaration), action: action)
    c.apply_api_deprecations
    c
  end

  describe "Deprecation header" do
    it "emits the RFC 9745 structured-fields Date item (@<unix>) of deprecated_at" do
      c = run { deprecate_actions :index, deprecated_at: "2026-01-15" }

      expect(c.response.headers["Deprecation"]).to eq("@1768435200")
    end

    it "emits the literal string \"true\" under header_format: :legacy" do
      c = run { deprecate_actions :index, deprecated_at: "2026-01-15", header_format: :legacy }

      expect(c.response.headers["Deprecation"]).to eq("true")
    end

    it "parses a String with an explicit zone and normalises to UTC" do
      c = run { deprecate_actions :index, deprecated_at: "2026-12-31T00:00:00Z" }

      expect(c.response.headers["Deprecation"]).to eq("@1798675200")
    end

    it "treats a bare Date as midnight UTC (sunset/deprecation is an instant, not end-of-day)" do
      c = run { deprecate_actions :index, deprecated_at: Date.new(2026, 1, 15) }

      expect(c.response.headers["Deprecation"]).to eq("@1768435200")
    end

    it "accepts a Time and a DateTime, normalising both to UTC" do
      from_time = run { deprecate_actions :index, deprecated_at: Time.utc(2026, 1, 15) }
      from_dt = run { deprecate_actions :index, deprecated_at: DateTime.new(2026, 1, 15, 0, 0, 0, "+00:00") }

      expect(from_time.response.headers["Deprecation"]).to eq("@1768435200")
      expect(from_dt.response.headers["Deprecation"]).to eq("@1768435200")
    end

    it "accepts an ActiveSupport::TimeWithZone (Time.current-style values)" do
      zone = ActiveSupport::TimeZone["Asia/Ho_Chi_Minh"]
      c = run { deprecate_actions :index, deprecated_at: zone.parse("2026-01-15 07:00:00") }

      expect(c.response.headers["Deprecation"]).to eq("@1768435200")
    end
  end

  describe "Sunset header" do
    it "emits an IMF-fixdate (HTTP-date in GMT) via httpdate, not ISO 8601" do
      c = run { deprecate_actions :index, deprecated_at: "2025-01-01", sunset_at: "2026-12-31" }

      expect(c.response.headers["Sunset"]).to eq("Thu, 31 Dec 2026 00:00:00 GMT")
    end

    it "is omitted when no sunset_at is configured" do
      c = run { deprecate_actions :index, deprecated_at: "2025-01-01" }

      expect(c.response.headers).not_to have_key("Sunset")
    end
  end

  describe "Link header" do
    it "emits only the deprecation rel when just link: is given" do
      c = run { deprecate_actions :index, deprecated_at: "2025-01-01", link: "https://docs.example.com/v1" }

      expect(c.response.headers["Link"]).to eq('<https://docs.example.com/v1>; rel="deprecation"')
    end

    it "emits only the successor rel when just successor: is given" do
      c = run { deprecate_actions :index, deprecated_at: "2025-01-01", successor: "https://api.example.com/v2" }

      expect(c.response.headers["Link"]).to eq('<https://api.example.com/v2>; rel="successor-version"')
    end

    it "joins both rels with \", \" when link: and successor: are both given" do
      c = run do
        deprecate_actions :index, deprecated_at: "2025-01-01",
                                  link: "https://docs.example.com/v1", successor: "https://api.example.com/v2"
      end

      expect(c.response.headers["Link"]).to eq(
        '<https://docs.example.com/v1>; rel="deprecation", <https://api.example.com/v2>; rel="successor-version"'
      )
    end

    it "emits no Link header when neither URL is configured" do
      c = run { deprecate_actions :index, deprecated_at: "2025-01-01" }

      expect(c.response.headers).not_to have_key("Link")
    end

    it "appends to (never clobbers) a Link header already on the response" do
      c = instance(deprecatable_class { deprecate_actions :index, deprecated_at: "2025-01-01", link: "https://docs.example.com/v1" })
      c.response.set_header("Link", '<https://api.example.com/orders?page=2>; rel="next"')
      c.apply_api_deprecations

      expect(c.response.headers["Link"]).to eq(
        '<https://api.example.com/orders?page=2>; rel="next", <https://docs.example.com/v1>; rel="deprecation"'
      )
    end
  end

  describe "action scoping" do
    it "applies a catch-all rule (no positional actions) to every action" do
      klass = deprecatable_class { deprecate_actions deprecated_at: "2025-01-01" }

      %w[index show create].each do |action|
        c = instance(klass, action: action)
        c.apply_api_deprecations
        expect(c.response.headers["Deprecation"]).to eq("@1735689600")
      end
    end

    it "applies a positional rule only to the listed actions" do
      klass = deprecatable_class { deprecate_actions :show, deprecated_at: "2025-01-01" }

      shown = instance(klass, action: "show")
      indexed = instance(klass, action: "index")
      shown.apply_api_deprecations
      indexed.apply_api_deprecations

      expect(shown.response.headers).to have_key("Deprecation")
      expect(indexed.response.headers).not_to have_key("Deprecation")
    end

    it "normalises action names to strings" do
      klass = deprecatable_class { deprecate_actions "show", deprecated_at: "2025-01-01" }
      c = instance(klass, action: :show)
      c.apply_api_deprecations

      expect(c.response.headers).to have_key("Deprecation")
    end

    it "does nothing (returns nil) when no rule matches the action" do
      c = instance(deprecatable_class { deprecate_actions :show, deprecated_at: "2025-01-01" }, action: "index")

      expect(c.apply_api_deprecations).to be_nil
      expect(c.response.headers).to be_empty
    end
  end

  describe "last match wins" do
    let(:klass) do
      deprecatable_class do
        # Catch-all V1 deprecation, then an action-specific override for :show.
        deprecate_actions deprecated_at: "2025-01-01", sunset_at: "2026-01-15"
        deprecate_actions :show, deprecated_at: "2025-01-01", sunset_at: "2026-12-31"
      end
    end

    it "lets the later action-specific rule win for the action it names" do
      c = instance(klass, action: "show")
      c.apply_api_deprecations

      expect(c.response.headers["Sunset"]).to eq("Thu, 31 Dec 2026 00:00:00 GMT")
    end

    it "still applies the catch-all to actions the override does not name" do
      c = instance(klass, action: "index")
      c.apply_api_deprecations

      expect(c.response.headers["Sunset"]).to eq("Thu, 15 Jan 2026 00:00:00 GMT")
    end

    it "emits exactly one Deprecation header even when two rules match (last wins)" do
      klass = deprecatable_class do
        deprecate_actions :index, deprecated_at: "2025-01-01"
        deprecate_actions :index, deprecated_at: "2026-01-15"
      end
      c = instance(klass, action: "index")
      c.apply_api_deprecations

      expect(c.response.headers["Deprecation"]).to eq("@1768435200")
    end
  end

  describe "inheritance" do
    it "inherits parent rules and can append its own" do
      parent = deprecatable_class { deprecate_actions deprecated_at: "2025-01-01", sunset_at: "2026-01-15" }
      child = Class.new(parent) do
        deprecate_actions :show, deprecated_at: "2025-01-01", sunset_at: "2026-12-31"
      end

      # Parent rule still applies to its own instances...
      pc = instance(parent, action: "show")
      pc.apply_api_deprecations
      expect(pc.response.headers["Sunset"]).to eq("Thu, 15 Jan 2026 00:00:00 GMT")

      # ...and the child sees both, with the appended rule winning for :show.
      cc = instance(child, action: "show")
      cc.apply_api_deprecations
      expect(cc.response.headers["Sunset"]).to eq("Thu, 31 Dec 2026 00:00:00 GMT")

      # An action the child did not override still gets the inherited catch-all.
      ci = instance(child, action: "index")
      ci.apply_api_deprecations
      expect(ci.response.headers["Sunset"]).to eq("Thu, 15 Jan 2026 00:00:00 GMT")
    end

    it "does not mutate the parent's rules array when the child declares more" do
      parent = deprecatable_class { deprecate_actions deprecated_at: "2025-01-01" }
      Class.new(parent) { deprecate_actions :show, deprecated_at: "2025-01-01" }

      expect(parent.deprecatable_rules.size).to eq(1)
    end
  end

  describe "410 Gone enforcement (after_sunset: :gone)" do
    def gone_class
      deprecatable_class do
        deprecate_actions :index, deprecated_at: "2025-01-01", sunset_at: "2026-01-15", after_sunset: :gone
      end
    end

    it "does not block strictly before the sunset instant" do
      travel_to Time.utc(2026, 1, 14, 23, 59, 59) do
        c = instance(gone_class, action: "index")
        expect(c.apply_api_deprecations).to be_nil
        expect(c.rendered).to be_nil
        # Signalling headers are still emitted before the cut-off.
        expect(c.response.headers["Deprecation"]).to eq("@1735689600")
        expect(c.response.headers["Sunset"]).to eq("Thu, 15 Jan 2026 00:00:00 GMT")
      end
    end

    it "blocks AT the boundary instant (inclusive)" do
      travel_to Time.utc(2026, 1, 15, 0, 0, 0) do
        c = instance(gone_class, action: "index")
        c.apply_api_deprecations

        expect(c.rendered[:status]).to eq(:gone)
        expect(c.rendered[:json][:error][:code]).to eq("endpoint_sunset")
      end
    end

    it "blocks after the boundary instant" do
      travel_to Time.utc(2026, 1, 16, 0, 0, 0) do
        c = instance(gone_class, action: "index")
        c.apply_api_deprecations

        expect(c.rendered[:status]).to eq(:gone)
      end
    end

    it "still emits the deprecation headers on the 410 (self-documenting failure)" do
      travel_to Time.utc(2026, 6, 1) do
        c = instance(gone_class, action: "index")
        c.apply_api_deprecations

        expect(c.rendered[:status]).to eq(:gone)
        expect(c.response.headers["Deprecation"]).to eq("@1735689600")
        expect(c.response.headers["Sunset"]).to eq("Thu, 15 Jan 2026 00:00:00 GMT")
      end
    end

    it "names the sunset httpdate in the 410 message" do
      travel_to Time.utc(2026, 6, 1) do
        c = instance(gone_class, action: "index")
        c.apply_api_deprecations

        expect(c.rendered[:json][:error][:message]).to eq("This endpoint was sunset on Thu, 15 Jan 2026 00:00:00 GMT.")
      end
    end

    it "never blocks under the default after_sunset: :headers, however long past sunset" do
      klass = deprecatable_class do
        deprecate_actions :index, deprecated_at: "2025-01-01", sunset_at: "2026-01-15"
      end

      travel_to Time.utc(2030, 1, 1) do
        c = instance(klass, action: "index")
        expect(c.apply_api_deprecations).to be_nil
        expect(c.rendered).to be_nil
        expect(c.response.headers["Sunset"]).to eq("Thu, 15 Jan 2026 00:00:00 GMT")
      end
    end
  end

  describe "410 response rendering" do
    it "delegates to Respondable's render_error when the controller includes it" do
      klass = Class.new(base_class) do
        include ConcernsOnRails::Controllers::Respondable
        include ConcernsOnRails::Controllers::Deprecatable

        deprecate_actions :index, deprecated_at: "2025-01-01", sunset_at: "2026-01-15", after_sunset: :gone
      end

      travel_to Time.utc(2026, 6, 1) do
        c = instance(klass, action: "index")
        c.apply_api_deprecations

        expect(c.rendered[:status]).to eq(:gone)
        expect(c.rendered[:json][:success]).to be(false)
        expect(c.rendered[:json][:error][:code]).to eq("endpoint_sunset")
        expect(c.rendered[:json][:error][:message]).to include("Thu, 15 Jan 2026 00:00:00 GMT")
      end
    end

    it "uses the inline envelope when Respondable is not present" do
      klass = deprecatable_class do
        deprecate_actions :index, deprecated_at: "2025-01-01", sunset_at: "2026-01-15", after_sunset: :gone
      end

      travel_to Time.utc(2026, 6, 1) do
        c = instance(klass, action: "index")
        c.apply_api_deprecations

        expect(c.rendered[:status]).to eq(:gone)
        expect(c.rendered[:json]).to eq(
          success: false,
          error: { message: "This endpoint was sunset on Thu, 15 Jan 2026 00:00:00 GMT.", code: "endpoint_sunset" }
        )
      end
    end
  end

  describe "#on_deprecated_access instrumentation" do
    it "publishes a deprecated_endpoint.concerns_on_rails event with the rule payload" do
      c = instance(deprecatable_class { deprecate_actions :index, deprecated_at: "2025-01-01", sunset_at: "2026-01-15" })
      c.define_singleton_method(:controller_path) { "api/v1/orders" }

      events = []
      subscriber = ->(*args) { events << ActiveSupport::Notifications::Event.new(*args) }
      ActiveSupport::Notifications.subscribed(subscriber, "deprecated_endpoint.concerns_on_rails") do
        c.apply_api_deprecations
      end

      expect(events.size).to eq(1)
      payload = events.first.payload
      expect(payload[:controller]).to eq("api/v1/orders")
      expect(payload[:action]).to eq("index")
      expect(payload[:deprecated_at].to_i).to eq(1_735_689_600)
      expect(payload[:sunset_at].to_i).to eq(1_768_435_200)
    end

    it "instance_execs notify: in the controller context (can read controller state)" do
      klass = deprecatable_class do
        attr_reader :captured_tenant

        deprecate_actions :index, deprecated_at: "2025-01-01", notify: -> { @captured_tenant = tenant_id }

        def tenant_id
          "acme"
        end
      end
      c = instance(klass, action: "index")
      c.apply_api_deprecations

      expect(c.captured_tenant).to eq("acme")
    end

    it "lets a raising notify propagate (a broken metrics hook must be loud)" do
      klass = deprecatable_class do
        deprecate_actions :index, deprecated_at: "2025-01-01", notify: -> { raise "metrics down" }
      end
      c = instance(klass, action: "index")

      expect { c.apply_api_deprecations }.to raise_error("metrics down")
    end

    it "does not fire notify or instrument when no rule matches" do
      klass = deprecatable_class do
        deprecate_actions :show, deprecated_at: "2025-01-01", notify: -> { raise "should not run" }
      end
      c = instance(klass, action: "index")

      expect { c.apply_api_deprecations }.not_to raise_error
    end
  end

  describe "predicates" do
    describe "#deprecation_active?" do
      it "is true when a rule matches the current action" do
        c = instance(deprecatable_class { deprecate_actions :index, deprecated_at: "2025-01-01" }, action: "index")

        expect(c.deprecation_active?).to be(true)
      end

      it "is false when no rule matches the current action" do
        c = instance(deprecatable_class { deprecate_actions :show, deprecated_at: "2025-01-01" }, action: "index")

        expect(c.deprecation_active?).to be(false)
      end
    end

    describe "#sunset_passed?" do
      let(:klass) do
        deprecatable_class { deprecate_actions :index, deprecated_at: "2025-01-01", sunset_at: "2026-01-15" }
      end

      it "is false before the sunset instant" do
        travel_to Time.utc(2026, 1, 14, 23, 59, 59) do
          expect(instance(klass, action: "index").sunset_passed?).to be(false)
        end
      end

      it "is true at and after the sunset instant (inclusive)" do
        travel_to Time.utc(2026, 1, 15, 0, 0, 0) do
          expect(instance(klass, action: "index").sunset_passed?).to be(true)
        end
      end

      it "is false when the matching rule has no sunset_at" do
        c = instance(deprecatable_class { deprecate_actions :index, deprecated_at: "2025-01-01" }, action: "index")

        expect(c.sunset_passed?).to be(false)
      end

      it "is false when no rule matches the action" do
        c = instance(klass, action: "create")

        expect(c.sunset_passed?).to be(false)
      end
    end
  end

  describe "macro-time validation" do
    def declare(&block)
      Class.new(base_class) do
        include ConcernsOnRails::Controllers::Deprecatable

        class_eval(&block)
      end
    end

    it "rejects a missing deprecated_at" do
      expect { declare { deprecate_actions :index } }.to raise_error(ArgumentError, /:deprecated_at is required/)
    end

    it "rejects an unparseable deprecated_at String" do
      expect do
        declare { deprecate_actions :index, deprecated_at: "definitely-not-a-date" }
      end.to raise_error(ArgumentError, /:deprecated_at could not be parsed/)
    end

    it "rejects a deprecated_at of an unsupported type" do
      expect do
        declare { deprecate_actions :index, deprecated_at: 1_700_000_000 }
      end.to raise_error(ArgumentError, /:deprecated_at could not be parsed/)
    end

    it "rejects an unparseable sunset_at" do
      expect do
        declare { deprecate_actions :index, deprecated_at: "2025-01-01", sunset_at: "soon" }
      end.to raise_error(ArgumentError, /:sunset_at could not be parsed/)
    end

    it "rejects a sunset_at earlier than deprecated_at" do
      expect do
        declare { deprecate_actions :index, deprecated_at: "2026-06-01", sunset_at: "2026-01-01" }
      end.to raise_error(ArgumentError, /:sunset_at must be on or after :deprecated_at/)
    end

    it "rejects a header_format outside [:rfc9745, :legacy]" do
      expect { deprecatable_class { deprecate_actions deprecated_at: "2026-01-15", header_format: :boolean } }
        .to raise_error(ArgumentError, /:header_format must be one of rfc9745, legacy/)
    end

    it "rejects an after_sunset value outside [:headers, :gone]" do
      expect do
        declare { deprecate_actions :index, deprecated_at: "2025-01-01", after_sunset: :archive }
      end.to raise_error(ArgumentError, /:after_sunset must be one of/)
    end

    it "rejects after_sunset: :gone without a sunset_at" do
      expect do
        declare { deprecate_actions :index, deprecated_at: "2025-01-01", after_sunset: :gone }
      end.to raise_error(ArgumentError, /after_sunset: :gone requires :sunset_at/)
    end

    it "rejects a blank link" do
      expect do
        declare { deprecate_actions :index, deprecated_at: "2025-01-01", link: "  " }
      end.to raise_error(ArgumentError, /:link must be a non-blank String/)
    end

    it "rejects a non-String link" do
      expect do
        declare { deprecate_actions :index, deprecated_at: "2025-01-01", link: 123 }
      end.to raise_error(ArgumentError, /:link must be a non-blank String/)
    end

    it "rejects a blank successor" do
      expect do
        declare { deprecate_actions :index, deprecated_at: "2025-01-01", successor: "" }
      end.to raise_error(ArgumentError, /:successor must be a non-blank String/)
    end

    it "rejects a non-callable notify" do
      expect do
        declare { deprecate_actions :index, deprecated_at: "2025-01-01", notify: "ping" }
      end.to raise_error(ArgumentError, /:notify must be callable/)
    end

    it "all ArgumentError messages are prefixed with the fully qualified concern name" do
      expect { declare { deprecate_actions :index } }.to raise_error(
        ArgumentError, /\AConcernsOnRails::Controllers::Deprecatable:/
      )
    end
  end
end
