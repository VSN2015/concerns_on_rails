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
        t.string :slug
        t.datetime :deleted_at
      end
    end
  end

  after(:each) do
    ConcernsOnRails.encryption.key = nil
    ConcernsOnRails.encryption.on_missing_key = :raise
    ConcernsOnRails.encryption.raise_on_decrypt_error = true
    ConcernsOnRails.encryption.key_id = 0
    ConcernsOnRails.encryption.previous_keys = {}

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

  describe "#<field>_ciphertext never exposes plaintext" do
    let(:klass) { model_class { encryptable :ssn } }

    # read_attribute_before_type_cast on an `attribute`-overridden column is
    # the caller's PLAINTEXT until the value round-trips through the database.
    # A reader named _ciphertext returning an SSN — while _encrypted? answered
    # true — put the value straight into any log line that trusted it.
    it "returns nil (not the plaintext) for an unsaved new record" do
      record = klass.new(ssn: "111-22-3333")

      expect(record.ssn_ciphertext).to be_nil
      expect(record.ssn_encrypted?).to be(false)
    end

    it "returns nil (not the plaintext) for a persisted record with a pending change" do
      record = klass.create!(ssn: "111-22-3333").reload
      record.ssn = "999-88-7777"

      expect(record.ssn_ciphertext).to be_nil
      expect(record.ssn_encrypted?).to be(false)
    end

    it "returns the envelope once the change is saved" do
      record = klass.create!(ssn: "111-22-3333").reload
      record.update!(ssn: "999-88-7777")

      expect(record.ssn_ciphertext).to be_a(String)
      expect(record.ssn_ciphertext).not_to include("999-88-7777")
      expect(record.ssn_encrypted?).to be(true)
    end

    # Rails 6.0-7.0 do not memoize Attribute#value_for_database: after a save
    # the in-memory "raw" value is a SECOND serialize (fresh IV), so the reader
    # returned ciphertext that was never written, and reencrypt! on the
    # just-saved instance failed its own guard.
    describe "matches what is actually stored after a write" do
      def stored_ssn(id)
        klass.connection.select_value(
          "SELECT #{TestDatabase.quoted_column('ssn')} FROM #{TestDatabase.quoted_table('encryptable_records')} " \
          "WHERE #{TestDatabase.quoted_column('id')} = #{Integer(id)}"
        )
      end

      it "after create" do
        record = klass.create!(ssn: "111-22-3333")
        expect(record.ssn_ciphertext).to eq(stored_ssn(record.id))
        expect(record.ssn).to eq("111-22-3333")
      end

      it "after an update of the encrypted field" do
        record = klass.create!(ssn: "111-22-3333")
        record.update!(ssn: "999-88-7777")
        expect(record.ssn_ciphertext).to eq(stored_ssn(record.id))
        expect(record.ssn).to eq("999-88-7777")
      end

      it "after a save that changed only another column" do
        record = klass.create!(ssn: "111-22-3333").reload
        record.update!(name: "renamed")
        expect(record.ssn_ciphertext).to eq(stored_ssn(record.id))
      end

      it "after touch" do
        record = klass.create!(ssn: "111-22-3333").reload
        record.touch
        expect(record.ssn_ciphertext).to eq(stored_ssn(record.id))
      end

      it "after update_columns" do
        record = klass.create!(ssn: "111-22-3333").reload
        record.update_columns(ssn: "444-55-6666")
        expect(record.ssn_ciphertext).to eq(stored_ssn(record.id))
        expect(record.ssn).to eq("444-55-6666")
      end

      it "lets reencrypt! rotate the instance that was just saved" do
        record = klass.create!(ssn: "111-22-3333")
        ConcernsOnRails.configure_encryption do |c|
          c.key = "concerns-on-rails-encryptable-rotated-key"
          c.key_id = 1
          c.previous_keys = { 0 => TEST_KEY }
        end

        expect(record.reencrypt!).to be(true)
        expect(record.ssn_key_id).to eq(1)
        expect(record.ssn_ciphertext).to eq(stored_ssn(record.id))
      end
    end

    it "is nil for a persisted record whose value was never set" do
      record = klass.create!.reload

      expect(record.ssn_ciphertext).to be_nil
      expect(record.ssn_encrypted?).to be(false)
    end

    it "reports encrypted? false when the column holds plaintext rather than an envelope" do
      record = klass.create!(ssn: "111-22-3333")
      klass.connection.execute(
        "UPDATE encryptable_records SET ssn = 'not-an-envelope' WHERE id = #{record.id}"
      )

      expect(klass.find(record.id).ssn_encrypted?).to be(false)
    end
  end

  describe "Support::Encryptor.envelope?" do
    it "recognizes its own output and rejects everything else" do
      envelope = ConcernsOnRails::Support::Encryptor.encrypt("x", key: "a" * 64)

      expect(ConcernsOnRails::Support::Encryptor.envelope?(envelope)).to be(true)
      expect(ConcernsOnRails::Support::Encryptor.envelope?("123-45-6789")).to be(false)
      expect(ConcernsOnRails::Support::Encryptor.envelope?("not base64 !!")).to be(false)
      expect(ConcernsOnRails::Support::Encryptor.envelope?(["short"].pack("m0"))).to be(false)
      # valid Base64, right length, but an unknown version byte
      bogus = [[0xFF].pack("C") + ("\0" * 40)].pack("m0")
      expect(ConcernsOnRails::Support::Encryptor.envelope?(bogus)).to be(false)
      expect(ConcernsOnRails::Support::Encryptor.envelope?(nil)).to be(false)
      expect(ConcernsOnRails::Support::Encryptor.envelope?(42)).to be(false)
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

    it "raises at declaration when audited after encryption is declared (1.22: macro-time)" do
      expect do
        model_class do
          include ConcernsOnRails::Models::Auditable

          encryptable :ssn
          auditable_by :ssn, into: :audit_log
        end
      end.to raise_error(ArgumentError, /Auditable/)
    end

    # A friendly_id slug is a plaintext derivative of its source: slugging an
    # encrypted field stored "123-45-6789" in the slug column in clear.
    describe "Sluggable guard (a slug is plaintext of its source)" do
      it "raises when the encrypted field is the slug source (Sluggable first)" do
        expect do
          model_class do
            include ConcernsOnRails::Models::Sluggable

            sluggable_by :ssn
            encryptable :ssn
          end
        end.to raise_error(ArgumentError, /Sluggable/)
      end

      it "raises when the slug source is declared after encryption" do
        expect do
          model_class do
            include ConcernsOnRails::Models::Sluggable

            encryptable :ssn
            sluggable_by :ssn
          end
        end.to raise_error(ArgumentError, /Sluggable.*:ssn|:ssn.*Sluggable/)
      end

      it "raises when a slug candidate (nested included) names an encrypted field, either order" do
        expect do
          model_class do
            include ConcernsOnRails::Models::Sluggable

            sluggable_by :name, candidates: [:name, %i[name ssn]]
            encryptable :ssn
          end
        end.to raise_error(ArgumentError, /Sluggable/)

        expect do
          model_class do
            include ConcernsOnRails::Models::Sluggable

            encryptable :ssn
            sluggable_by :name, candidates: [:name, %i[name ssn]]
          end
        end.to raise_error(ArgumentError, /Sluggable/)
      end

      # The macro-time guards cannot see every shape; a save-time backstop
      # refuses to write a slug resolved from an encrypted field.
      def raw_slug(klass, id)
        klass.connection.select_value(
          "SELECT #{TestDatabase.quoted_column('slug')} FROM encryptable_records WHERE id = #{id}"
        )
      end

      it "refuses to save when Sluggable is included WITHOUT sluggable_by and slugs the encrypted :name (either order)" do
        sluggable_first = model_class do
          include ConcernsOnRails::Models::Sluggable

          encryptable :name
        end
        encryptable_first = model_class do
          encryptable :name
          include ConcernsOnRails::Models::Sluggable
        end
        stub_const("EncSlugImplicit", sluggable_first)
        stub_const("EncSlugImplicitLate", encryptable_first)

        [sluggable_first, encryptable_first].each do |klass|
          expect { klass.create!(name: "Jane Smith") }.to raise_error(ArgumentError, /:name.*slug source/)
          expect(klass.connection.select_value("SELECT COUNT(*) FROM encryptable_records").to_i).to eq(0)
        end
      end

      it "raises for a bare friendly_id model whose base is encrypted (friendly_id first: macro time; after: save time)" do
        expect do
          model_class do
            extend FriendlyId

            friendly_id :ssn, use: :slugged
            encryptable :ssn
          end
        end.to raise_error(ArgumentError, /:ssn.*slug source/)

        late = model_class do
          encryptable :ssn
          extend FriendlyId

          friendly_id :ssn, use: :slugged
        end
        stub_const("EncBareFriendlyLate", late)
        expect { late.create!(ssn: "123-45-6789") }.to raise_error(ArgumentError, /:ssn.*slug source/)
      end

      it "a refused sluggable_by leaves the previous slug configuration in place" do
        klass = model_class do
          include ConcernsOnRails::Models::Sluggable

          encryptable :ssn
        end
        expect { klass.sluggable_by(:ssn) }.to raise_error(ArgumentError)
        expect(klass.sluggable_field).to eq(:name)
        expect(klass.sluggable_declared).to be(false)
      end

      it "leaves an unrelated slug source alone, and never writes the ciphertext's plaintext to the slug" do
        klass = model_class do
          include ConcernsOnRails::Models::Sluggable

          encryptable :ssn
          sluggable_by :name
        end
        record = klass.create!(name: "Jane Doe", ssn: "123-45-6789")
        expect(raw_slug(klass, record.id)).to eq("jane-doe")
      end
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

  describe "key rotation" do
    OLD_KEY = TEST_KEY
    NEW_KEY = "concerns-on-rails-encryptable-rotated-key".freeze

    def rotate!(previous: { 0 => OLD_KEY })
      ConcernsOnRails.configure_encryption do |c|
        c.key = NEW_KEY
        c.key_id = 1
        c.previous_keys = previous
      end
    end

    let(:klass) { model_class { encryptable :ssn, :notes } }

    it "keeps decrypting rows written under a previous key and writes new rows with the current key id" do
      legacy = klass.create!(ssn: "111-11-1111")
      expect(legacy.ssn_key_id).to eq(0)

      rotate!
      found = klass.find(legacy.id)
      expect(found.ssn).to eq("111-11-1111")
      expect(found.ssn_key_id).to eq(0)
      # A successful rewrite reloads, so the readers describe what is at rest.
      expect(found.reencrypt!).to be true
      expect(found.ssn_key_id).to eq(1)
      expect(found.ssn).to eq("111-11-1111")

      fresh = klass.create!(ssn: "222-22-2222")
      expect(fresh.ssn_key_id).to eq(1)
      expect(ConcernsOnRails::Support::Encryptor.key_id(fresh.ssn_ciphertext)).to eq(1)
      expect(klass.find(fresh.id).ssn).to eq("222-22-2222")
      expect(klass.new.ssn_key_id).to be_nil
    end

    it "raises a DecryptionError naming the key id when a row's key is no longer configured" do
      legacy = klass.create!(ssn: "111-11-1111")
      rotate!(previous: {})
      expect { klass.find(legacy.id).ssn }
        .to raise_error(ConcernsOnRails::Encryption::DecryptionError, /encrypted with unknown key id 0/)
    end

    it "needs_reencryption finds stale rows and reencrypt_all! rewrites them with the current key, blind indexes included" do
      klass = model_class do
        encryptable :ssn
        encryptable :email, blind_index: true
      end
      a = klass.create!(ssn: "111-11-1111", email: "a@example.com")
      b = klass.create!(ssn: "333-33-3333")
      klass.create!(notes: "no encrypted values") # nothing to rotate
      old_bidx = a.email_bidx

      rotate!
      expect(klass.needs_reencryption.order(:id)).to eq([a, b])
      expect(klass.needs_reencryption(:email).order(:id)).to eq([a])
      expect(klass.reencrypt_all!).to eq(2)
      expect(klass.needs_reencryption.count).to eq(0)

      a.reload
      expect(a.ssn_key_id).to eq(1)
      expect(a.email_key_id).to eq(1)
      expect(a.ssn).to eq("111-11-1111")
      expect(a.email_bidx).not_to eq(old_bidx)
      expect(a.email_bidx).to eq(klass.email_fingerprint("a@example.com"))
      expect(klass.find_by_email("a@example.com")).to eq(a)
      expect(b.reload.ssn_key_id).to eq(1)
      expect(klass.reencrypt_all!).to eq(0) # idempotent
    end

    it "blind-index lookups still find rows fingerprinted under a previous key during the rotation window" do
      klass = model_class { encryptable :email, blind_index: true }
      legacy = klass.create!(email: "a@example.com")

      rotate!
      expect(klass.email_fingerprint("a@example.com")).not_to eq(legacy.email_bidx) # current-key digest differs
      expect(klass.find_by_email("a@example.com")).to eq(legacy)
      expect(klass.where_email("a@example.com").count).to eq(1)
      expect(klass.where_email("nobody@example.com")).to be_empty
      expect(klass.find_by_email("nobody@example.com")).to be_nil
    end

    it "leaves per-field keys out of rotation and validates the rotation config" do
      klass = model_class do
        encryptable :ssn
        encryptable :notes, key: "field-specific-key"
      end
      record = klass.create!(ssn: "111-11-1111", notes: "pinned")
      expect(record.notes_key_id).to eq(0)

      rotate!
      expect(klass.needs_reencryption(:notes).count).to eq(0)
      expect(klass.reencrypt_all!(:notes)).to eq(0)
      expect(klass.find(record.id).notes).to eq("pinned")
      expect(klass.reencrypt_all!).to eq(1) # only :ssn was stale

      expect { ConcernsOnRails.encryption.key_id = 256 }.to raise_error(ArgumentError, /key_id must be an Integer between 0 and 255/)
      expect { ConcernsOnRails.encryption.previous_keys = { "0" => OLD_KEY } }
        .to raise_error(ArgumentError, /previous_keys must map Integer key ids \(0-255\) to key material/)
      expect { ConcernsOnRails.encryption.previous_keys = [OLD_KEY] }.to raise_error(ArgumentError, /previous_keys must map/)
      expect { klass.needs_reencryption(:name) }.to raise_error(ArgumentError, /name is not an encryptable field/)
    end

    it "never puts key material in the previous_keys error message" do
      secret = "super-secret-production-key-material"
      expect { ConcernsOnRails.encryption.previous_keys = { "0" => secret } }
        .to raise_error(ArgumentError) { |e| expect(e.message).not_to include(secret) }
      expect { ConcernsOnRails.encryption.previous_keys = secret }
        .to raise_error(ArgumentError) { |e| expect(e.message).not_to include(secret) }
      # The inverted hash — `{ material => id }` instead of `{ id => material }`
      # — is the one shape whose KEYS are the secret.
      expect { ConcernsOnRails.encryption.previous_keys = { secret => 0 } }
        .to raise_error(ArgumentError) { |e| expect(e.message).not_to include(secret) }
    end

    it "never commits an unsaved change and never reverts a concurrent write" do
      klass = model_class { encryptable :email, blind_index: true }
      record = klass.create!(email: "a@example.com")
      rotate!

      # A pending edit belongs to a normal save (validations, callbacks), not to
      # a key rotation — the field is skipped, so nothing is written at all.
      pending_edit = klass.find(record.id)
      pending_edit.email = "typo@example.com"
      expect(pending_edit.reencrypt!).to be false
      expect(klass.find(record.id).email).to eq("a@example.com")

      # Another process rewrites the row (under the current key) between this
      # record's load and its rewrite: the guard refuses rather than reverting.
      stale = klass.find(record.id)
      klass.find(record.id).update!(email: "b@example.com")
      expect(stale.reencrypt!).to be false
      expect(klass.reencrypt_all!).to eq(0)
      expect(klass.find(record.id).email).to eq("b@example.com")
      expect(klass.find_by_email("b@example.com")).to eq(record)
    end

    it "detects stale rows for key ids above 25, where a case-folding LIKE could not" do
      # Base64 prefixes for ids 26..51 reuse the letters of 0..25 in the other
      # case, and SQLite's LIKE (and MySQL's default collation) fold case.
      legacy = klass.create!(ssn: "111-11-1111")
      ConcernsOnRails.configure_encryption do |c|
        c.key = NEW_KEY
        c.key_id = 26
        c.previous_keys = { 0 => OLD_KEY }
      end

      expect(klass.needs_reencryption).to eq([legacy])
      expect(klass.reencrypt_all!).to eq(1)
      expect(klass.needs_reencryption.count).to eq(0)
      expect(klass.find(legacy.id).ssn).to eq("111-11-1111")
      expect(klass.find(legacy.id).ssn_key_id).to eq(26)
    end

    describe "rows hidden by a default_scope" do
      # The documented rotation is "reencrypt_all!, then drop the old id from
      # previous_keys". A sweep that ran through the default scope never saw a
      # soft-deleted (or unpublished) row, so dropping the key made exactly
      # those rows undecryptable — restore! brought back an unreadable record.
      let(:klass) do
        model_class do
          include ConcernsOnRails::Models::SoftDeletable

          soft_deletable_by :deleted_at
          encryptable :ssn
        end
      end

      it "reencrypt_all! on the model rotates soft-deleted rows too, so the old key can be dropped" do
        visible = klass.create!(ssn: "111-11-1111")
        hidden = klass.create!(ssn: "222-22-2222")
        hidden.soft_delete!

        rotate!
        expect(klass.reencrypt_all!).to eq(2)
        expect(klass.unscoped.needs_reencryption.count).to eq(0)

        rotate!(previous: {}) # the documented last step: forget the old key
        expect(klass.find(visible.id).ssn).to eq("111-11-1111")
        expect(klass.unscoped.find(hidden.id).ssn).to eq("222-22-2222")
        expect(klass.unscoped.find(hidden.id).ssn_key_id).to eq(1)
      end

      it "needs_reencryption on the model reports hidden stale rows, so the 'nothing left' check is honest" do
        visible = klass.create!(ssn: "111-11-1111")
        hidden = klass.create!(ssn: "222-22-2222")
        hidden.soft_delete!
        rotate!

        expect(klass.needs_reencryption.order(:id).map(&:id)).to eq([visible.id, hidden.id])
        expect(klass.needs_reencryption.exists?).to be(true)
      end

      it "honours an explicit relation: a chained call covers exactly that relation" do
        visible = klass.create!(ssn: "111-11-1111")
        hidden = klass.create!(ssn: "222-22-2222")
        hidden.soft_delete!
        rotate!

        # A chain is the caller's own selection — the default scope included.
        expect(klass.where(id: [visible.id, hidden.id]).needs_reencryption.map(&:id)).to eq([visible.id])
        expect(klass.unscoped.where(id: hidden.id).needs_reencryption.map(&:id)).to eq([hidden.id])
        expect(klass.unscoped.where(id: hidden.id).reencrypt_all!).to eq(1)
        expect(klass.unscoped.find(hidden.id).ssn_key_id).to eq(1)
        expect(klass.find(visible.id).ssn_key_id).to eq(0)
      end

      it "also covers rows hidden by Publishable's default_scope" do
        ActiveRecord::Base.connection.add_column :encryptable_records, :published_at, :datetime
        published_klass = model_class do
          include ConcernsOnRails::Models::Publishable

          publishable_by :published_at, default_scope: true
          encryptable :ssn
        end
        draft = published_klass.create!(ssn: "333-33-3333")
        expect(published_klass.where(id: draft.id)).to be_empty

        rotate!
        expect(published_klass.reencrypt_all!).to eq(1)
        rotate!(previous: {})
        expect(published_klass.unscoped.find(draft.id).ssn).to eq("333-33-3333")
      end
    end

    it "refuses to overwrite ciphertext it could not decrypt, even when errors are swallowed" do
      record = klass.create!(ssn: "111-11-1111")
      before = klass.find(record.id).ssn_ciphertext

      # Old key dropped AND raise_on_decrypt_error off: the plaintext reads as
      # nil. Writing that back would NULL exactly the rows a rotation exists to
      # rescue, so the field must be skipped instead.
      ConcernsOnRails.configure_encryption do |c|
        c.key = NEW_KEY
        c.key_id = 1
        c.previous_keys = {}
        c.raise_on_decrypt_error = false
      end

      expect(klass.reencrypt_all!).to eq(0)
      expect(klass.find(record.id).ssn_ciphertext).to eq(before)
    end
  end
end
