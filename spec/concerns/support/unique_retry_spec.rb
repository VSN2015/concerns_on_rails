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
end
