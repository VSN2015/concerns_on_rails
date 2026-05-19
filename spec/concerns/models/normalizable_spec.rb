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
end
