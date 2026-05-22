require "spec_helper"

describe ConcernsOnRails::Tokenizable do
  before do
    ActiveRecord::Schema.define do
      create_table :accounts, force: true do |t|
        t.string :name
        t.string :api_token
        t.string :reset_password_token
      end
    end

    class Account < TestModel
      include ConcernsOnRails::Tokenizable

      tokenizable_by :api_token
      tokenizable_by :reset_password_token, length: 24
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end

    %i[Account HexAccount AlphaAccount NumericAccount NoColumnAccount BadTypeAccount BadLengthAccount].each do |const|
      Object.send(:remove_const, const) if Object.const_defined?(const)
    end
  end

  describe "default :urlsafe" do
    it "auto-generates a URL-safe token of the configured length on create" do
      account = Account.create!(name: "A")
      expect(account.api_token).to be_a(String)
      expect(account.api_token.length).to eq(32)
      expect(account.api_token).to match(/\A[A-Za-z0-9_-]+\z/)
    end

    it "generates distinct values for different records" do
      a = Account.create!(name: "A")
      b = Account.create!(name: "B")
      expect(a.api_token).not_to eq(b.api_token)
    end

    it "does not overwrite a value supplied by the caller" do
      account = Account.create!(name: "Manual", api_token: "preset-value")
      expect(account.api_token).to eq("preset-value")
    end

    it "generates each configured field independently" do
      account = Account.create!(name: "Multi")
      expect(account.api_token.length).to eq(32)
      expect(account.reset_password_token.length).to eq(24)
      expect(account.api_token).not_to eq(account.reset_password_token)
    end
  end

  describe "generated instance helpers" do
    it "defines regenerate_<field>! that replaces and persists the value" do
      account = Account.create!(name: "R")
      original = account.api_token
      account.regenerate_api_token!
      expect(account.reload.api_token).not_to eq(original)
      expect(account.api_token.length).to eq(32)
    end

    it "defines revoke_<field>! that nils the column" do
      account = Account.create!(name: "Rev")
      expect(account.api_token).to be_present
      account.revoke_api_token!
      expect(account.reload.api_token).to be_nil
    end

    it "defines <field>? predicate" do
      account = Account.create!(name: "P")
      expect(account.api_token?).to be true
      account.revoke_api_token!
      expect(account.api_token?).to be false
    end
  end

  describe ".authenticate_by_<field>" do
    it "returns the matching record when the token matches" do
      account = Account.create!(name: "Auth")
      expect(Account.authenticate_by_api_token(account.api_token)).to eq(account)
    end

    it "returns nil for a non-matching token" do
      Account.create!(name: "Auth")
      expect(Account.authenticate_by_api_token("not-a-real-token-value-1234567890")).to be_nil
    end

    it "returns nil for blank input" do
      Account.create!(name: "Auth")
      expect(Account.authenticate_by_api_token(nil)).to be_nil
      expect(Account.authenticate_by_api_token("")).to be_nil
    end
  end

  describe "type: :hex" do
    it "produces a hex string of exactly the configured length" do
      ActiveRecord::Schema.define do
        create_table :hex_accounts, force: true do |t|
          t.string :code
        end
      end

      class HexAccount < TestModel
        include ConcernsOnRails::Tokenizable

        tokenizable_by :code, type: :hex, length: 10
      end

      account = HexAccount.create!
      expect(account.code).to match(/\A[0-9a-f]{10}\z/)
    end
  end

  describe "type: :alphanumeric" do
    it "samples only from A-Z, a-z, 0-9 and respects length" do
      ActiveRecord::Schema.define do
        create_table :alpha_accounts, force: true do |t|
          t.string :invite_code
        end
      end

      class AlphaAccount < TestModel
        include ConcernsOnRails::Tokenizable

        tokenizable_by :invite_code, type: :alphanumeric, length: 8
      end

      account = AlphaAccount.create!
      expect(account.invite_code.length).to eq(8)
      expect(account.invite_code).to match(/\A[A-Za-z0-9]{8}\z/)
    end
  end

  describe "type: :numeric" do
    it "samples only from 0-9 and respects length" do
      ActiveRecord::Schema.define do
        create_table :numeric_accounts, force: true do |t|
          t.string :pin
        end
      end

      class NumericAccount < TestModel
        include ConcernsOnRails::Tokenizable

        tokenizable_by :pin, type: :numeric, length: 6
      end

      account = NumericAccount.create!
      expect(account.pin).to match(/\A\d{6}\z/)
    end
  end

  describe "uniqueness retry on collision" do
    it "retries when a generated value already exists, then succeeds" do
      existing = Account.create!(name: "Existing")
      allow(SecureRandom).to receive(:urlsafe_base64).and_return(
        "#{existing.api_token}padding",
        "fresh-unique-value-1234567890123456"
      )

      account = Account.create!(name: "New")
      expect(account.api_token).to eq("fresh-unique-value-1234567890123"[0, 32])
    end

    it "raises after MAX_GENERATION_ATTEMPTS consecutive collisions" do
      existing = Account.create!(name: "Existing")
      allow(SecureRandom).to receive(:urlsafe_base64).and_return("#{existing.api_token}padding")

      expect { Account.create!(name: "New") }.to raise_error(
        /could not generate a unique value/
      )
    end
  end

  describe "validation" do
    it "raises if the field does not exist on the table" do
      ActiveRecord::Schema.define do
        create_table :no_column_accounts, force: true do |t|
          t.string :name
        end
      end

      expect do
        class NoColumnAccount < TestModel
          include ConcernsOnRails::Tokenizable

          tokenizable_by :missing_field
        end
      end.to raise_error(ArgumentError, /does not exist in the database/)
    end

    it "raises on an unknown type" do
      ActiveRecord::Schema.define do
        create_table :bad_type_accounts, force: true do |t|
          t.string :token
        end
      end

      expect do
        class BadTypeAccount < TestModel
          include ConcernsOnRails::Tokenizable

          tokenizable_by :token, type: :base64
        end
      end.to raise_error(ArgumentError, /unknown type/)
    end

    it "raises when length is not positive" do
      ActiveRecord::Schema.define do
        create_table :bad_length_accounts, force: true do |t|
          t.string :token
        end
      end

      expect do
        class BadLengthAccount < TestModel
          include ConcernsOnRails::Tokenizable

          tokenizable_by :token, length: 0
        end
      end.to raise_error(ArgumentError, /length must be a positive integer/)
    end
  end
end
