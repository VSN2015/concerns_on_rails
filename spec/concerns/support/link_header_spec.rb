require "spec_helper"
require "concerns_on_rails/support/link_header"

RSpec.describe ConcernsOnRails::Support::LinkHeader do
  FakeLinkRequest = Struct.new(:base_url, :path, :query_parameters) unless defined?(FakeLinkRequest)

  let(:request) do
    FakeLinkRequest.new("https://api.example.com", "/v1/articles",
                        ActiveSupport::HashWithIndifferentAccess.new("page" => "2", "per_page" => "10", "q" => "a b"))
  end
  let(:response) { FakeResponse.new }

  describe ".url_for" do
    it "rebuilds the current URL with overrides merged into the query, preserving order and encoding" do
      expect(described_class.url_for(request, page: 3))
        .to eq("https://api.example.com/v1/articles?page=3&per_page=10&q=a+b")
    end

    it "drops keys given as nil overrides or via drop:, and omits the '?' when nothing is left" do
      expect(described_class.url_for(request, page: nil, drop: %i[per_page q])).to eq("https://api.example.com/v1/articles")
      expect(described_class.url_for(request, drop: :q)).to eq("https://api.example.com/v1/articles?page=2&per_page=10")
    end

    it "adds a key the request did not carry" do
      bare = FakeLinkRequest.new("http://localhost:3000", "/items", ActiveSupport::HashWithIndifferentAccess.new)
      expect(described_class.url_for(bare, cursor: "abc")).to eq("http://localhost:3000/items?cursor=abc")
    end

    it "keeps nested params intact" do
      nested = FakeLinkRequest.new("http://h", "/p", ActiveSupport::HashWithIndifferentAccess.new("filter" => { "state" => "open" }))
      expect(described_class.url_for(nested, page: 2)).to eq("http://h/p?filter%5Bstate%5D=open&page=2")
    end
  end

  describe ".append" do
    it "serializes rels as RFC 8288 web links, skipping nil urls" do
      described_class.append(response, first: "http://h/p?page=1", prev: nil, next: "http://h/p?page=3")
      expect(response.headers["Link"]).to eq('<http://h/p?page=1>; rel="first", <http://h/p?page=3>; rel="next"')
    end

    it "appends to an existing Link header instead of clobbering it" do
      response.set_header("Link", '<https://docs.example.com/v2>; rel="deprecation"')
      described_class.append(response, next: "http://h/p?page=2")
      expect(response.headers["Link"])
        .to eq('<https://docs.example.com/v2>; rel="deprecation", <http://h/p?page=2>; rel="next"')
    end

    it "sets nothing when every url is nil" do
      described_class.append(response, next: nil, prev: nil)
      expect(response.headers).not_to have_key("Link")
    end
  end

  describe ".available?" do
    it "is true only for a controller whose request exposes base_url, path and query_parameters" do
      with_request = Struct.new(:request).new(request)
      expect(described_class.available?(with_request)).to be(true)
      expect(described_class.available?(FakeController.new)).to be(false)
      expect(described_class.available?(Struct.new(:request).new(nil))).to be(false)
      expect(described_class.available?(Struct.new(:request).new(Object.new))).to be(false)
    end
  end
end
