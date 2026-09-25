require "spec_helper"

describe ConcernsOnRails::Models::Maskable do
  before do
    ActiveRecord::Schema.define do
      create_table :maskable_users, force: true do |t|
        t.string :email
        t.string :card
        t.string :phone
        t.string :ssn
        t.integer :age
      end

      create_table :maskable_profiles, force: true do |t|
        t.integer :maskable_user_id
        t.string :email
      end
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end

    %i[MaskableUser MaskableProfile].each do |const|
      Object.send(:remove_const, const) if Object.const_defined?(const)
    end
  end

  describe "presets (non-destructive readers)" do
    it ":email keeps the first char + domain and leaves the column raw" do
      class MaskableUser < TestModel
        self.table_name = "maskable_users"
        include ConcernsOnRails::Models::Maskable

        maskable :email, with: :email
      end

      user = MaskableUser.new(email: "john.doe@example.com")

      expect(user.masked_email).to eq("j*******@example.com")
      expect(user.email).to eq("john.doe@example.com") # raw column untouched
    end

    it ":credit_card keeps the last four digits" do
      class MaskableUser < TestModel
        self.table_name = "maskable_users"
        include ConcernsOnRails::Models::Maskable

        maskable :card, with: :credit_card
      end

      expect(MaskableUser.new(card: "4242424242424242").masked_card).to eq("**** **** **** 4242")
    end

    it ":phone keeps the last four digits" do
      class MaskableUser < TestModel
        self.table_name = "maskable_users"
        include ConcernsOnRails::Models::Maskable

        maskable :phone, with: :phone
      end

      expect(MaskableUser.new(phone: "+1 (415) 555-2671").masked_phone).to eq("***-2671")
    end

    # Fail closed: input that does not have the expected shape used to come
    # back UNMASKED (an email column holding a bare username, a phone column
    # holding "ext. four" or "1234"). It now gets the full mask.
    it "falls back to the full mask when a value is not email- or phone-shaped" do
      class MaskableUser < TestModel
        self.table_name = "maskable_users"
        include ConcernsOnRails::Models::Maskable

        maskable :email, with: :email
        maskable :phone, with: :phone
      end

      expect(MaskableUser.new(email: "johndoe").masked_email).to eq("*******")
      expect(MaskableUser.new(email: "").masked_email).to eq("")
      expect(MaskableUser.new(phone: "1234").masked_phone).to eq("****")
      expect(MaskableUser.new(phone: "x42").masked_phone).to eq("***")
      expect(MaskableUser.new(phone: "call me").masked_phone).to eq("*******")
      expect(MaskableUser.new(phone: "٤١٥٥٥٥٢٦٧١").masked_phone).to eq("*" * 10) # no ASCII digits
      expect(MaskableUser.new(phone: "555-2671").masked_phone).to eq("***-2671") # 7 digits still keep 4
      expect(MaskableUser.new(phone: "12345").masked_phone).to eq("***-2345")
    end

    it ":last4 honors a custom mask character" do
      class MaskableUser < TestModel
        self.table_name = "maskable_users"
        include ConcernsOnRails::Models::Maskable

        maskable :ssn, with: :last4, mask: "•"
      end

      expect(MaskableUser.new(ssn: "123456789").masked_ssn).to eq("•••••6789")
    end

    it ":all (the default) masks every character" do
      class MaskableUser < TestModel
        self.table_name = "maskable_users"
        include ConcernsOnRails::Models::Maskable

        maskable :ssn
      end

      expect(MaskableUser.new(ssn: "secret").masked_ssn).to eq("******")
    end

    it "returns nil when the column is nil" do
      class MaskableUser < TestModel
        self.table_name = "maskable_users"
        include ConcernsOnRails::Models::Maskable

        maskable :email, with: :email
      end

      expect(MaskableUser.new(email: nil).masked_email).to be_nil
    end

    it "passes non-string column values through untouched" do
      class MaskableUser < TestModel
        self.table_name = "maskable_users"
        include ConcernsOnRails::Models::Maskable

        maskable :age, with: :all
      end

      expect(MaskableUser.new(age: 42).masked_age).to eq(42)
    end
  end

  describe "custom proc" do
    it "uses the proc as-is" do
      class MaskableUser < TestModel
        self.table_name = "maskable_users"
        include ConcernsOnRails::Models::Maskable

        maskable :ssn, with: ->(v) { "#{v.to_s[0, 2]}…" }
      end

      expect(MaskableUser.new(ssn: "123456").masked_ssn).to eq("12…")
    end
  end

  describe "configuration errors" do
    it "raises on an unknown preset" do
      expect do
        class MaskableUser < TestModel
          self.table_name = "maskable_users"
          include ConcernsOnRails::Models::Maskable

          maskable :email, with: :encrypt
        end
      end.to raise_error(ArgumentError, /unknown preset/)
    end

    it "raises when :with is neither a symbol nor a Proc" do
      expect do
        class MaskableUser < TestModel
          self.table_name = "maskable_users"
          include ConcernsOnRails::Models::Maskable

          maskable :email, with: 123
        end
      end.to raise_error(ArgumentError, /must be a preset symbol or a Proc/)
    end

    it "raises when no fields are given" do
      expect do
        class MaskableUser < TestModel
          self.table_name = "maskable_users"
          include ConcernsOnRails::Models::Maskable

          maskable with: :all
        end
      end.to raise_error(ArgumentError, /at least one field is required/)
    end

    it "raises when the column does not exist" do
      expect do
        class MaskableUser < TestModel
          self.table_name = "maskable_users"
          include ConcernsOnRails::Models::Maskable

          maskable :nonexistent, with: :all
        end
      end.to raise_error(ArgumentError, /does not exist in the database/)
    end
  end

  describe "masked serialization (masked_attributes / as_json(masked:))" do
    let(:user) do
      class MaskableUser < TestModel
        self.table_name = "maskable_users"
        include ConcernsOnRails::Models::Maskable

        maskable :email, with: :email
        maskable :card,  with: :credit_card
        maskable :phone, with: :phone
      end
      MaskableUser.create!(email: "john.doe@example.com", card: "4242424242424242", phone: "+1 (415) 555-2671",
                           ssn: "123456789", age: 30)
    end

    it "masked_attributes returns every declared field masked, keyed like `attributes`" do
      expect(user.masked_attributes).to eq(
        "email" => "j*******@example.com", "card" => "**** **** **** 4242", "phone" => "***-2671"
      )
      expect(user.email).to eq("john.doe@example.com")
    end

    it "as_json(masked: true) swaps the declared fields for their masked form and leaves everything else raw" do
      json = user.as_json(masked: true)
      expect(json.slice("email", "card", "phone")).to eq(
        "email" => "j*******@example.com", "card" => "**** **** **** 4242", "phone" => "***-2671"
      )
      expect(json["ssn"]).to eq("123456789") # not declared maskable → untouched
      expect(json["age"]).to eq(30)
      expect(json["id"]).to eq(user.id)
    end

    it "leaves as_json / to_json untouched without the option" do
      expect(user.as_json["email"]).to eq("john.doe@example.com")
      expect(JSON.parse(user.to_json)["card"]).to eq("4242424242424242")
    end

    it "masked: accepts a subset of the declared fields" do
      json = user.as_json(masked: [:email])
      expect(json["email"]).to eq("j*******@example.com")
      expect(json["card"]).to eq("4242424242424242")
      expect(user.as_json(masked: "card")["card"]).to eq("**** **** **** 4242")
    end

    it "composes with only:/except:/methods: and to_json" do
      json = user.as_json(only: %i[email age], masked: true)
      expect(json).to eq("email" => "j*******@example.com", "age" => 30)
      expect(user.as_json(except: [:email], masked: true)).not_to have_key("email")
      parsed = JSON.parse(user.to_json(masked: true, methods: :masked_email))
      expect(parsed.values_at("email", "masked_email")).to eq(["j*******@example.com", "j*******@example.com"])
    end

    it "carries masked: into a nested include: instead of serializing the child raw" do
      parent = user # defines MaskableUser before the association is declared

      class MaskableProfile < TestModel
        self.table_name = "maskable_profiles"
        include ConcernsOnRails::Models::Maskable

        maskable :email, with: :email
      end
      MaskableUser.has_many :maskable_profiles, class_name: "MaskableProfile", foreign_key: :maskable_user_id
      MaskableProfile.create!(maskable_user_id: parent.id, email: "secret.person@example.com")

      json = parent.as_json(masked: true, include: :maskable_profiles)
      expect(json["maskable_profiles"].first["email"]).to eq("s************@example.com")

      # an explicit per-child setting still wins
      raw = parent.as_json(masked: true, include: { maskable_profiles: { masked: false } })
      expect(raw["maskable_profiles"].first["email"]).to eq("secret.person@example.com")
    end

    it "masks the serialized value, not the raw column" do
      klass = Class.new(TestModel) do
        self.table_name = "maskable_users"
        include ConcernsOnRails::Models::Maskable

        maskable :email, with: ->(value) { "[#{value}]" }

        def email
          super.to_s.upcase # an overridden reader is what as_json serializes
        end
      end
      record = klass.create!(email: "john.doe@example.com")
      expect(record.as_json(masked: true)["email"]).to eq("[JOHN.DOE@EXAMPLE.COM]")
    end

    it "rejects a masked: shape that is neither true nor a field list" do
      expect { user.as_json(masked: { email: true }) }
        .to raise_error(ArgumentError, /masked: takes true or a list of declared fields, got Hash/)
    end

    it "raises for an undeclared field in masked:" do
      expect { user.as_json(masked: [:ssn]) }
        .to raise_error(ArgumentError, /ssn is not a maskable field \(declared: email, card, phone\)/)
    end

    it "masks nil values as nil" do
      user.update!(card: nil)
      expect(user.masked_attributes["card"]).to be_nil
      expect(user.as_json(masked: true)["card"]).to be_nil
    end
  end
end
