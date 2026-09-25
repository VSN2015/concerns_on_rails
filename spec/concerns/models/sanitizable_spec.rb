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

      create_table :sanitizable_comments, force: true do |t|
        t.integer :sanitizable_article_id
        t.text :body
      end

      create_table :sanitizable_accounts, force: true do |t|
        t.string :email
      end
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end

    %i[SanitizableArticle SanitizableComment].each do |const|
      Object.send(:remove_const, const) if Object.const_defined?(const)
    end
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
      expect(article.sanitized_body).to eq("Hi x()") # cleaned view
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

    # FullSanitizer returns HTML-escaped text, so `:strip, on: :write` used to
    # STORE "Tom &amp; Jerry" — which Rails' output escaping then turned into
    # "Tom &amp;amp; Jerry" on the page. The write-mode value is plain text:
    # entities are decoded, EXCEPT &lt; / &gt;, which stay encoded so a later
    # `raw` render can never produce markup.
    context "when :strip stores plain text" do
      before do
        class SanitizableArticle < TestModel
          self.table_name = "sanitizable_articles"
          include ConcernsOnRails::Models::Sanitizable

          sanitizable :title, with: :strip, on: :write
          sanitizable :summary, with: :strip
        end
      end

      def stored(value)
        SanitizableArticle.create!(title: value).reload.title
      end

      it "decodes entities the sanitizer introduced" do
        expect(stored("<b>Tom</b> & Jerry")).to eq("Tom & Jerry")
        expect(stored("Tom &amp; Jerry")).to eq("Tom & Jerry")
        expect(stored("say \"hi\" it's")).to eq("say \"hi\" it's")
        expect(stored("a&nbsp;b &eacute;")).to eq("a b é")
      end

      it "keeps angle brackets encoded so the stored value can never become markup" do
        expect(stored("a < b > c")).to eq("a &lt; b &gt; c")
        expect(stored("&lt;script&gt;alert(1)&lt;/script&gt;")).to eq("&lt;script&gt;alert(1)&lt;/script&gt;")
        expect(stored("&#60;img src=x onerror=alert(1)&#x3E;")).to eq("&lt;img src=x onerror=alert(1)&gt;")
        expect(stored("<scr<script>ipt>alert(1)</script>")).not_to match(/[<>]/)
      end

      it "decodes a bare ampersand but keeps one that would read back as a character reference" do
        expect(stored("R&amp;D, AT&T")).to eq("R&D, AT&T")
        # The text is literally "&copy;" / "&lt;b&gt;": decoding the &amp; would
        # turn it into "©" / markup-looking text on the next save.
        expect(stored("&amp;copy; 2024")).to eq("&amp;copy; 2024")
        expect(stored("&amp;lt;b&amp;gt;")).to eq("&amp;lt;b&amp;gt;")
      end

      it "is idempotent across re-saves" do
        inputs = ["<i>Tom</i> & Jerry < 3", "R&D", "&amp;copy2024", "&amp;amp;", "x&nbsp;y", "&amp;#60;"]
        inputs.each do |input|
          article = SanitizableArticle.create!(title: input)
          first = article.reload.title

          article.title = "#{first} "
          article.title = first
          article.save!

          expect(article.reload.title).to eq(first), "#{input.inspect} drifted"
          expect(SanitizableArticle.sanitize_all!).to eq(0), "#{input.inspect} drifted in sanitize_all!"
        end
        expect(SanitizableArticle.first.title).to eq("Tom & Jerry &lt; 3")
      end

      it "keeps semicolon-less legacy and numeric references encoded, so they never drift" do
        {
          "&amp;notit" => "&amp;notit", "&amp;copyright" => "&amp;copyright", "&amp;lt 3" => "&amp;lt 3",
          "&amp;#x3c" => "&amp;#x3c", "&amp;#60" => "&amp;#60", "&amp;Dagger;" => "&amp;Dagger;",
          "&amp;D; & &amp;#; &amp;x" => "&D; & &amp;#; &x", "a&#13;b&#13;&#10;c" => "a\nb\nc"
        }.each do |input, expected|
          expect(stored(input)).to eq(expected), input.inspect
          expect(ConcernsOnRails::Support::HtmlSanitizers.plain_text(expected)).to eq(expected), "#{input.inspect} drifted"
        end
      end

      # Deciding whether an "&" starts a character reference used to run a
      # full HTML parse PER ampersand: 100 KB of "&a" took ~24 s inside
      # before_validation. It is now a static, linear-time rule.
      it "sanitizes ampersand-heavy input in linear time" do
        payload = "&a" * 50_000 # 100 KB
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = ConcernsOnRails::Support::HtmlSanitizers.plain_text(payload)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        expect(result).to eq(payload)
        expect(elapsed).to be < 1.0
      end

      # The legacy-name alternation in the lookahead made each "&" slow even
      # though the pass was linear: 1 MB of "&" took ~7 s.
      it "sanitizes a megabyte of bare ampersands quickly" do
        payload = "&" * 1_000_000
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = ConcernsOnRails::Support::HtmlSanitizers.plain_text(payload)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        expect(result).to eq(payload)
        expect(elapsed).to be < 2.0
      end

      it "sanitize_all! stores the same plain text and repairs rows written double-escaped" do
        legacy = SanitizableArticle.create!(title: "x")
        legacy.update_columns(title: "Tom &amp; Jerry")
        raw = SanitizableArticle.create!(title: "y")
        raw.update_columns(title: "<b>Tom</b> & Jerry")

        expect(SanitizableArticle.sanitize_all!).to eq(2)
        expect(legacy.reload.title).to eq("Tom & Jerry")
        expect(raw.reload.title).to eq("Tom & Jerry")
        expect(SanitizableArticle.sanitize_all!).to eq(0)
      end

      it "leaves the on: :read reader's HTML output unchanged" do
        article = SanitizableArticle.new(summary: "<b>Tom</b> & Jerry")

        expect(article.sanitized_summary).to eq("Tom &amp; Jerry")
        expect(article.sanitized_attributes["summary"]).to eq("Tom &amp; Jerry")
      end
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

  describe "sanitized serialization and sanitize_all!" do
    let(:klass) do
      class SanitizableArticle < TestModel
        self.table_name = "sanitizable_articles"
        include ConcernsOnRails::Models::Sanitizable

        sanitizable :body, with: :safe_list
        sanitizable :summary, with: :strip
        sanitizable :title, with: :strip, on: :write
      end
      SanitizableArticle
    end
    let(:raw_body) { "<b>Hi</b><script>alert(1)</script>" }
    let(:article) { klass.create!(title: "<b>T</b>", body: raw_body, summary: "<i>sum</i>", code: "<x>", views: 3) }

    it "sanitized_attributes applies every rule (read and write) to the current values, keyed like `attributes`" do
      expect(article.sanitized_attributes).to eq("body" => "<b>Hi</b>alert(1)", "summary" => "sum", "title" => "T")
      expect(article.body).to eq(raw_body)
    end

    it "as_json(sanitized: true) swaps the declared fields, leaves the rest raw, accepts a subset and rejects unknowns" do
      json = article.as_json(sanitized: true)
      expect(json.slice("body", "summary", "title", "code", "views"))
        .to eq("body" => "<b>Hi</b>alert(1)", "summary" => "sum", "title" => "T", "code" => "<x>", "views" => 3)
      expect(article.as_json["body"]).to eq(raw_body)

      subset = article.as_json(sanitized: [:summary])
      expect(subset["summary"]).to eq("sum")
      expect(subset["body"]).to eq(raw_body)
      expect(JSON.parse(article.to_json(sanitized: true, only: %i[id summary]))).to eq("id" => article.id, "summary" => "sum")
      expect { article.as_json(sanitized: [:code]) }
        .to raise_error(ArgumentError, /code is not a sanitizable field \(declared: body, summary, title\)/)
    end

    it "sanitize_all! repairs the on: :write rows and leaves the on: :read columns raw" do
      clean = klass.create!(title: "clean", body: "<p>ok</p>", summary: "plain")
      dirty = klass.create!(title: "x", body: "<script>bad</script><em>e</em>", summary: "<b>s</b>")
      dirty.update_columns(title: "<u>legacy</u>") # a write that bypassed the on: :write callback
      klass.create!(title: nil, body: nil, summary: nil)

      expect(klass.sanitize_all!).to eq(1)
      # title is on: :write, so it is repaired. body and summary are on: :read —
      # the mode whose whole contract is that the stored column stays raw — so a
      # bare call must not touch them.
      expect(dirty.reload.attributes.slice("title", "body", "summary"))
        .to eq("title" => "legacy", "body" => "<script>bad</script><em>e</em>", "summary" => "<b>s</b>")
      expect(clean.reload.body).to eq("<p>ok</p>")
      expect(klass.sanitize_all!).to eq(0) # idempotent
    end

    it "sanitize_all! still overwrites an on: :read column when you name it explicitly" do
      dirty = klass.create!(title: "x", body: "<script>bad</script><em>e</em>", summary: "<b>s</b>")

      expect(klass.sanitize_all!(:body)).to eq(1)
      expect(dirty.reload.body).to eq("bad<em>e</em>")
      expect(dirty.summary).to eq("<b>s</b>") # not named, still raw
    end

    it "sanitize_all! follows the current scope and accepts a subset of fields" do
      a = klass.create!(title: "a", body: "<script>x</script>", summary: "<b>a</b>")
      b = klass.create!(title: "b", body: "<script>y</script>", summary: "<b>b</b>")

      expect(klass.where(id: a.id).sanitize_all!(:summary)).to eq(1)
      expect(a.reload.summary).to eq("a")
      expect(a.body).to eq("<script>x</script>") # body not in the subset
      expect(b.reload.summary).to eq("<b>b</b>") # outside the scope
      expect { klass.sanitize_all!(:code) }.to raise_error(ArgumentError, /code is not a sanitizable field/)
    end

    it "rejects a sanitized: shape that is neither true nor a field list" do
      expect { article.as_json(sanitized: { body: true }) }
        .to raise_error(ArgumentError, /sanitized: takes true or a list of declared fields, got Hash/)
    end

    it "carries sanitized: into a nested include: instead of serializing the child raw" do
      parent = article # defines SanitizableArticle before the association is declared

      class SanitizableComment < TestModel
        self.table_name = "sanitizable_comments"
        include ConcernsOnRails::Models::Sanitizable

        sanitizable :body, with: :strip
      end
      SanitizableArticle.has_many :sanitizable_comments, class_name: "SanitizableComment",
                                                         foreign_key: :sanitizable_article_id
      SanitizableComment.create!(sanitizable_article_id: parent.id, body: "<script>bad</script>ok")

      json = parent.as_json(sanitized: true, include: :sanitizable_comments)
      expect(json["sanitizable_comments"].first["body"]).to eq("badok")

      # an explicit per-child setting still wins
      raw = parent.as_json(sanitized: true, include: { sanitizable_comments: { sanitized: false } })
      expect(raw["sanitizable_comments"].first["body"]).to eq("<script>bad</script>ok")
    end

    it "sanitizes the serialized value, not the raw column" do
      klass = Class.new(TestModel) do
        self.table_name = "sanitizable_articles"
        include ConcernsOnRails::Models::Sanitizable

        sanitizable :summary, with: :strip

        def summary
          "<b>#{super}</b>" # an overridden reader is what as_json serializes
        end
      end
      record = klass.create!(summary: "hi")

      expect(record.as_json(sanitized: true)["summary"]).to eq("hi")
    end

    it "returns 0 without querying when nothing is declared on: :write" do
      read_only = Class.new(TestModel) do
        self.table_name = "sanitizable_articles"
        include ConcernsOnRails::Models::Sanitizable

        sanitizable :body, with: :strip
      end
      read_only.create!(body: "<script>x</script>")

      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
        statements << args.last[:sql].to_s
      end
      begin
        expect(read_only.sanitize_all!).to eq(0)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(statements).to be_empty
    end

    it "raises RecordNotSaved and rolls the batch back when a row vanishes mid-sweep" do
      first = klass.create!(title: "ok")
      first.update_columns(title: "<b>first</b>")
      gone = klass.create!(title: "ok")
      gone.update_columns(title: "<b>gone</b>")

      # update_columns returns false when the row it targets no longer exists.
      allow_any_instance_of(klass).to receive(:update_columns) do |record, changes|
        next false if record.id == gone.id

        klass.unscoped.where(id: record.id).update_all(changes) == 1
      end

      expect { klass.sanitize_all! }.to raise_error(ActiveRecord::RecordNotSaved, /failed to sanitize record/)
      expect(first.reload.title).to eq("<b>first</b>") # rolled back with the batch
    end
  end

  describe "composition with Maskable" do
    def account_class(order)
      Class.new(TestModel) do
        self.table_name = "sanitizable_accounts"
        if order == :maskable_first
          include ConcernsOnRails::Models::Maskable
          include ConcernsOnRails::Models::Sanitizable
        else
          include ConcernsOnRails::Models::Sanitizable
          include ConcernsOnRails::Models::Maskable
        end

        maskable :email, with: :email
        sanitizable :email, with: :strip
      end
    end

    %i[maskable_first sanitizable_first].each do |order|
      it "keeps the mask when both options are requested (#{order})" do
        record = account_class(order).create!(email: "jack@example.com")

        json = record.as_json(masked: true, sanitized: true)

        expect(json["email"]).to eq("j***@example.com")
        expect(json["email"]).not_to include("jack@") # never the raw column
      end

      it "still sanitizes the masked-and-unrequested field on its own (#{order})" do
        record = account_class(order).create!(email: "<b>jack@example.com</b>")

        expect(record.as_json(sanitized: true)["email"]).to eq("jack@example.com")
      end
    end
  end

  describe "composition with Encryptable" do
    before do
      ConcernsOnRails.encryption.key = "concerns-on-rails-sanitizable-test-key"

      ActiveRecord::Schema.define do
        create_table :sanitizable_secrets, force: true do |t|
          t.text :note
          t.text :note_bidx
        end
      end
    end

    after { ConcernsOnRails.encryption.key = nil }

    it "refreshes the blind index when sanitize_all! rewrites an encrypted field" do
      klass = Class.new(TestModel) do
        self.table_name = "sanitizable_secrets"
        include ConcernsOnRails::Models::Encryptable
        include ConcernsOnRails::Models::Sanitizable

        encryptable :note, blind_index: true
        sanitizable :note, with: :strip, on: :write
      end
      record = klass.create!(note: "clean")
      # A write that bypassed both callbacks: raw markup at rest, fingerprinted raw.
      record.update_columns(note: "<b>dirty</b>", note_bidx: klass.note_fingerprint("<b>dirty</b>"))

      expect(klass.sanitize_all!).to eq(1)
      expect(record.reload.note).to eq("dirty")
      expect(klass.find_by_note("<b>dirty</b>")).to be_nil # the stale fingerprint is gone
      expect(klass.find_by_note("dirty")).to eq(record)
    end
  end
end
