require "spec_helper"

# Audit 2026-10-10, TRANS-7. The :url preset prefixed every scheme-less value
# with "https://", so a protocol-relative "//CDN.Example.com/x" became
# "https:////CDN.Example.com/x", which does not parse; the rescue then stored
# it stripped but otherwise untouched: no scheme, host case unchanged. Two
# records for the same CDN URL differed by case, and equality lookups through
# Model.normalize(:website, ...) missed.
describe ConcernsOnRails::Models::Normalizable do
  before do
    ActiveRecord::Schema.define do
      create_table :protocol_relative_posts, force: true do |t|
        t.string :website
      end
    end
  end

  after do
    ActiveRecord::Base.connection.drop_table(:protocol_relative_posts, if_exists: true)
  end

  let(:klass) do
    Class.new(TestModel) do
      self.table_name = "protocol_relative_posts"
      include ConcernsOnRails::Models::Normalizable

      normalizable :website, with: :url
    end
  end

  it "gives a protocol-relative URL the https scheme and a lowercase host, keeping the path" do
    post = klass.create!(website: " //CDN.Example.com/Assets/x.js ")

    expect(post.website).to eq("https://cdn.example.com/Assets/x.js")
    expect(klass.normalize(:website, "//CDN.EXAMPLE.COM/Assets/x.js")).to eq(post.website)
  end

  it "keeps the userinfo and port of a protocol-relative URL, dropping only the default port" do
    expect(klass.normalize(:website, "//user:PASS@Host.Example.com:8443/p?q=Y")).to eq("https://user:PASS@host.example.com:8443/p?q=Y")
    expect(klass.normalize(:website, "//Example.com:443/x")).to eq("https://example.com/x")
  end

  it "leaves input with no host after the slashes on the stripped-only path" do
    expect(klass.normalize(:website, " ///x ")).to eq("///x")
    expect(klass.normalize(:website, "//")).to eq("//")
    expect(klass.normalize(:website, "// spaced out")).to eq("// spaced out")
  end

  it "still defaults the scheme of a bare host and leaves other schemes alone" do
    expect(klass.normalize(:website, "Example.COM/Some/Path")).to eq("https://example.com/Some/Path")
    expect(klass.normalize(:website, "HTTP://Foo.Bar/X")).to eq("http://foo.bar/X")
    expect(klass.normalize(:website, "javascript:alert(1)")).to eq("javascript:alert(1)")
  end
end
