require "spec_helper"

describe ConcernsOnRails::Models::Sanitizable do
  before do
    ActiveRecord::Schema.define do
      create_table :sanitizable_articles, force: true do |t|
        t.string :title
        t.text :body
        t.text :summary
        t.string :code
        t.integer :views
      end
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end

    Object.send(:remove_const, :SanitizableArticle) if Object.const_defined?(:SanitizableArticle)
  end

  describe "non-destructive :read mode (default)" do
    it "adds a sanitized_<field> reader and leaves the stored column untouched" do
      class SanitizableArticle < TestModel
        self.table_name = "sanitizable_articles"
        include ConcernsOnRails::Models::Sanitizable

        sanitizable :body, with: :strip
      end

      article = SanitizableArticle.new(body: "<b>Hi</b> <script>x()</script>")
      article.valid?

      expect(article.body).to eq("<b>Hi</b> <script>x()</script>") # raw, intact
      expect(article.sanitized_body).to eq("Hi x()")                # cleaned view
    end

    it "applies the :safe_list preset in the reader (keeps formatting, drops <script>)" do
      class SanitizableArticle < TestModel
        self.table_name = "sanitizable_articles"
        include ConcernsOnRails::Models::Sanitizable

        sanitizable :body, with: :safe_list
      end

      article = SanitizableArticle.new(body: "<b>Hi</b><script>alert(1)</script><i>x</i>")

      expect(article.sanitized_body).to include("<b>Hi</b>", "<i>x</i>")
      expect(article.sanitized_body).not_to include("<script")
    end

    it "applies the :no_links preset in the reader (strips <a>, keeps other markup)" do
      class SanitizableArticle < TestModel
        self.table_name = "sanitizable_articles"
        include ConcernsOnRails::Models::Sanitizable

        sanitizable :body, with: :no_links
      end

      article = SanitizableArticle.new(body: %(<a href="/x">click</a> rest <b>b</b>))

      expect(article.sanitized_body).to eq("click rest <b>b</b>")
    end

    it "treats the :none preset as a no-op reader" do
      class SanitizableArticle < TestModel
        self.table_name = "sanitizable_articles"
        include ConcernsOnRails::Models::Sanitizable

        sanitizable :body, with: :none
      end

      article = SanitizableArticle.new(body: "<b>x</b>")

      expect(article.sanitized_body).to eq("<b>x</b>")
    end

    it "returns nil from the reader when the column is nil" do
      class SanitizableArticle < TestModel
        self.table_name = "sanitizable_articles"
        include ConcernsOnRails::Models::Sanitizable

        sanitizable :body, with: :strip
      end

      expect(SanitizableArticle.new(body: nil).sanitized_body).to be_nil
    end
  end

  describe "destructive :write mode" do
    it "overwrites the column in before_validation" do
      class SanitizableArticle < TestModel
        self.table_name = "sanitizable_articles"
        include ConcernsOnRails::Models::Sanitizable

        sanitizable :title, with: :strip, on: :write
      end

      article = SanitizableArticle.new(title: "<b>Hello</b>")
      article.valid?

      expect(article.title).to eq("Hello")
    end

    it "runs before validations so a presence check sees the sanitized value" do
      class SanitizableArticle < TestModel
        self.table_name = "sanitizable_articles"
        include ConcernsOnRails::Models::Sanitizable

        sanitizable :title, with: :strip, on: :write
        validates :title, presence: true
      end

      # "<script></script>" strips to "" -> presence fails on the clean value.
      article = SanitizableArticle.new(title: "<script></script>")

      expect(article.valid?).to be false
      expect(article.errors[:title]).to be_present
    end

    it "does not define a sanitized_ reader in :write mode" do
      class SanitizableArticle < TestModel
        self.table_name = "sanitizable_articles"
        include ConcernsOnRails::Models::Sanitizable

        sanitizable :title, with: :strip, on: :write
      end

      expect(SanitizableArticle.new).not_to respond_to(:sanitized_title)
    end

    it "leaves nil values alone" do
      class SanitizableArticle < TestModel
        self.table_name = "sanitizable_articles"
        include ConcernsOnRails::Models::Sanitizable

        sanitizable :title, with: :strip, on: :write
      end

      article = SanitizableArticle.new(title: nil)
      article.valid?

      expect(article.title).to be_nil
    end
  end

  describe "non-string handling" do
    it "passes non-string column values through untouched" do
      class SanitizableArticle < TestModel
        self.table_name = "sanitizable_articles"
        include ConcernsOnRails::Models::Sanitizable

        sanitizable :views, with: :strip
      end

      expect(SanitizableArticle.new(views: 42).sanitized_views).to eq(42)
    end
  end

  describe "custom allow-lists and procs" do
    it "treats an Array as a custom tag allow-list" do
      class SanitizableArticle < TestModel
        self.table_name = "sanitizable_articles"
        include ConcernsOnRails::Models::Sanitizable

        sanitizable :body, with: %w[b i]
      end

      article = SanitizableArticle.new(body: %(<b>B</b><i>I</i><a href="/x">L</a>))

      expect(article.sanitized_body).to include("<b>B</b>", "<i>I</i>")
      expect(article.sanitized_body).not_to include("<a")
    end

    it "treats a Hash as a { tags:, attributes: } allow-list" do
      class SanitizableArticle < TestModel
        self.table_name = "sanitizable_articles"
        include ConcernsOnRails::Models::Sanitizable

        sanitizable :body, with: { tags: %w[a], attributes: %w[href] }
      end

      article = SanitizableArticle.new(body: %(<a href="/x" onclick="evil()">L</a>))

      expect(article.sanitized_body).to include(%(href="/x"))
      expect(article.sanitized_body).not_to include("onclick")
    end

    it "uses a Proc as-is" do
      class SanitizableArticle < TestModel
        self.table_name = "sanitizable_articles"
        include ConcernsOnRails::Models::Sanitizable

        sanitizable :code, with: ->(v) { v.to_s.upcase }
      end

      expect(SanitizableArticle.new(code: "abc").sanitized_code).to eq("ABC")
    end
  end

  describe "multiple fields and declarations" do
    it "sanitizes every listed field and supports several declarations" do
      class SanitizableArticle < TestModel
        self.table_name = "sanitizable_articles"
        include ConcernsOnRails::Models::Sanitizable

        sanitizable :body, :summary, with: :strip
        sanitizable :title, with: :strip, on: :write
      end

      article = SanitizableArticle.new(
        title: "<b>T</b>",
        body: "<i>B</i>",
        summary: "<u>S</u>"
      )
      article.valid?

      expect(article.title).to eq("T")            # :write overwrote
      expect(article.body).to eq("<i>B</i>")      # :read left raw
      expect(article.sanitized_body).to eq("B")
      expect(article.sanitized_summary).to eq("S")
    end
  end

  describe "configuration errors" do
    it "raises when no fields are given" do
      expect do
        class SanitizableArticle < TestModel
          self.table_name = "sanitizable_articles"
          include ConcernsOnRails::Models::Sanitizable

          sanitizable with: :strip
        end
      end.to raise_error(ArgumentError, /at least one field is required/)
    end

    it "raises when :on is not :read or :write" do
      expect do
        class SanitizableArticle < TestModel
          self.table_name = "sanitizable_articles"
          include ConcernsOnRails::Models::Sanitizable

          sanitizable :body, with: :strip, on: :always
        end
      end.to raise_error(ArgumentError, /:on must be :read or :write/)
    end

    it "raises on an unknown preset" do
      expect do
        class SanitizableArticle < TestModel
          self.table_name = "sanitizable_articles"
          include ConcernsOnRails::Models::Sanitizable

          sanitizable :body, with: :flarbgnarb
        end
      end.to raise_error(ArgumentError, /unknown preset/)
    end

    it "raises on an unknown allow-list key" do
      expect do
        class SanitizableArticle < TestModel
          self.table_name = "sanitizable_articles"
          include ConcernsOnRails::Models::Sanitizable

          sanitizable :body, with: { tags: %w[a], bogus: 1 }
        end
      end.to raise_error(ArgumentError, /allow-list keys must be :tags/)
    end

    it "raises when :with is an unsupported type" do
      expect do
        class SanitizableArticle < TestModel
          self.table_name = "sanitizable_articles"
          include ConcernsOnRails::Models::Sanitizable

          sanitizable :body, with: 123
        end
      end.to raise_error(ArgumentError, /must be a preset symbol/)
    end

    it "raises when the column does not exist" do
      expect do
        class SanitizableArticle < TestModel
          self.table_name = "sanitizable_articles"
          include ConcernsOnRails::Models::Sanitizable

          sanitizable :nonexistent, with: :strip
        end
      end.to raise_error(ArgumentError, /does not exist in the database/)
    end
  end

  describe ConcernsOnRails::Support::HtmlSanitizers do
    it "exposes reusable, memoized sanitizer instances that respond to #sanitize" do
      sanitizers = ConcernsOnRails::Support::HtmlSanitizers

      %i[full safe link].each do |kind|
        instance = sanitizers.public_send(kind)
        expect(instance).to respond_to(:sanitize)
        expect(sanitizers.public_send(kind)).to be(instance) # same memoized object
      end
    end
  end
end
