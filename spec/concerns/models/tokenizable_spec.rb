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
  describe "expires_in: (expiring tokens) and consume_<field> (single use)" do
    before do
      ActiveRecord::Schema.define do
        create_table :reset_accounts, force: true do |t|
          t.string :email
          t.string :reset_token
          t.datetime :reset_token_expires_at
          t.string :invite_code
        end
      end
    end

    let(:klass) do
      Class.new(TestModel) do
        self.table_name = "reset_accounts"
        include ConcernsOnRails::Tokenizable

        tokenizable_by :reset_token, length: 24, expires_in: 2.hours
        tokenizable_by :invite_code, type: :alphanumeric, length: 8
      end
    end

    it "stamps <field>_expires_at on create and on regenerate" do
      account = travel_to(Time.utc(2026, 5, 1, 10)) { klass.create!(email: "a@x.com") }
      expect(account.reset_token_expires_at).to eq(Time.utc(2026, 5, 1, 12))

      travel_to(Time.utc(2026, 5, 2, 10)) { account.regenerate_reset_token! }
      expect(account.reload.reset_token_expires_at).to eq(Time.utc(2026, 5, 2, 12))
    end

    it "gives a caller-supplied token the configured lifetime unless the caller also set an expiry" do
      supplied = travel_to(Time.utc(2026, 5, 1, 10)) { klass.create!(reset_token: "preset-token-value-12345") }
      expect(supplied.reset_token).to eq("preset-token-value-12345")
      expect(supplied.reset_token_expires_at).to eq(Time.utc(2026, 5, 1, 12))

      explicit = klass.create!(reset_token: "another-preset-token-123", reset_token_expires_at: Time.utc(2030, 1, 1))
      expect(explicit.reset_token_expires_at).to eq(Time.utc(2030, 1, 1))
    end

    it "revoke_<field>! clears the expiry too" do
      account = klass.create!
      account.revoke_reset_token!
      account.reload
      expect(account.reset_token).to be_nil
      expect(account.reset_token_expires_at).to be_nil
    end

    it "<field>_expired? flips at the boundary; a token without an expiry never expires" do
      account = travel_to(Time.utc(2026, 5, 1, 10)) { klass.create! }
      travel_to(Time.utc(2026, 5, 1, 11, 59)) { expect(account.reset_token_expired?).to be(false) }
      travel_to(Time.utc(2026, 5, 1, 12)) { expect(account.reset_token_expired?).to be(true) }

      account.update_columns(reset_token_expires_at: nil)
      travel_to(Time.utc(2030, 1, 1)) { expect(account.reset_token_expired?).to be(false) }
      expect(klass.create!.invite_code_expired?).to be(false) # field without expires_in:
    end

    it "authenticate_by_<field> refuses an expired token" do
      account = travel_to(Time.utc(2026, 5, 1, 10)) { klass.create! }
      travel_to(Time.utc(2026, 5, 1, 11)) { expect(klass.authenticate_by_reset_token(account.reset_token)).to eq(account) }
      travel_to(Time.utc(2026, 5, 1, 13)) { expect(klass.authenticate_by_reset_token(account.reset_token)).to be_nil }
    end

    it "consume_<field> authenticates once and revokes the token (single use)" do
      account = klass.create!
      token = account.reset_token
      consumed = klass.consume_reset_token(token)
      expect(consumed).to eq(account)
      expect(consumed.reset_token).to be_nil
      expect(consumed.reset_token_expires_at).to be_nil
      expect(klass.consume_reset_token(token)).to be_nil
      expect(klass.authenticate_by_reset_token(token)).to be_nil
    end

    it "consume_<field> is atomic — the row is revoked with a conditional UPDATE, so a second consumer loses" do
      account = klass.create!
      token = account.reset_token
      # Simulate the race: someone else consumed it between our authenticate and our UPDATE.
      allow(klass).to receive(:authenticate_by_reset_token).and_wrap_original do |original, value|
        record = original.call(value)
        klass.where(id: record.id).update_all(reset_token: nil, reset_token_expires_at: nil) if record
        record
      end
      expect(klass.consume_reset_token(token)).to be_nil
    end

    it "consume_<field> returns nil for a wrong, blank or expired token" do
      account = travel_to(Time.utc(2026, 5, 1, 10)) { klass.create! }
      expect(klass.consume_reset_token("nope")).to be_nil
      expect(klass.consume_reset_token(nil)).to be_nil
      travel_to(Time.utc(2026, 5, 1, 13)) { expect(klass.consume_reset_token(account.reset_token)).to be_nil }
      expect(account.reload.reset_token).to be_present # an expired token is not consumed
    end

    it "consume_<field> works for fields without expires_in: (invite codes)" do
      account = klass.create!
      expect(klass.consume_invite_code(account.invite_code)).to eq(account)
      expect(account.reload.invite_code).to be_nil
    end

    it "defines an <field>_expired scope for cleanup" do
      stale = travel_to(Time.utc(2026, 5, 1, 10)) { klass.create! }
      fresh = klass.create!
      travel_to(Time.utc(2026, 5, 1, 13)) do
        expect(klass.reset_token_expired).to eq([stale])
        expect(klass.reset_token_expired).not_to include(fresh)
      end
      expect(klass).not_to respond_to(:invite_code_expired)
    end

    it "records expires_in (seconds) in the field config" do
      expect(klass.tokenizable_fields[:reset_token]).to include(expires_in: 7200)
      expect(klass.tokenizable_fields[:invite_code]).to include(expires_in: nil)
    end

    it "requires the <field>_expires_at column with a typed migration hint" do
      expect do
        Class.new(TestModel) do
          self.table_name = "reset_accounts"
          include ConcernsOnRails::Tokenizable

          tokenizable_by :invite_code, expires_in: 1.day
        end
      end.to raise_error(ArgumentError, /invite_code_expires_at.*does not exist.*invite_code_expires_at:datetime/)
    end

    it "rejects a non-positive expires_in:" do
      expect do
        Class.new(TestModel) do
          self.table_name = "reset_accounts"
          include ConcernsOnRails::Tokenizable

          tokenizable_by :reset_token, expires_in: 0
        end
      end.to raise_error(ArgumentError, /expires_in must be a positive Duration or number of seconds/)
    end
  end
end
