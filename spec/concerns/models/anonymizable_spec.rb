require "spec_helper"

RSpec.describe ConcernsOnRails::Models::Anonymizable do
  before do
    ActiveRecord::Schema.define do
      create_table :anon_users, force: true do |t|
        t.string :name
        t.string :email
        t.string :phone
        t.text :bio
        t.string :ssn
        t.text :audit_log
        t.text :secret
        t.datetime :anonymized_at
        t.datetime :when_wiped
        t.timestamps null: true
      end
    end
  end

  after { ActiveRecord::Base.connection.drop_table(:anon_users) }

  def model_class(&block)
    Class.new(TestModel) do
      self.table_name = "anon_users"
      include ConcernsOnRails::Models::Anonymizable

      class_eval(&block) if block
    end
  end

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

  describe "presets" do
    let(:klass) do
      model_class do
        anonymizable :ssn, with: :nullify
        anonymizable :name, with: :redact
        anonymizable :phone, with: :hash
        anonymizable :email, with: :email
        anonymizable :bio, with: :random_hex
      end
    end

    it "applies each preset" do
      record = klass.create!(name: "Jane", email: "jane@example.com", phone: "555-1234",
                             bio: "about me", ssn: "123-45-6789")
      record.anonymize!

      expect(record.ssn).to be_nil
      expect(record.name).to eq("[REDACTED]")
      expect(record.phone).to eq(Digest::SHA256.hexdigest("555-1234"))
      expect(record.email).to match(/\Aanon-\h{20}@anonymized\.invalid\z/)
      expect(record.bio).to match(/\A\h{32}\z/)
    end

    it "passes nil through untouched (nothing to erase)" do
      record = klass.create!(name: nil, email: nil, phone: nil, bio: nil, ssn: nil)
      record.anonymize!

      expect(record.name).to be_nil
      expect(record.email).to be_nil
      expect(record.phone).to be_nil
    end

    it "generates a distinct :email per record (unique-index safe)" do
      a = klass.create!(email: "same@example.com")
      b = klass.create!(email: "same2@example.com")
      a.anonymize!
      b.anonymize!
      expect(a.email).not_to eq(b.email)
    end
  end

  describe "custom callables" do
    it "supports a one-arg callable" do
      klass = model_class { anonymizable :bio, with: ->(value) { value && "removed" } }
      record = klass.create!(bio: "hello")
      record.anonymize!
      expect(record.bio).to eq("removed")
    end

    it "supports a two-arg callable receiving the record" do
      klass = model_class { anonymizable :name, with: ->(_value, record) { "user-#{record.id}" } }
      record = klass.create!(name: "Jane")
      record.anonymize!
      expect(record.name).to eq("user-#{record.id}")
    end
  end

  describe "the write path" do
    it "erases in a single UPDATE" do
      klass = model_class { anonymizable :name, with: :redact }
      record = klass.create!(name: "Jane")

      statements = capture_sql { record.anonymize! }
      expect(statements.grep(/\AUPDATE/i).size).to eq(1)
    end

    it "is not blocked by validations" do
      klass = model_class do
        anonymizable :name, with: :nullify
        validates :name, presence: true
      end
      record = klass.create!(name: "Jane")
      record.anonymize!
      expect(record.reload.name).to be_nil
    end

    it "does not run save callbacks" do
      klass = model_class do
        anonymizable :name, with: :redact

        before_save { self.class.callback_runs += 1 }

        class << self
          attr_accessor :callback_runs
        end
        self.callback_runs = 0
      end
      record = klass.create!(name: "Jane")
      expect { record.anonymize! }.not_to change(klass, :callback_runs)
    end

    it "raises on a new record" do
      klass = model_class { anonymizable :name, with: :redact }
      expect { klass.new(name: "x").anonymize! }.to raise_error(ArgumentError, /new record/)
    end
  end

  describe "the stamp" do
    it "stamps anonymized_at by default and answers anonymized?" do
      klass = model_class { anonymizable :name, with: :redact }
      record = klass.create!(name: "Jane")
      expect(record.anonymized?).to be(false)

      record.anonymize!
      expect(record.anonymized_at).to be_present
      expect(record.anonymized?).to be(true)
    end

    it "supports a custom stamp column" do
      klass = model_class { anonymizable :name, with: :redact, stamp: :when_wiped }
      record = klass.create!(name: "Jane")
      record.anonymize!
      expect(record.when_wiped).to be_present
      expect(record.anonymized_at).to be_nil
    end

    it "stamp: false erases without stamping (anonymized? stays false)" do
      klass = model_class { anonymizable :name, with: :redact, stamp: false }
      record = klass.create!(name: "Jane")
      record.anonymize!
      expect(record.name).to eq("[REDACTED]")
      expect(record.anonymized?).to be(false)
      expect(klass).not_to respond_to(:anonymized)
    end

    it "keeps an explicit stamp across later default-argument calls" do
      klass = model_class do
        anonymizable :name, with: :redact, stamp: :when_wiped
        anonymizable :bio, with: :nullify
      end
      record = klass.create!(name: "Jane", bio: "x")
      record.anonymize!
      expect(record.when_wiped).to be_present
    end
  end

  describe "scopes" do
    it "defines anonymized / not_anonymized" do
      klass = model_class { anonymizable :name, with: :redact }
      wiped = klass.create!(name: "a").tap(&:anonymize!)
      kept = klass.create!(name: "b")

      expect(klass.anonymized).to contain_exactly(wiped)
      expect(klass.not_anonymized).to contain_exactly(kept)
    end

    it "affixes scope names with prefix:/suffix:" do
      klass = model_class { anonymizable :name, with: :redact, prefix: :privacy }
      expect(klass).to respond_to(:privacy_anonymized)
      expect(klass).to respond_to(:privacy_not_anonymized)
    end
  end

  describe "hooks" do
    it "runs before/after_anonymize inside the transaction and rolls back on a raising hook" do
      klass = model_class do
        anonymizable :name, with: :redact

        def after_anonymize
          raise "boom"
        end
      end
      record = klass.create!(name: "Jane")

      expect { record.anonymize! }.to raise_error("boom")
      expect(record.reload.name).to eq("Jane")
      expect(record.anonymized?).to be(false)
    end
  end

  describe ".anonymize_all!" do
    it "anonymizes matching records, skips stamped ones, returns the count" do
      klass = model_class { anonymizable :name, with: :redact }
      already = klass.create!(name: "a").tap(&:anonymize!)
      klass.create!(name: "b")
      klass.create!(name: "c")

      expect(klass.anonymize_all!).to eq(2)
      expect(klass.anonymized.count).to eq(3)
      expect(already.reload.name).to eq("[REDACTED]")
    end
  end

  describe "macro validation" do
    it "raises without fields" do
      expect { model_class { anonymizable(with: :redact) } }.to raise_error(ArgumentError, /at least one field/)
    end

    it "raises on an unknown preset" do
      expect { model_class { anonymizable :name, with: :bogus } }.to raise_error(ArgumentError, /unknown preset/)
    end

    it "raises on a non-callable strategy" do
      expect { model_class { anonymizable :name, with: 42 } }.to raise_error(ArgumentError, /must be a preset symbol or a callable/)
    end

    it "raises on a missing column" do
      expect { model_class { anonymizable :nope, with: :redact } }.to raise_error(ArgumentError, /does not exist/)
    end
  end

  describe "Auditable interaction" do
    def audited_class(**options)
      opts = options
      model_class do
        include ConcernsOnRails::Models::Auditable

        auditable_by :name, into: :audit_log
        anonymizable :name, with: :redact, **opts
      end
    end

    it "clears the audit trail when an anonymized field is audited" do
      klass = audited_class
      record = klass.create!(name: "Jane")
      record.update!(name: "Janet")
      expect(record.audit_trail).not_to be_empty

      record.anonymize!
      expect(record.audit_trail).to eq([])
    end

    it "keeps the trail with clear_audit_trail: false" do
      klass = audited_class(clear_audit_trail: false)
      record = klass.create!(name: "Jane")
      record.update!(name: "Janet")

      record.anonymize!
      expect(record.audit_trail).not_to be_empty
    end

    it "keeps the trail when no anonymized field is audited" do
      klass = model_class do
        include ConcernsOnRails::Models::Auditable

        auditable_by :name, into: :audit_log
        anonymizable :phone, with: :nullify
      end
      record = klass.create!(name: "Jane", phone: "555")
      record.update!(name: "Janet")

      record.anonymize!
      expect(record.audit_trail).not_to be_empty
    end
  end

  describe "Encryptable interaction" do
    let(:klass) do
      model_class do
        include ConcernsOnRails::Models::Encryptable

        encryptable :secret, key: "anonymizable-spec-passphrase"
        anonymizable :secret, with: :redact
      end
    end

    it "stores a fresh ciphertext of the anonymized value — never plaintext" do
      record = klass.create!(secret: "top secret")
      original_ciphertext = record.secret_ciphertext

      record.anonymize!

      expect(record.secret).to eq("[REDACTED]")
      expect(record.secret_encrypted?).to be(true)
      expect(record.secret_ciphertext).not_to eq(original_ciphertext)
      expect(record.secret_ciphertext).not_to include("[REDACTED]")

      fresh = klass.find(record.id)
      expect(fresh.secret).to eq("[REDACTED]")
    end
  end
end
