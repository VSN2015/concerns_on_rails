require "spec_helper"

describe ConcernsOnRails::Models::Normalizable do
  before do
    ActiveRecord::Schema.define do
      create_table :users, force: true do |t|
        t.string :email
        t.string :phone
        t.string :first_name
        t.string :last_name
        t.string :bio
        t.string :code
        t.integer :age
      end
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end

    Object.send(:remove_const, :User) if Object.const_defined?(:User)
  end

  describe "presets" do
    it "applies the :email preset (strip + downcase)" do
      class User < TestModel
        self.table_name = "users"
        include ConcernsOnRails::Models::Normalizable

        normalizable :email, with: :email
      end

      user = User.new(email: "  FOO@Bar.com  ")
      user.valid?
      expect(user.email).to eq("foo@bar.com")
    end

    it "applies the :phone preset (digits only)" do
      class User < TestModel
        self.table_name = "users"
        include ConcernsOnRails::Models::Normalizable

        normalizable :phone, with: :phone
      end

      user = User.new(phone: "+1 (415) 555-2671")
      user.valid?
      expect(user.phone).to eq("14155552671")
    end

    it "applies the :whitespace preset (strip)" do
      class User < TestModel
        self.table_name = "users"
        include ConcernsOnRails::Models::Normalizable

        normalizable :first_name, with: :whitespace
      end

      user = User.new(first_name: "   Alice   ")
      user.valid?
      expect(user.first_name).to eq("Alice")
    end

    it "applies the :squish preset (collapses inner whitespace)" do
      class User < TestModel
        self.table_name = "users"
        include ConcernsOnRails::Models::Normalizable

        normalizable :bio, with: :squish
      end

      user = User.new(bio: "  hello   world  ")
      user.valid?
      expect(user.bio).to eq("hello world")
    end

    it "applies the :downcase preset" do
      class User < TestModel
        self.table_name = "users"
        include ConcernsOnRails::Models::Normalizable

        normalizable :code, with: :downcase
      end

      user = User.new(code: "ABC123")
      user.valid?
      expect(user.code).to eq("abc123")
    end

    it "applies the :upcase preset" do
      class User < TestModel
        self.table_name = "users"
        include ConcernsOnRails::Models::Normalizable

        normalizable :code, with: :upcase
      end

      user = User.new(code: "abc123")
      user.valid?
      expect(user.code).to eq("ABC123")
    end
  end

  describe "custom lambda normalizer" do
    it "calls the lambda with the field value" do
      class User < TestModel
        self.table_name = "users"
        include ConcernsOnRails::Models::Normalizable

        normalizable :code, with: ->(v) { v.to_s.tr("-", "_").upcase }
      end

      user = User.new(code: "abc-def")
      user.valid?
      expect(user.code).to eq("ABC_DEF")
    end
  end

  describe "multiple fields in one declaration" do
    it "normalizes every listed field with the same rule" do
      class User < TestModel
        self.table_name = "users"
        include ConcernsOnRails::Models::Normalizable

        normalizable :first_name, :last_name, with: :whitespace
      end

      user = User.new(first_name: "  Alice  ", last_name: "  Smith  ")
      user.valid?
      expect(user.first_name).to eq("Alice")
      expect(user.last_name).to eq("Smith")
    end
  end

  describe "nil and non-string handling" do
    it "leaves nil values alone" do
      class User < TestModel
        self.table_name = "users"
        include ConcernsOnRails::Models::Normalizable

        normalizable :email, with: :email
      end

      user = User.new(email: nil)
      user.valid?
      expect(user.email).to be_nil
    end

    it "passes non-string values through preset normalizers unchanged" do
      class User < TestModel
        self.table_name = "users"
        include ConcernsOnRails::Models::Normalizable

        normalizable :age, with: :downcase
      end

      user = User.new(age: 30)
      user.valid?
      expect(user.age).to eq(30)
    end
  end

  describe "validation timing" do
    it "runs in before_validation so validations see normalized values" do
      class User < TestModel
        self.table_name = "users"
        include ConcernsOnRails::Models::Normalizable

        normalizable :email, with: :email
        validates :email, format: { with: /\A[a-z0-9.+_-]+@[a-z0-9.-]+\z/ }
      end

      user = User.new(email: "  ALICE@Example.com  ")
      expect(user.valid?).to be true
      expect(user.email).to eq("alice@example.com")
    end
  end

  describe "configuration errors" do
    it "raises when the field column does not exist" do
      expect do
        class User < TestModel
          self.table_name = "users"
          include ConcernsOnRails::Models::Normalizable

          normalizable :nonexistent, with: :email
        end
      end.to raise_error(ArgumentError, /does not exist in the database/)
    end

    it "raises when no fields are given" do
      expect do
        class User < TestModel
          self.table_name = "users"
          include ConcernsOnRails::Models::Normalizable

          normalizable with: :email
        end
      end.to raise_error(ArgumentError, /at least one field is required/)
    end

    it "raises when :with refers to an unknown preset" do
      expect do
        class User < TestModel
          self.table_name = "users"
          include ConcernsOnRails::Models::Normalizable

          normalizable :email, with: :flarbgnarb
        end
      end.to raise_error(ArgumentError, /unknown preset/)
    end

    it "raises when :with is neither a symbol nor a Proc" do
      expect do
        class User < TestModel
          self.table_name = "users"
          include ConcernsOnRails::Models::Normalizable

          normalizable :email, with: "downcase"
        end
      end.to raise_error(ArgumentError, /must be a preset symbol or a Proc/)
    end
  end

  describe "multiple normalizable declarations on the same model" do
    it "applies all declared rules" do
      class User < TestModel
        self.table_name = "users"
        include ConcernsOnRails::Models::Normalizable

        normalizable :email, with: :email
        normalizable :phone, with: :phone
        normalizable :first_name, :last_name, with: :whitespace
      end

      user = User.new(
        email: "  FOO@bar.com  ",
        phone: "+1 (415) 555-1234",
        first_name: "  Alice  ",
        last_name: "  Smith  "
      )
      user.valid?

      expect(user.email).to eq("foo@bar.com")
      expect(user.phone).to eq("14155551234")
      expect(user.first_name).to eq("Alice")
      expect(user.last_name).to eq("Smith")
    end
  end

  describe "chained normalizers, extra presets and Model.normalize" do
    before do
      ActiveRecord::Schema.define do
        create_table :normalizable_extras, force: true do |t|
          t.string :name
          t.text :bio
          t.string :slug
          t.string :website
          t.string :title
          t.string :note
        end
      end
      stub_const("NormalizableExtra", Class.new(TestModel) do
        self.table_name = "normalizable_extras"
        include ConcernsOnRails::Models::Normalizable

        normalizable :name,    with: %i[squish titleize]
        normalizable :bio,     with: %i[squish nullify_blank]
        normalizable :slug,    with: :parameterize
        normalizable :website, with: :url
        normalizable :title,   with: :capitalize
        normalizable :note,    with: [:strip, ->(v) { "#{v}!" }]
      end)
    end

    def normalized(attrs)
      record = NormalizableExtra.new(attrs)
      record.valid?
      record
    end

    it "applies an Array of presets and callables left to right" do
      expect(normalized(name: "  alice   SMITH ").name).to eq("Alice Smith")
      expect(normalized(note: "  abc ").note).to eq("abc!")
    end

    it ":nullify_blank turns blank strings into nil and leaves content alone" do
      expect(normalized(bio: "   ").bio).to be_nil
      expect(normalized(bio: "").bio).to be_nil
      expect(normalized(bio: "  hi   there ").bio).to eq("hi there")
    end

    it ":parameterize, :capitalize and :titleize" do
      expect(normalized(slug: "Hello World!").slug).to eq("hello-world")
      expect(normalized(title: "hELLO").title).to eq("Hello")
      expect(NormalizableExtra.normalize(:name, "jane doe")).to eq("Jane Doe")
    end

    it ":url defaults the scheme to https, lowercases scheme + host, keeps the path and rejects nothing" do
      expect(normalized(website: "  Example.COM/Some/Path ").website).to eq("https://example.com/Some/Path")
      expect(normalized(website: "HTTP://Foo.Bar:8080/X?q=Y").website).to eq("http://foo.bar:8080/X?q=Y")
      expect(normalized(website: "mailto:Someone@Example.com").website).to eq("mailto:Someone@Example.com")
      expect(normalized(website: "localhost:3000/admin").website).to eq("https://localhost:3000/admin")
      expect(normalized(website: "not a url ").website).to eq("not a url") # left for a format validator to reject
      expect(normalized(website: "   ").website).to eq("")
    end

    it "Model.normalize(field, value) applies a field's rule outside a record (lookups, params)" do
      expect(NormalizableExtra.normalize(:name, " bob   jones ")).to eq("Bob Jones")
      expect(NormalizableExtra.normalize("website", "Example.com")).to eq("https://example.com")
      expect(NormalizableExtra.normalize(:bio, nil)).to be_nil
      expect { NormalizableExtra.normalize(:zzz, "x") }
        .to raise_error(ArgumentError, /no normalization rule for :zzz \(declared: name, bio, slug, website, title, note\)/)
    end

    it "validates every entry of an Array at class load" do
      build = lambda do |with|
        Class.new(TestModel) do
          self.table_name = "normalizable_extras"
          include ConcernsOnRails::Models::Normalizable

          normalizable :name, with: with
        end
      end
      expect { build.call(%i[squish bogus]) }.to raise_error(ArgumentError, /unknown preset 'bogus'/)
      expect { build.call([]) }.to raise_error(ArgumentError, /with: \[\] needs at least one normalizer/)
      expect { build.call([:squish, "downcase"]) }.to raise_error(ArgumentError, /must be a preset symbol or a Proc/)
    end
  end
end
