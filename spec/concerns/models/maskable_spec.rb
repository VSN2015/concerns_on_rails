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
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end

    Object.send(:remove_const, :MaskableUser) if Object.const_defined?(:MaskableUser)
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
