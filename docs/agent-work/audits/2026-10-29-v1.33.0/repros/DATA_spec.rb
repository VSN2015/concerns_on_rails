require "spec_helper"

# DATA slice audit repros, concerns_on_rails v1.33.0. Written by a read-only
# auditor and NOT yet run — each example should FAIL on current master.
describe "DATA audit repros" do
  after(:each) do
    ConcernsOnRails.encryption.key = nil
    ConcernsOnRails.encryption.on_missing_key = :raise
    ConcernsOnRails.encryption.raise_on_decrypt_error = true
    ConcernsOnRails.encryption.key_id = 0
    ConcernsOnRails.encryption.previous_keys = {}
  end

  context "DATA-1 composite primary keys in Lockable / Tokenizable", min_rails: "7.1" do
    before do
      ActiveRecord::Schema.define do
        create_table :data_cpk_users, primary_key: %i[shop_id id], force: true do |t|
          t.integer :shop_id
          t.integer :id
          t.integer :failed_attempts, default: 0
          t.datetime :locked_at
          t.string :unlock_token
          t.string :api_token
        end
      end
    end

    after { ActiveRecord::Base.connection.drop_table(:data_cpk_users, if_exists: true) }

    let(:klass) do
      Class.new(TestModel) do
        self.table_name = "data_cpk_users"
        include ConcernsOnRails::Models::Lockable
        include ConcernsOnRails::Models::Tokenizable

        lockable_by max_attempts: 2, unlock_token: :unlock_token
        tokenizable_by :api_token
      end
    end

    it "DATA-1a register_failed_attempt! counts a failure on a composite-key row" do
      user = klass.create!(id: [1, 1])
      expect(user.register_failed_attempt!).to eq(1)
    end

    it "DATA-1b lock_access! locks a composite-key row" do
      user = klass.create!(id: [1, 1])
      expect(user.lock_access!).to be(true)
      expect(klass.find([1, 1]).locked_at).not_to be_nil
    end

    it "DATA-1c unlock_by_token unlocks a composite-key row" do
      user = klass.create!(id: [1, 1], locked_at: Time.current, unlock_token: "tok")
      expect(klass.unlock_by_token("tok")).to eq(user)
      expect(klass.find([1, 1]).locked_at).to be_nil
    end

    it "DATA-1d consume_<field> consumes a composite-key row's token" do
      user = klass.create!(id: [1, 1])
      expect(klass.consume_api_token(user.api_token)).to eq(user)
      expect(klass.find([1, 1]).api_token).to be_nil
    end
  end

  context "DATA-2 per-field key: Proc resolving to nil" do
    before do
      ActiveRecord::Schema.define do
        create_table(:data_field_keys, force: true) { |t| t.text :ssn }
      end
      ConcernsOnRails.encryption.key = "data-audit-global-key"
    end

    after { ActiveRecord::Base.connection.drop_table(:data_field_keys, if_exists: true) }

    def field_keyed_model(key_proc)
      Class.new(TestModel) do
        self.table_name = "data_field_keys"
        include ConcernsOnRails::Models::Encryptable

        encryptable :ssn, key: key_proc
      end
    end

    it "DATA-2a refuses to encrypt under the global key when the field's own key is missing" do
      klass = field_keyed_model(-> { nil })
      expect { klass.create!(ssn: "123-45-6789") }.to raise_error(ConcernsOnRails::Encryption::MissingKeyError)
    end

    it "DATA-2b a row written while the field key was missing stays readable once it appears" do
      field_key = nil
      klass = field_keyed_model(-> { field_key })
      id = klass.create!(ssn: "123-45-6789").id
      field_key = "data-audit-field-key"
      expect(klass.find(id).ssn).to eq("123-45-6789")
    end
  end

  context "DATA-3 NUL byte in a looked-up token" do
    before do
      skip "PostgreSQL only (the pg driver refuses NUL in bound text)" unless ActiveRecord::Base.connection.adapter_name.match?(/postg/i)
      ActiveRecord::Schema.define do
        create_table :data_nul_tokens, force: true do |t|
          t.string :api_token
          t.integer :failed_attempts, default: 0
          t.datetime :locked_at
          t.string :unlock_token
        end
      end
    end

    after { ActiveRecord::Base.connection.drop_table(:data_nul_tokens, if_exists: true) }

    let(:klass) do
      Class.new(TestModel) do
        self.table_name = "data_nul_tokens"
        include ConcernsOnRails::Models::Tokenizable
        include ConcernsOnRails::Models::Lockable

        tokenizable_by :api_token
        lockable_by unlock_token: :unlock_token
      end
    end

    it "DATA-3 answers nil, not a database error" do
      klass.create!
      expect(klass.authenticate_by_api_token("a\u0000b")).to be_nil
      expect(klass.consume_api_token("a\u0000b")).to be_nil
      expect(klass.unlock_by_token("a\u0000b")).to be_nil
    end
  end

  context "DATA-4 Lockable on a readonly record" do
    before do
      ActiveRecord::Schema.define do
        create_table :data_ro_users, force: true do |t|
          t.integer :failed_attempts, default: 0
          t.datetime :locked_at
        end
      end
    end

    after { ActiveRecord::Base.connection.drop_table(:data_ro_users, if_exists: true) }

    it "DATA-4 register_failed_attempt! writes nothing for a readonly! record" do
      klass = Class.new(TestModel) do
        self.table_name = "data_ro_users"
        include ConcernsOnRails::Models::Lockable

        lockable_by max_attempts: 1
      end
      id = klass.create!.id
      record = klass.find(id)
      record.readonly!

      expect { record.register_failed_attempt! }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect(klass.find(id).failed_attempts).to eq(0)
    end
  end
end
