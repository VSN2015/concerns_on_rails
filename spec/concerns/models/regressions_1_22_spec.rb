require "spec_helper"

# Proof specs for the 1.22 performance fixes: each asserts the mechanism
# (statement counts, parse counts, KDF invocations), not just the outcome, so
# a regression to the old behavior fails loudly.
RSpec.describe "1.22 model-side regression proofs" do
  def capture_sql
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
      statements << args.last[:sql].to_s
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  describe "SoftDeletable batch operations" do
    before do
      ActiveRecord::Schema.define do
        create_table :regress_soft_rows, force: true do |t|
          t.string :name
          t.datetime :deleted_at
        end
      end
    end

    after { ActiveRecord::Base.connection.drop_table(:regress_soft_rows) }

    let(:fast_klass) do
      Class.new(TestModel) do
        self.table_name = "regress_soft_rows"
        include ConcernsOnRails::Models::SoftDeletable

        soft_deletable_by :deleted_at, touch: false
      end
    end

    it "soft_delete_all fast path is one UPDATE, no row loads, returning the count" do
      3.times { |i| fast_klass.create!(name: "r#{i}") }

      count = nil
      statements = capture_sql { count = fast_klass.soft_delete_all }

      expect(count).to eq(3)
      expect(statements.grep(/\AUPDATE/i).size).to eq(1)
      expect(statements.grep(/\ASELECT/i)).to be_empty
      expect(fast_klass.unscoped.where.not(deleted_at: nil).count).to eq(3)
    end

    it "keeps the per-record path (hooks observed) when a hook is overridden" do
      klass = Class.new(TestModel) do
        self.table_name = "regress_soft_rows"
        include ConcernsOnRails::Models::SoftDeletable

        soft_deletable_by :deleted_at, touch: false

        def before_soft_delete
          self.class.hook_runs += 1
        end

        class << self
          attr_accessor :hook_runs
        end
        self.hook_runs = 0
      end
      2.times { |i| klass.create!(name: "h#{i}") }

      expect(klass.soft_delete_all).to eq(2)
      expect(klass.hook_runs).to eq(2)
      expect(klass.unscoped.where.not(deleted_at: nil).count).to eq(2)
    end

    it "restore_all fast path is one UPDATE returning the count" do
      2.times { |i| fast_klass.create!(name: "r#{i}", deleted_at: Time.zone.now) }

      count = nil
      statements = capture_sql { count = fast_klass.restore_all }

      expect(count).to eq(2)
      expect(statements.grep(/\AUPDATE/i).size).to eq(1)
      expect(fast_klass.unscoped.where(deleted_at: nil).count).to eq(2)
    end

    it "really_destroy_all honors the calling relation (1.22 data-loss fix)" do
      fast_klass.create!(name: "a")
      fast_klass.create!(name: "a", deleted_at: Time.zone.now)
      fast_klass.create!(name: "b")

      fast_klass.where(name: "a").really_destroy_all

      expect(fast_klass.unscoped.pluck(:name)).to eq(["b"])
    end
  end

  describe "Encryptor PBKDF2 key cache" do
    it "derives the key once across encrypt / decrypt / blind_index" do
      pass = "kdf-spec-#{SecureRandom.hex(6)}"
      ConcernsOnRails::Support::Encryptor.reset_key_cache!
      expect(OpenSSL::KDF).to receive(:pbkdf2_hmac).once.and_call_original

      envelope = ConcernsOnRails::Support::Encryptor.encrypt("secret", key: pass)
      expect(ConcernsOnRails::Support::Encryptor.decrypt(envelope, key: pass)).to eq("secret")
      ConcernsOnRails::Support::Encryptor.blind_index("secret", key: pass)
    end

    it "derives again after reset_key_cache! (configure_encryption purges)" do
      pass = "kdf-spec-#{SecureRandom.hex(6)}"
      ConcernsOnRails::Support::Encryptor.reset_key_cache!
      expect(OpenSSL::KDF).to receive(:pbkdf2_hmac).twice.and_call_original

      ConcernsOnRails::Support::Encryptor.encrypt("x", key: pass)
      ConcernsOnRails::Support::Encryptor.reset_key_cache!
      ConcernsOnRails::Support::Encryptor.encrypt("x", key: pass)
    end

    it "never runs the KDF for raw 32-byte or 64-hex keys" do
      expect(OpenSSL::KDF).not_to receive(:pbkdf2_hmac)
      ConcernsOnRails::Support::Encryptor.encrypt("x", key: SecureRandom.bytes(32))
      ConcernsOnRails::Support::Encryptor.encrypt("x", key: SecureRandom.hex(32))
    end
  end

  describe "Storable decode memoization" do
    before do
      ActiveRecord::Schema.define do
        create_table :regress_storable_rows, force: true do |t|
          t.text :settings
        end
      end
    end

    after { ActiveRecord::Base.connection.drop_table(:regress_storable_rows) }

    let(:klass) do
      Class.new(TestModel) do
        self.table_name = "regress_storable_rows"
        include ConcernsOnRails::Models::Storable

        storable_by :settings, theme: { type: :string, default: "light" },
                               data: { type: :json }
      end
    end

    it "parses the column once for repeated reads" do
      record = klass.create!
      record.theme = "dark"
      record.save!

      fresh = klass.first
      allow(JSON).to receive(:parse).and_call_original
      5.times { expect(fresh.theme).to eq("dark") }
      expect(JSON).to have_received(:parse).once
    end

    it "keeps the 1.21 string-key semantics for :json read-back after a write" do
      record = klass.new
      record.data = { a: 1, nested: { b: 2 } }
      expect(record.data).to eq("a" => 1, "nested" => { "b" => 2 })
    end

    it "dup records read correctly and write independently" do
      record = klass.create!
      record.theme = "dark"
      record.save!

      copy = record.dup
      expect(copy.theme).to eq("dark")
      copy.theme = "solar"
      expect(record.theme).to eq("dark")
      expect(copy.theme).to eq("solar")
    end

    it "reads correctly on a frozen record (uncached path)" do
      record = klass.create!
      record.theme = "dark"
      record.save!

      fresh = klass.first
      fresh.freeze
      expect(fresh.theme).to eq("dark")
      expect(fresh.theme).to eq("dark")
    end
  end
end
