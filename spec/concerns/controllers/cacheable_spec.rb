require "spec_helper"

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

  FakeCacheRequest = Struct.new(:request_method, :headers) unless defined?(FakeCacheRequest)

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

  def instance(klass, action: "show", method: "GET", headers: {}, params: {})
    controller = klass.new(params: params)
    request = FakeCacheRequest.new(method, headers)
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

    it "never sends 304 for an unsafe (non-GET/HEAD) request" do
      c = instance(cacheable_class, method: "POST", headers: { "If-None-Match" => etag })
      expect(c.stale_resource?(resource)).to be(true)
      expect(c.response.status).not_to eq(304)
      # validators are still set
      expect(c.response.headers["ETag"]).to eq(etag)
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
end
