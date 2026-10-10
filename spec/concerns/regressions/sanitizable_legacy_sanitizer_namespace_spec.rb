require "spec_helper"

# Audit 2026-10-10, TRANS-12. Rails::HTML4 / Rails::HTML5 (and Rails::HTML)
# arrived in rails-html-sanitizer 1.6.0; 1.5.x and earlier define only
# Rails::Html. actionpack 6.0-7.0 accept those older releases, and the
# namespace probe referenced Rails::HTML4 unconditionally there, so every
# Sanitizable call raised NameError. CI resolves 1.6+, so the older layout is
# simulated by hiding the newer constants (Rails::Html is still the gem's
# HTML4 implementation, as it was in 1.5).
describe ConcernsOnRails::Support::HtmlSanitizers do
  def reset_sanitizer_memos
    %i[@namespace @full @safe @link].each do |ivar|
      described_class.remove_instance_variable(ivar) if described_class.instance_variable_defined?(ivar)
    end
  end

  before { reset_sanitizer_memos }
  after { reset_sanitizer_memos }

  context "on rails-html-sanitizer older than 1.6 (only Rails::Html)" do
    before do
      ActiveRecord::Schema.define do
        create_table :legacy_sanitizer_posts, force: true do |t|
          t.string :title
          t.text :body
        end
      end

      hide_const("Rails::HTML5")
      hide_const("Rails::HTML4")
      hide_const("Rails::HTML")
    end

    after do
      ActiveRecord::Base.connection.drop_table(:legacy_sanitizer_posts, if_exists: true)
    end

    it "uses the Rails::Html sanitizers instead of raising NameError" do
      expect(described_class.namespace).to be(Rails::Html)
      expect(described_class.full).to be_a(Rails::Html::FullSanitizer)
      expect(described_class.safe).to be_a(Rails::Html::SafeListSanitizer)
      expect(described_class.link).to be_a(Rails::Html::LinkSanitizer)
    end

    it "still strips, safe-lists and unlinks" do
      expect(described_class.plain_text("<b>Tom</b> & Jerry")).to eq("Tom & Jerry")
      expect(described_class.safe.sanitize("<b>x</b><script>alert(1)</script>")).to eq("<b>x</b>alert(1)")
      expect(described_class.link.sanitize('<a href="/x">go</a>')).to eq("go")
    end

    it "keeps a Sanitizable model working (on: :write saves and the sanitized_ reader)" do
      klass = Class.new(TestModel) do
        self.table_name = "legacy_sanitizer_posts"
        include ConcernsOnRails::Models::Sanitizable

        sanitizable :title, with: :strip, on: :write
        sanitizable :body, with: :safe_list
      end

      post = klass.create!(title: "<b>Tom</b> & Jerry", body: "<i>hi</i><script>x()</script>")

      expect(post.reload.title).to eq("Tom & Jerry")
      expect(post.sanitized_body).to eq("<i>hi</i>x()")
      expect(post.as_json(sanitized: true)["body"]).to eq("<i>hi</i>x()")
    end
  end

  context "on rails-html-sanitizer 1.6+ without HTML5 support (JRuby, no libgumbo)" do
    it "uses Rails::HTML4" do
      allow(Rails::HTML::Sanitizer).to receive(:html5_support?).and_return(false)

      expect(described_class.namespace).to be(Rails::HTML4)
    end
  end

  context "on rails-html-sanitizer 1.6+ with HTML5 support" do
    it "uses Rails::HTML5" do
      allow(Rails::HTML::Sanitizer).to receive(:html5_support?).and_return(true)

      expect(described_class.namespace).to be(Rails::HTML5)
    end
  end
end
