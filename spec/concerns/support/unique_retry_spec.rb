require "spec_helper"

RSpec.describe ConcernsOnRails::Support::UniqueRetry do
  it "yields once on success" do
    calls = 0
    result = described_class.with_retries do
      calls += 1
      :ok
    end
    expect(result).to eq(:ok)
    expect(calls).to eq(1)
  end

  it "retries on RecordNotUnique and re-raises at the limit" do
    calls = 0
    expect do
      described_class.with_retries(limit: 3) do
        calls += 1
        raise ActiveRecord::RecordNotUnique, "dup"
      end
    end.to raise_error(ActiveRecord::RecordNotUnique)
    expect(calls).to eq(3)
  end

  it "succeeds when a retry attempt goes through" do
    calls = 0
    result = described_class.with_retries(limit: 3) do
      calls += 1
      raise ActiveRecord::RecordNotUnique, "dup" if calls < 3

      :recovered
    end
    expect(result).to eq(:recovered)
    expect(calls).to eq(3)
  end

  it "propagates unrelated errors immediately" do
    calls = 0
    expect do
      described_class.with_retries do
        calls += 1
        raise ArgumentError, "not a uniqueness problem"
      end
    end.to raise_error(ArgumentError)
    expect(calls).to eq(1)
  end

  describe "regenerate_<field>! against a real unique index (1.22)" do
    before do
      ActiveRecord::Schema.define do
        create_table :unique_retry_tokens, force: true do |t|
          t.string :api_token
        end
        add_index :unique_retry_tokens, :api_token, unique: true
      end
    end

    after { ActiveRecord::Base.connection.drop_table(:unique_retry_tokens) }

    let(:klass) do
      Class.new(TestModel) do
        self.table_name = "unique_retry_tokens"
        include ConcernsOnRails::Models::Tokenizable

        tokenizable_by :api_token, type: :hex, length: 8
      end
    end

    it "retries into a fresh value when the DB index rejects the first candidate" do
      taken = klass.create!(api_token: "aaaaaaaa")
      record = klass.create!(api_token: "bbbbbbbb")

      # Hand regenerate a colliding candidate first (bypassing the in-Ruby
      # exists? precheck) so the real unique index raises RecordNotUnique —
      # the pre-1.22 regenerate had no retry and blew up here.
      allow(record).to receive(:tokenizable_unique_value).and_return(taken.api_token, "cccccccc")

      record.regenerate_api_token!
      expect(record.reload.api_token).to eq("cccccccc")
    end
  end

  describe "savepoint: (1.29 audit)" do
    before do
      ActiveRecord::Schema.define do
        create_table :unique_retry_codes, force: true do |t|
          t.string :code
        end
        add_index :unique_retry_codes, :code, unique: true
      end
    end

    after { ActiveRecord::Base.connection.drop_table(:unique_retry_codes) }

    let(:klass) { Class.new(TestModel) { self.table_name = "unique_retry_codes" } }

    it "runs each attempt in its own savepoint so a caller's transaction survives the rejected write" do
      klass.create!(code: "taken")
      candidates = %w[taken fresh]
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*args| statements << args.last[:sql].to_s }

      begin
        ActiveRecord::Base.transaction do
          # A write first, so the outer transaction is materialized (Rails 7.1+
          # otherwise restarts a still-empty parent instead of using a savepoint).
          klass.create!(code: "before")
          described_class.with_retries(savepoint: klass) { klass.create!(code: candidates.shift) }
          klass.create!(code: "after") # the outer transaction is still usable
        end
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(klass.order(:id).pluck(:code)).to eq(%w[taken before fresh after])
      expect(statements.grep(/\AROLLBACK TO SAVEPOINT/i).size).to eq(1)
    end
  end
end
