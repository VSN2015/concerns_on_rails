require "spec_helper"

describe ConcernsOnRails::Models::Encryptable do
  TEST_KEY = "concerns-on-rails-encryptable-test-key".freeze

  before do
    ConcernsOnRails.encryption.key = TEST_KEY
    ConcernsOnRails.encryption.on_missing_key = :raise
    ConcernsOnRails.encryption.raise_on_decrypt_error = true

    ActiveRecord::Schema.define do
      create_table :encryptable_records, force: true do |t|
        t.text :ssn
        t.text :notes
        t.text :dob
        t.text :age
        t.text :amount
        t.text :meeting_at
        t.text :email
        t.text :email_bidx
        t.string :name
        t.text :audit_log
      end
    end
  end

  after(:each) do
    ConcernsOnRails.encryption.key = nil
    ConcernsOnRails.encryption.on_missing_key = :raise
    ConcernsOnRails.encryption.raise_on_decrypt_error = true

    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  # Anonymous classes avoid const leakage between examples.
  def model_class(&declaration)
    klass = Class.new(TestModel) do
      self.table_name = "encryptable_records"
      include ConcernsOnRails::Models::Encryptable
    end
    klass.class_eval(&declaration) if declaration
    klass
  end

  describe "round-trip" do
    let(:klass) { model_class { encryptable :ssn } }

    it "encrypts on write and decrypts on read after save" do
      record = klass.create!(ssn: "123-45-6789")
      expect(record.ssn).to eq("123-45-6789")
    end

    it "decrypts after reload" do
      record = klass.create!(ssn: "123-45-6789")
      expect(record.reload.ssn).to eq("123-45-6789")
    end

    it "does not store the plaintext in the column" do
      record = klass.create!(ssn: "123-45-6789").reload
      expect(record.ssn_ciphertext).to be_a(String)
      expect(record.ssn_ciphertext).not_to include("123-45-6789")
    end

    it "survives a fresh find" do
      id = klass.create!(ssn: "123-45-6789").id
      expect(klass.find(id).ssn).to eq("123-45-6789")
    end
  end

  describe "nil / blank" do
    let(:klass) { model_class { encryptable :ssn } }

    it "stores nil as nil (column stays NULL)" do
      record = klass.create!(ssn: nil).reload
      expect(record.ssn).to be_nil
      expect(record.ssn_ciphertext).to be_nil
    end

    it "reports encrypted? only once a value is persisted" do
      record = klass.new
      expect(record.ssn_encrypted?).to be(false)
      record.update!(ssn: "x")
      expect(record.reload.ssn_encrypted?).to be(true)
    end
  end

  describe "dirty tracking (on plaintext)" do
    let(:klass) { model_class { encryptable :ssn } }

    it "tracks changes against the decrypted plaintext" do
      record = klass.create!(ssn: "old").reload
      record.ssn = "new"
      expect(record.ssn_changed?).to be(true)
      expect(record.ssn_was).to eq("old")
    end

    it "is not dirty when the same plaintext is reassigned (despite random IV)" do
      record = klass.create!(ssn: "same").reload
      record.ssn = "same"
      expect(record.ssn_changed?).to be(false)
    end

    it "does not re-encrypt an unchanged field on save" do
      record = klass.create!(ssn: "keep", name: "a").reload
      before = record.ssn_ciphertext
      record.update!(name: "b")
      expect(record.reload.ssn_ciphertext).to eq(before)
    end
  end

  describe "cryptographic integrity" do
    let(:klass) { model_class { encryptable :ssn } }

    it "produces different ciphertext for equal plaintext across records" do
      a = klass.create!(ssn: "555").reload
      b = klass.create!(ssn: "555").reload
      expect(a.ssn_ciphertext).not_to eq(b.ssn_ciphertext)
    end

    it "raises DecryptionError when the key changes underneath it" do
      record = klass.create!(ssn: "secret").reload
      ConcernsOnRails.encryption.key = "a-totally-different-key"
      expect { klass.find(record.id).ssn }
        .to raise_error(ConcernsOnRails::Encryption::DecryptionError)
    end

    it "raises DecryptionError on tampered ciphertext" do
      record = klass.create!(ssn: "secret").reload
      raw = record.ssn_ciphertext.unpack1("m0")
      tampered = [raw[0..-2] + (raw[-1].ord ^ 0x01).chr].pack("m0")
      klass.connection.execute(
        "UPDATE encryptable_records SET ssn = #{klass.connection.quote(tampered)} WHERE id = #{record.id}"
      )
      expect { klass.find(record.id).ssn }
        .to raise_error(ConcernsOnRails::Encryption::DecryptionError)
    end

    it "returns nil instead of raising when raise_on_decrypt_error is false" do
      record = klass.create!(ssn: "secret").reload
      ConcernsOnRails.encryption.raise_on_decrypt_error = false
      ConcernsOnRails.encryption.key = "a-totally-different-key"
      expect(klass.find(record.id).ssn).to be_nil
    end
  end

  describe "type casting round-trip" do
    it "round-trips a :date back to a Date" do
      klass = model_class { encryptable :dob, type: :date }
      record = klass.create!(dob: Date.new(1990, 1, 2)).reload
      expect(record.dob).to eq(Date.new(1990, 1, 2))
      expect(record.dob).to be_a(Date)
    end

    it "round-trips an :integer" do
      klass = model_class { encryptable :age, type: :integer }
      record = klass.new
      record.age = "42"
      expect(record.age).to eq(42)
      record.save!
      expect(record.reload.age).to eq(42)
    end

    it "round-trips a :decimal with precision preserved" do
      klass = model_class { encryptable :amount, type: :decimal }
      record = klass.create!(amount: BigDecimal("19.99")).reload
      expect(record.amount).to eq(BigDecimal("19.99"))
      expect(record.amount).to be_a(BigDecimal)
    end

    it "round-trips a :datetime in UTC" do
      klass = model_class { encryptable :meeting_at, type: :datetime }
      t = Time.utc(2026, 7, 1, 12, 30, 0)
      record = klass.create!(meeting_at: t).reload
      expect(record.meeting_at.to_i).to eq(t.to_i)
    end
  end

  describe "composition" do
    it "normalizes plaintext before encrypting (Normalizable), order-independent" do
      klass = model_class do
        include ConcernsOnRails::Models::Normalizable

        normalizable :ssn, with: :squish
        encryptable :ssn
      end
      record = klass.create!(ssn: "  1 2 3  ").reload
      expect(record.ssn).to eq("1 2 3")
    end

    it "masks the decrypted value (Maskable)" do
      klass = model_class do
        include ConcernsOnRails::Models::Maskable

        encryptable :ssn
        maskable :ssn, with: :last4
      end
      record = klass.create!(ssn: "123456789").reload
      expect(record.masked_ssn).to end_with("6789")
      expect(record.masked_ssn).not_to include("12345")
      expect(record.ssn_ciphertext).not_to include("123456789")
    end

    it "raises when a field is both encryptable and audited (Auditable first)" do
      expect do
        model_class do
          include ConcernsOnRails::Models::Auditable

          auditable_by :ssn, into: :audit_log
          encryptable :ssn
        end
      end.to raise_error(ArgumentError, /Auditable/)
    end

    it "raises on save when audited after encryption is declared" do
      klass = model_class do
        include ConcernsOnRails::Models::Auditable

        encryptable :ssn
        auditable_by :ssn, into: :audit_log
      end
      expect { klass.create!(ssn: "secret") }.to raise_error(ArgumentError, /Auditable/)
    end
  end

  describe "macro-time validation" do
    it "raises when the column does not exist" do
      expect { model_class { encryptable :nope } }
        .to raise_error(ArgumentError, /does not exist/)
    end

    it "raises on an unknown type" do
      expect { model_class { encryptable :ssn, type: :bogus } }
        .to raise_error(ArgumentError, /unknown type/)
    end

    it "raises when no field is given" do
      expect { model_class { encryptable } }
        .to raise_error(ArgumentError, /at least one field/)
    end

    it "accumulates rules across repeated calls and is introspectable" do
      klass = model_class do
        encryptable :ssn
        encryptable :dob, type: :date
      end
      expect(klass.encryptable_rules.keys).to contain_exactly(:ssn, :dob)
      expect(klass.encryptable_rules[:dob][:type]).to eq(:date)
    end
  end

  describe "key configuration" do
    it "raises MissingKeyError at first use, not at class-load" do
      ConcernsOnRails.encryption.key = nil
      klass = model_class { encryptable :ssn } # class loads fine
      expect { klass.create!(ssn: "x") }
        .to raise_error(ConcernsOnRails::Encryption::MissingKeyError)
    end

    it "honors a per-field String key override" do
      ConcernsOnRails.encryption.key = nil
      klass = model_class { encryptable :ssn, key: "per-field-key" }
      record = klass.create!(ssn: "x").reload
      expect(record.ssn).to eq("x")
    end

    it "honors a per-field Proc key override" do
      ConcernsOnRails.encryption.key = nil
      klass = model_class { encryptable :ssn, key: -> { "proc-key" } }
      record = klass.create!(ssn: "x").reload
      expect(record.ssn).to eq("x")
    end

    it "stores plaintext when on_missing_key is :passthrough and no key is set" do
      ConcernsOnRails.encryption.key = nil
      ConcernsOnRails.encryption.on_missing_key = :passthrough
      klass = model_class { encryptable :ssn }
      record = klass.create!(ssn: "plain").reload
      expect(record.ssn).to eq("plain")
      expect(record.ssn_ciphertext).to eq("plain")
    end
  end

  describe "blind index" do
    let(:klass) { model_class { encryptable :email, blind_index: true } }

    it "stores a 64-char hex fingerprint, not the plaintext" do
      record = klass.create!(email: "a@b.com").reload
      expect(record.email_bidx).to match(/\A\h{64}\z/)
      expect(record.email_bidx).not_to include("a@b.com")
    end

    it "finds a record by exact value via find_by_<field>" do
      record = klass.create!(email: "a@b.com")
      expect(klass.find_by_email("a@b.com")).to eq(record)
      expect(klass.find_by_email("nope@b.com")).to be_nil
    end

    it "builds a relation via where_<field>" do
      record = klass.create!(email: "a@b.com")
      klass.create!(email: "c@d.com")
      expect(klass.where_email("a@b.com").to_a).to eq([record])
    end

    it "accepts multiple values (IN query) via where_<field>" do
      a = klass.create!(email: "a@b.com")
      c = klass.create!(email: "c@d.com")
      klass.create!(email: "e@f.com")
      expect(klass.where_email("a@b.com", "c@d.com")).to contain_exactly(a, c)
      expect(klass.where_email(["a@b.com", "c@d.com"])).to contain_exactly(a, c)
    end

    it "chains with scopes, where, and or" do
      a = klass.create!(email: "a@b.com", name: "keep")
      klass.create!(email: "a@b.com", name: "drop")
      b = klass.create!(email: "c@d.com", name: "keep")
      expect(klass.where(name: "keep").where_email("a@b.com").to_a).to eq([a])
      expect(klass.where_email("a@b.com").where(name: "keep").to_a).to eq([a])
      expect(klass.where_email("a@b.com").or(klass.where_email("c@d.com")).where(name: "keep"))
        .to contain_exactly(a, b)
    end

    it "exposes a deterministic <field>_fingerprint equal to the stored digest" do
      record = klass.create!(email: "a@b.com").reload
      expect(klass.email_fingerprint("a@b.com")).to eq(record.email_bidx)
      expect(klass.email_fingerprint("a@b.com")).to eq(klass.email_fingerprint("a@b.com"))
    end

    it "stores a nil fingerprint for a nil value" do
      record = klass.create!(email: nil).reload
      expect(record.email_bidx).to be_nil
    end

    it "records the blind_index config in the rules" do
      expect(klass.encryptable_rules[:email][:blind_index][:column]).to eq(:email_bidx)
    end

    it "refreshes the index only when the field changes" do
      record = klass.create!(email: "a@b.com", name: "x").reload
      before = record.email_bidx
      record.update!(name: "y")
      expect(record.reload.email_bidx).to eq(before)

      record.update!(email: "z@b.com")
      expect(klass.find_by_email("a@b.com")).to be_nil
      expect(klass.find_by_email("z@b.com")).to eq(record)
    end

    context "with a normalization expression" do
      let(:klass) do
        model_class { encryptable :email, blind_index: { expression: ->(v) { v.to_s.downcase.strip } } }
      end

      it "matches case- and whitespace-insensitively on write and query" do
        record = klass.create!(email: "  Alice@Example.COM ")
        expect(klass.find_by_email("alice@example.com")).to eq(record)
      end
    end

    describe "macro-time validation" do
      it "raises when the blind-index column does not exist" do
        expect { model_class { encryptable :email, blind_index: { column: :missing_bidx } } }
          .to raise_error(ArgumentError, /does not exist/)
      end

      it "raises when a custom column is combined with multiple fields" do
        expect { model_class { encryptable :ssn, :email, blind_index: { column: :x } } }
          .to raise_error(ArgumentError, /cannot be combined with multiple fields/)
      end

      it "raises when the expression is not callable" do
        expect { model_class { encryptable :email, blind_index: { expression: 42 } } }
          .to raise_error(ArgumentError, /must be callable/)
      end
    end
  end
end
