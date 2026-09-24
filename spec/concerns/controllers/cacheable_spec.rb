require "spec_helper"
require "support/integration_harness"

describe ConcernsOnRails::Controllers::Cacheable do
  # A minimal resource that quacks like an ActiveRecord model for ETag /
  # Last-Modified derivation, without a database.
  class FakeResource
    attr_reader :id, :updated_at

    def initialize(id:, updated_at:)
      @id = id
      @updated_at = updated_at
    end

    def cache_key_with_version
      "fake_resources/#{id}-#{updated_at.to_i}"
    end
  end

  # format/query_string are here so the :format and :query etag_with presets
  # actually fold a VALUE; without them both lambdas' respond_to? guards
  # short-circuit and only their Vary side gets exercised.
  FakeCacheRequest = Struct.new(:request_method, :headers, :format, :query_string) unless defined?(FakeCacheRequest)

  let(:base_class) do
    Class.new(FakeController) do
      def self.before_action(*); end
      def self.after_action(*); end
    end
  end

  def cacheable_class(&declaration)
    Class.new(base_class) do
      include ConcernsOnRails::Controllers::Cacheable

      class_eval(&declaration) if declaration
    end
  end

  def instance(klass, action: "show", method: "GET", headers: {}, params: {}, format: nil, query_string: nil)
    controller = klass.new(params: params)
    request = FakeCacheRequest.new(method, headers, format, query_string)
    controller.define_singleton_method(:request) { request }
    controller.define_singleton_method(:action_name) { action }
    controller
  end

  let(:resource) { FakeResource.new(id: 7, updated_at: Time.utc(2026, 1, 1, 12, 0, 0)) }
  let(:etag) { %(W/"#{Digest::MD5.hexdigest("fake_resources/7-#{Time.utc(2026, 1, 1, 12, 0, 0).to_i}")}") }

  describe "#apply_http_cache_headers (Cache-Control / Vary policy)" do
    it "emits public max-age and Vary on a matching action" do
      c = instance(cacheable_class { http_cache_actions :show, max_age: 300, visibility: :public, vary: "Accept" })
      c.apply_http_cache_headers

      expect(c.response.headers["Cache-Control"]).to eq("public, max-age=300")
      expect(c.response.headers["Vary"]).to eq("Accept")
    end

    it "emits nothing for a non-matching action" do
      c = instance(cacheable_class { http_cache_actions :index, max_age: 300 }, action: "show")
      c.apply_http_cache_headers

      expect(c.response.headers["Cache-Control"]).to be_nil
    end

    it "treats a rule with no actions as a catch-all" do
      c = instance(cacheable_class { http_cache_actions max_age: 60 }, action: "whatever")
      c.apply_http_cache_headers

      expect(c.response.headers["Cache-Control"]).to eq("private, max-age=60")
    end

    it "lets the last matching rule win" do
      klass = cacheable_class do
        http_cache_actions max_age: 60
        http_cache_actions :show, no_store: true
      end
      c = instance(klass, action: "show")
      c.apply_http_cache_headers

      expect(c.response.headers["Cache-Control"]).to eq("no-store")
    end

    it "appends to a pre-existing Vary header without clobbering it" do
      c = instance(cacheable_class { http_cache_actions :show, vary: %w[Accept Accept-Language] })
      c.response.set_header("Vary", "Origin")
      c.apply_http_cache_headers

      expect(c.response.headers["Vary"]).to eq("Origin, Accept, Accept-Language")
    end

    # Pre-fix the positive policy was emitted for every method and status, so a
    # catch-all `visibility: :public, max_age:` told shared caches to store a
    # POST's 201, an action-rendered 500, or a redirect for the full max-age.
    context "positive freshness is limited to GET/HEAD with a cacheable status" do
      let(:klass) { cacheable_class { http_cache_actions visibility: :public, max_age: 300, stale_while_revalidate: 60 } }

      it "is not emitted for unsafe methods" do
        %w[POST PUT PATCH DELETE].each do |method|
          c = instance(klass, method: method)
          c.apply_http_cache_headers
          expect(c.response.headers["Cache-Control"]).to be_nil, "#{method} got #{c.response.headers['Cache-Control']}"
        end
      end

      it "is not emitted for error, redirect or otherwise non-cacheable statuses the action rendered itself" do
        [201, 202, 301, 302, 400, 401, 403, 404, 410, 422, 500, 503].each do |status|
          c = instance(klass)
          c.response.status = status
          c.apply_http_cache_headers
          expect(c.response.headers["Cache-Control"]).to be_nil, "#{status} got #{c.response.headers['Cache-Control']}"
        end
      end

      it "is emitted for GET and HEAD with 200, 203, 204, 206 and 304" do
        %w[GET HEAD].product([200, 203, 204, 206, 304]).each do |method, status|
          c = instance(klass, method: method)
          c.response.status = status
          c.apply_http_cache_headers
          expect(c.response.headers["Cache-Control"]).to eq("public, max-age=300, stale-while-revalidate=60")
        end
      end

      it "keeps no-store unconditional" do
        klass = cacheable_class { http_cache_actions no_store: true }
        [["POST", 201], ["GET", 500], ["DELETE", 404]].each do |method, status|
          c = instance(klass, method: method)
          c.response.status = status
          c.apply_http_cache_headers
          expect(c.response.headers["Cache-Control"]).to eq("no-store")
        end
      end
    end

    it "de-duplicates Vary case-insensitively, keeping the first spelling" do
      c = instance(cacheable_class { http_cache_actions :show, vary: %w[Accept Accept-Language] })
      c.response.set_header("Vary", "accept")
      c.apply_http_cache_headers

      expect(c.response.headers["Vary"]).to eq("accept, Accept-Language")
    end

    it "leaves Vary: * alone" do
      klass = cacheable_class do
        http_cache_actions :show, vary: "Accept"
        etag_with :locale
      end
      c = instance(klass)
      c.response.set_header("Vary", "*")
      c.stale_resource?(resource)
      c.apply_http_cache_headers

      expect(c.response.headers["Vary"]).to eq("*")
    end

    it "assembles must-revalidate and stale-while-revalidate" do
      c = instance(cacheable_class do
        http_cache_actions :show, max_age: 30, must_revalidate: true, stale_while_revalidate: 120
      end)
      c.apply_http_cache_headers

      expect(c.response.headers["Cache-Control"]).to eq("private, max-age=30, must-revalidate, stale-while-revalidate=120")
    end
  end

  describe "#stale_resource? (conditional GET)" do
    it "sets validators and returns true on a first request" do
      c = instance(cacheable_class)
      expect(c.stale_resource?(resource)).to be(true)

      expect(c.response.headers["ETag"]).to eq(etag)
      expect(c.response.headers["Last-Modified"]).to eq(Time.utc(2026, 1, 1, 12, 0, 0).httpdate)
      expect(c.rendered).to be_nil
    end

    it "sends 304 when If-None-Match matches the ETag" do
      c = instance(cacheable_class, headers: { "If-None-Match" => etag })
      expect(c.stale_resource?(resource)).to be(false)

      expect(c.response.status).to eq(304)
      expect(c.rendered[:status]).to eq(:not_modified)
    end

    it "matches If-None-Match weakly (ignoring a strong/weak prefix difference)" do
      strong = etag.sub(%r{\AW/}, "")
      c = instance(cacheable_class, headers: { "If-None-Match" => strong })
      expect(c.stale_resource?(resource)).to be(false)
    end

    it "honours a wildcard If-None-Match" do
      c = instance(cacheable_class, headers: { "If-None-Match" => "*" })
      expect(c.stale_resource?(resource)).to be(false)
    end

    it "renders (returns true) when If-None-Match does not match" do
      c = instance(cacheable_class, headers: { "If-None-Match" => %(W/"different") })
      expect(c.stale_resource?(resource)).to be(true)
      expect(c.rendered).to be_nil
    end

    it "sends 304 when If-Modified-Since is at/after the resource timestamp" do
      c = instance(cacheable_class, headers: { "If-Modified-Since" => Time.utc(2026, 1, 1, 12, 0, 0).httpdate })
      expect(c.stale_resource?(resource)).to be(false)
      expect(c.response.status).to eq(304)
    end

    it "renders when If-Modified-Since is before the resource timestamp" do
      c = instance(cacheable_class, headers: { "If-Modified-Since" => Time.utc(2026, 1, 1, 11, 0, 0).httpdate })
      expect(c.stale_resource?(resource)).to be(true)
    end

    it "prefers If-None-Match over If-Modified-Since (RFC 7232)" do
      # ETag mismatch must win even though the date would say 'not modified'.
      c = instance(cacheable_class, headers: {
                     "If-None-Match" => %(W/"stale"),
                     "If-Modified-Since" => Time.utc(2026, 1, 1, 12, 0, 0).httpdate
                   })
      expect(c.stale_resource?(resource)).to be(true)
    end

    it "never sends 304 nor writes validators for an unsafe (non-GET/HEAD) request (1.22)" do
      c = instance(cacheable_class, method: "POST", headers: { "If-None-Match" => etag })
      expect(c.stale_resource?(resource)).to be(true)
      expect(c.response.status).not_to eq(304)
      # A POST response must not advertise an ETag a client could replay
      # against GET (pre-1.22 validators were written even on unsafe methods).
      expect(c.response.headers["ETag"]).to be_nil
    end

    it "accepts an explicit etag/last_modified pair" do
      c = instance(cacheable_class, headers: { "If-None-Match" => %(W/"abc") })
      expect(c.stale_resource?(etag: %(W/"abc"))).to be(false)
    end
  end

  describe "argument validation" do
    it "rejects an invalid visibility" do
      expect { cacheable_class { http_cache_actions :show, visibility: :semi } }
        .to raise_error(ArgumentError, /:visibility/)
    end

    it "rejects a non-positive max_age" do
      expect { cacheable_class { http_cache_actions :show, max_age: 0 } }
        .to raise_error(ArgumentError, /:max_age/)
    end

    it "rejects a blank vary value" do
      expect { cacheable_class { http_cache_actions :show, vary: ["Accept", ""] } }
        .to raise_error(ArgumentError, /:vary/)
    end

    it "rejects a non-boolean no_store" do
      expect { cacheable_class { http_cache_actions :show, no_store: "yes" } }
        .to raise_error(ArgumentError, /:no_store/)
    end
  end
  describe "ETag extras (etag_with) and automatic Vary" do
    def etag_of(controller)
      controller.stale_resource?(resource)
      controller.response.headers["ETag"]
    end

    it "folds a :locale preset into the ETag and adds Vary: Accept-Language" do
      klass = cacheable_class { etag_with :locale }
      en = de = nil
      I18n.with_locale(:en) { en = etag_of(instance(klass)) }
      I18n.with_locale(:de) { de = etag_of(instance(klass)) }

      expect(en).to match(%r{\AW/"[0-9a-f]{32}"\z})
      expect(en).not_to eq(de)
      expect(en).not_to eq(etag) # no longer the bare resource ETag
      expect(instance(klass).tap { |c| c.stale_resource?(resource) }.response.headers["Vary"]).to eq("Accept-Language")
    end

    it "does not send 304 for a validator minted under another locale" do
      klass = cacheable_class { etag_with :locale }
      en = nil
      I18n.with_locale(:en) { en = etag_of(instance(klass)) }

      I18n.with_locale(:de) do
        c = instance(klass, headers: { "If-None-Match" => en })
        expect(c.stale_resource?(resource)).to be(true)
      end
      I18n.with_locale(:en) do
        c = instance(klass, headers: { "If-None-Match" => en })
        expect(c.stale_resource?(resource)).to be(false)
      end
    end

    it "is deterministic — the same context yields the same ETag" do
      klass = cacheable_class { etag_with :locale }
      expect(etag_of(instance(klass))).to eq(etag_of(instance(klass)))
    end

    it "folds the :format and :query preset VALUES, not just their Vary" do
      formats = cacheable_class { etag_with :format }
      json = etag_of(instance(formats, format: "application/json"))
      xml = etag_of(instance(formats, format: "application/xml"))
      expect(json).not_to eq(xml)
      expect(etag_of(instance(formats, format: "application/json"))).to eq(json)

      queries = cacheable_class { etag_with :query }
      first = etag_of(instance(queries, query_string: "page=1"))
      second = etag_of(instance(queries, query_string: "page=2"))
      expect(first).not_to eq(second)
    end

    it "accepts a block (instance_exec'd) and a Symbol naming a controller method" do
      klass = cacheable_class do
        http_cache_actions :show, max_age: 60, visibility: :public
        etag_with :requested_fields
        etag_with { params[:role] }

        def requested_fields
          params[:fields]
        end
      end
      a = etag_of(instance(klass, params: { fields: "id,title", role: "admin" }))
      b = etag_of(instance(klass, params: { fields: "id", role: "admin" }))
      c = etag_of(instance(klass, params: { fields: "id,title", role: "guest" }))
      d = etag_of(instance(klass, params: { fields: "id,title", role: "admin" }))
      expect([a, b, c].uniq.size).to eq(3)
      expect(d).to eq(a)

      # Neither source has a Vary to advertise, so none is emitted — and the
      # response stops being shareable, whatever the rule declared.
      controller = instance(klass)
      controller.stale_resource?(resource)
      controller.apply_http_cache_headers
      expect(controller.response.headers).not_to have_key("Vary")
      expect(controller.response.headers["Cache-Control"]).to eq("private, max-age=60")
    end

    it "ignores nil extras so an absent context leaves the ETag alone" do
      klass = cacheable_class { etag_with { params[:missing] } }
      expect(etag_of(instance(klass))).to eq(etag)
    end

    it "supports per-call extras: merged after the class-level ones" do
      klass = cacheable_class
      plain = etag_of(instance(klass))
      c = instance(klass)
      c.stale_resource?(resource, extras: ["v2"])
      with_extra = c.response.headers["ETag"]
      expect(with_extra).not_to eq(plain)

      again = instance(klass)
      again.stale_resource?(resource, extras: ["v2"])
      expect(again.response.headers["ETag"]).to eq(with_extra)
    end

    it "combines an explicit etag: with extras (and keeps it verbatim without extras)" do
      klass = cacheable_class { etag_with :locale }
      c = instance(klass)
      c.stale_resource?(etag: %(W/"custom"))
      expect(c.response.headers["ETag"]).to match(%r{\AW/"[0-9a-f]{32}"\z})
      expect(c.response.headers["ETag"]).not_to eq(%(W/"custom"))

      bare = instance(cacheable_class)
      bare.stale_resource?(etag: %(W/"custom"))
      expect(bare.response.headers["ETag"]).to eq(%(W/"custom"))
    end

    it ":format varies on Accept, vary: overrides a preset default and vary: false suppresses it" do
      c = instance(cacheable_class { etag_with :format })
      c.stale_resource?(resource)
      expect(c.response.headers["Vary"]).to eq("Accept")

      c = instance(cacheable_class { etag_with :locale, vary: %w[Accept-Language X-Locale] })
      c.stale_resource?(resource)
      expect(c.response.headers["Vary"]).to eq("Accept-Language, X-Locale")

      suppressed = cacheable_class do
        http_cache_actions :show, max_age: 60, visibility: :public
        etag_with :locale, vary: false
      end
      c = instance(suppressed)
      c.stale_resource?(resource)
      c.apply_http_cache_headers
      expect(c.response.headers).not_to have_key("Vary")
      expect(c.response.headers["Cache-Control"]).to eq("private, max-age=60")
    end

    it "merges etag_with Vary with the http_cache_actions policy Vary, de-duplicated" do
      klass = cacheable_class do
        http_cache_actions :show, max_age: 60, vary: %w[Accept Accept-Language]
        etag_with :locale
      end
      c = instance(klass)
      c.stale_resource?(resource)
      c.apply_http_cache_headers
      expect(c.response.headers["Vary"]).to eq("Accept-Language, Accept")
    end

    it "does not touch validators or Vary on an unsafe request" do
      c = instance(cacheable_class { etag_with :locale }, method: "POST")
      expect(c.stale_resource?(resource)).to be(true)
      expect(c.response.headers).not_to have_key("ETag")
      expect(c.response.headers).not_to have_key("Vary")
    end

    it "exposes the declared extras and validates the macro" do
      klass = cacheable_class { etag_with :locale, :format }
      expect(klass.cacheable_etag_extras.map { |e| e[:source] }).to eq(%i[locale format])

      expect { cacheable_class { etag_with } }.to raise_error(ArgumentError, /etag_with needs at least one source or a block/)
      expect { cacheable_class { etag_with "locale" } }.to raise_error(ArgumentError, /sources must be Symbols/)
      expect { cacheable_class { etag_with :locale, vary: "" } }.to raise_error(ArgumentError, /:vary must be/)
    end

    it "raises a clear error at request time for a Symbol that is neither a preset nor a controller method" do
      c = instance(cacheable_class { etag_with :nope })
      expect { c.stale_resource?(resource) }.to raise_error(ArgumentError, /etag_with :nope.*neither a preset.*nor a controller method/)
    end

    it "emits the sources' Vary from the after_action too, for an action that never calls stale_resource?" do
      klass = cacheable_class do
        http_cache_actions :show, max_age: 300, visibility: :public, vary: "Accept"
        etag_with :locale
      end
      c = instance(klass)
      c.apply_http_cache_headers

      expect(c.response.headers["Vary"]).to eq("Accept, Accept-Language")
      expect(c.response.headers["Cache-Control"]).to eq("public, max-age=300")
    end

    it "still calls an override of set_cache_validators that kept the three-keyword signature" do
      klass = cacheable_class do
        etag_with :locale

        def set_cache_validators(resource = nil, etag: nil, last_modified: nil)
          @legacy_override = true
          super
        end
      end
      c = instance(klass)

      expect { c.stale_resource?(resource) }.not_to raise_error
      expect(c.instance_variable_get(:@legacy_override)).to be(true)
      expect(c.response.headers["ETag"]).to match(%r{\AW/"[0-9a-f]{32}"\z})
    end
  end

  describe "unshareable ETag sources (forced private)" do
    it "downgrades a :public rule when a block source has no Vary to advertise" do
      klass = cacheable_class do
        http_cache_actions :show, max_age: 300, visibility: :public, vary: "Accept"
        etag_with { current_user_role }

        def current_user_role
          "admin"
        end
      end
      c = instance(klass)
      c.apply_http_cache_headers

      expect(c.response.headers["Cache-Control"]).to eq("private, max-age=300")
      expect(c.response.headers["Vary"]).to eq("Accept")
    end

    it "downgrades a :public rule for a Symbol source and for a preset with vary: false" do
      symbol = cacheable_class do
        http_cache_actions :show, max_age: 60, visibility: :public
        etag_with :requested_fields

        def requested_fields
          "id"
        end
      end
      suppressed = cacheable_class do
        http_cache_actions :show, max_age: 60, visibility: :public
        etag_with :locale, vary: false
      end

      [symbol, suppressed].each do |klass|
        c = instance(klass)
        c.apply_http_cache_headers
        expect(c.response.headers["Cache-Control"]).to eq("private, max-age=60")
      end
    end

    it "leaves :public alone when every source advertises a Vary (or is :query)" do
      klass = cacheable_class do
        http_cache_actions :show, max_age: 300, visibility: :public
        etag_with :locale, :format, :query # :query is already keyed by the URL
        etag_with :fields, vary: "X-Fields"

        def fields
          "id"
        end
      end
      c = instance(klass)
      c.apply_http_cache_headers

      expect(c.response.headers["Cache-Control"]).to eq("public, max-age=300")
      expect(c.response.headers["Vary"]).to eq("Accept-Language, Accept, X-Fields")
    end

    it "leaves no_store alone — it already overrides visibility" do
      klass = cacheable_class do
        http_cache_actions :show, no_store: true
        etag_with { "role" }
      end
      c = instance(klass)
      c.apply_http_cache_headers

      expect(c.response.headers["Cache-Control"]).to eq("no-store")
    end
  end

  describe "through real ActionController dispatch" do
    let(:controller) do
      IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Cacheable

        http_cache_actions visibility: :public, max_age: 300

        def show
          render json: { ok: true }
        end

        def create
          render json: { id: 1 }, status: :created
        end

        def missing
          render json: { error: "nope" }, status: :not_found
        end

        def failing
          render json: { error: "boom" }, status: :internal_server_error
        end

        def moved
          redirect_to "/elsewhere"
        end
      end
    end

    def cache_control(action, method: "GET")
      IntegrationHarness.dispatch(controller, action, method: method).header("Cache-Control").to_s
    end

    it "emits the public policy on a GET 200" do
      expect(cache_control(:show)).to include("public").and include("max-age=300")
    end

    it "does not hand shared caches a POST 201, or a 404/500/302 the action rendered itself" do
      [[:create, "POST"], [:missing, "GET"], [:failing, "GET"], [:moved, "GET"]].each do |action, method|
        value = cache_control(action, method: method)
        expect(value).not_to include("public"), "#{method} #{action}: #{value}"
        expect(value).not_to include("max-age=300"), "#{method} #{action}: #{value}"
      end
    end

    # set_cache_validators runs BEFORE render, and Rails only adds its own
    # `Vary: Accept` while the header is still blank — so writing
    # `Vary: Accept-Language` first used to strip the Accept dimension from a
    # content-negotiated response. (Rails 6.0 never emits Vary: Accept.)
    it "keeps Rails' own Vary: Accept when validators are written before render", min_rails: "6.1" do
      negotiating = IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Cacheable

        etag_with :locale

        def show
          return unless stale_resource?("article-1")

          render json: { ok: true }
        end
      end
      result = IntegrationHarness.dispatch(negotiating, :show, headers: { "Accept" => "application/json" })
      dimensions = result.header("Vary").to_s.split(",").map(&:strip)
      expect(dimensions).to include("Accept", "Accept-Language")
    end
  end
end
