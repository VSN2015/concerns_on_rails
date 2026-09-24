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
        t.string :email_bidx
        t.datetime :anonymized_at
        t.datetime :when_wiped
        t.string :slug
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

    it "reports every missing field at once with one combined migration command" do
      expect { model_class { anonymizable :nope, :nada, with: :redact } }.to raise_error(
        ArgumentError, /\x27nope\x27 and \x27nada\x27 do not exist.*AddAnonymizableColumnsToAnonUsers nope nada\z/
      )
    end

    it "types the stamp column in the migration hint" do
      expect { model_class { anonymizable :name, with: :redact, stamp: :erased_at } }.to raise_error(
        ArgumentError, /AddErasedAtToAnonUsers erased_at:datetime\z/
      )
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

    # Erasure must never be blocked by crypto state: a row whose ciphertext
    # cannot be decrypted (lost key, corruption) is exactly the kind of data a
    # right-to-erasure request still has to destroy.
    describe "a field whose ciphertext cannot be decrypted" do
      let(:writer) do
        model_class do
          include ConcernsOnRails::Models::Encryptable

          encryptable :secret, key: "the-key-that-wrote-the-row"
        end
      end

      def eraser(strategy)
        model_class do
          include ConcernsOnRails::Models::Encryptable

          encryptable :secret, key: "a-different-key-that-cannot-read-it"
          anonymizable :secret, with: strategy
        end
      end

      it "sanity: the row really is undecryptable under the eraser's key" do
        id = writer.create!(secret: "top secret").id
        expect { eraser(:redact).find(id).secret }.to raise_error(ConcernsOnRails::Encryption::DecryptionError)
      end

      %i[nullify redact email random_hex].each do |preset|
        it "erases with :#{preset} without ever decrypting the old value" do
          id = writer.create!(secret: "top secret").id
          klass = eraser(preset)
          record = klass.find(id)

          expect(ConcernsOnRails::Support::Encryptor).not_to receive(:decrypt)
          expect { record.send(:anonymize_record!) }.not_to raise_error
          RSpec::Mocks.space.proxy_for(ConcernsOnRails::Support::Encryptor).reset

          erased = klass.find(id).secret
          case preset
          when :nullify then expect(erased).to be_nil
          when :redact then expect(erased).to eq("[REDACTED]")
          when :email then expect(erased).to match(/\Aanon-\h{20}@anonymized\.invalid\z/)
          when :random_hex then expect(erased).to match(/\A\h{32}\z/)
          end
        end
      end

      it "keeps the presence-only presets nil-in / nil-out without decrypting" do
        id = writer.create!(secret: nil).id
        record = eraser(:redact).find(id)
        record.anonymize!
        expect(record.secret).to be_nil
      end

      it "falls back to [REDACTED] for a value-dependent strategy (:hash, a callable)" do
        seen = []
        recorder = lambda do |value|
          seen << value
          "custom"
        end
        [:hash, recorder].each do |strategy|
          id = writer.create!(secret: "top secret").id
          record = eraser(strategy).find(id)

          expect { record.anonymize! }.not_to raise_error
          expect(record.secret).to eq("[REDACTED]")
          expect(record.anonymized?).to be(true)
        end
        # The callable is never handed a value it cannot have read.
        expect(seen).to be_empty
      end

      it "falls back the same way when decrypt errors are swallowed (the value reads as nil)" do
        ConcernsOnRails.encryption.raise_on_decrypt_error = false
        id = writer.create!(secret: "top secret").id
        record = eraser(:hash).find(id)

        record.anonymize!
        expect(record.secret).to eq("[REDACTED]")
      ensure
        ConcernsOnRails.encryption.raise_on_decrypt_error = true
      end

      it "does not let one undecryptable row roll back anonymize_all!" do
        good_writer = eraser(:hash)
        good = good_writer.create!(secret: "readable")
        bad = writer.create!(secret: "unreadable")

        expect(eraser(:hash).anonymize_all!).to eq(2)
        expect(good_writer.find(good.id).secret).to eq(Digest::SHA256.hexdigest("readable"))
        expect(good_writer.find(bad.id).secret).to eq("[REDACTED]")
      end
    end

    context "with a blind index" do
      let(:klass) do
        model_class do
          include ConcernsOnRails::Models::Encryptable

          encryptable :email, key: "anonymizable-spec-passphrase", blind_index: true
          anonymizable :email, with: :email
        end
      end

      it "rewrites the fingerprint in the same UPDATE, so the erased value stops resolving (1.26)" do
        record = klass.create!(email: "jane@real.example")
        expect(klass.find_by_email("jane@real.example")).to eq(record)

        old_fingerprint = record.email_bidx
        record.anonymize!

        # update_columns skips before_save, so without the explicit payload
        # entry the OLD value's fingerprint stayed queryable after erasure.
        expect(record.email_bidx).not_to eq(old_fingerprint)
        expect(record.email_bidx).to eq(klass.email_fingerprint(record.email))
        expect(klass.find_by_email("jane@real.example")).to be_nil
        expect(klass.find_by_email(record.email)).to eq(record)
      end

      it "nils the fingerprint when the strategy nullifies" do
        nullify_klass = model_class do
          include ConcernsOnRails::Models::Encryptable

          encryptable :email, key: "anonymizable-spec-passphrase", blind_index: true
          anonymizable :email, with: :nullify
        end

        record = nullify_klass.create!(email: "gone@real.example")
        record.anonymize!

        expect(record.email).to be_nil
        expect(record.email_bidx).to be_nil
      end
    end
  end

  describe "Sluggable interaction" do
    # update_columns skips callbacks, so a slug generated from an erased field
    # kept the PII ("jane-smith") in every URL — and friendly_id's history
    # table kept every earlier one.
    before do
      ActiveRecord::Schema.define do
        create_table :friendly_id_slugs, force: true do |t|
          t.string   :slug, null: false
          t.integer  :sluggable_id, null: false
          t.string   :sluggable_type, limit: 50
          t.string   :scope
          t.datetime :created_at
        end
      end
    end

    after { ActiveRecord::Base.connection.drop_table(:friendly_id_slugs) }

    def slugged_class(name = "AnonSluggedUser", sluggable: [:name], &block)
      klass = model_class do
        include ConcernsOnRails::Models::Sluggable
      end
      stub_const(name, klass)
      field, *options = sluggable
      klass.sluggable_by(field, **(options.first || {}))
      klass.class_eval(&block) if block
      klass
    end

    it "replaces a slug derived from an anonymized field with a non-identifying unique one" do
      klass = slugged_class { anonymizable :name, with: :redact }
      jane = klass.create!(name: "Jane Smith")
      john = klass.create!(name: "John Doe")
      expect(jane.slug).to eq("jane-smith")

      jane.anonymize!
      john.anonymize!

      expect(jane.slug).to match(/\Aanon-\h{32}\z/)
      expect(john.slug).to match(/\Aanon-\h{32}\z/)
      expect(jane.slug).not_to eq(john.slug)
      expect(klass.friendly.find(jane.slug)).to eq(jane)
      expect { klass.friendly.find("jane-smith") }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "rewrites the slug in the same single UPDATE" do
      klass = slugged_class { anonymizable :name, with: :redact }
      record = klass.create!(name: "Jane Smith")

      statements = capture_sql { record.anonymize! }
      expect(statements.grep(/\AUPDATE/i).size).to eq(1)
    end

    it "leaves the slug alone when its source field is not anonymized" do
      klass = slugged_class { anonymizable :email, with: :email }
      record = klass.create!(name: "Public Title", email: "jane@example.com")
      record.anonymize!
      expect(record.slug).to eq("public-title")
    end

    it "rewrites the slug when an anonymized field is one of its candidates" do
      klass = slugged_class(sluggable: [:email, { candidates: [:name, %i[name phone]] }]) do
        anonymizable :name, with: :redact
      end
      record = klass.create!(name: "Jane Smith", email: "x@example.com")
      expect(record.slug).to eq("jane-smith")

      record.anonymize!
      expect(record.slug).to match(/\Aanon-\h{32}\z/)
    end

    it "keeps an explicit rule for the slug column itself" do
      klass = slugged_class do
        anonymizable :name, with: :redact
        anonymizable :slug, with: ->(_value, record) { "user-#{record.id}" }
      end
      record = klass.create!(name: "Jane Smith")
      record.anonymize!
      expect(record.slug).to eq("user-#{record.id}")
    end

    it "deletes the record's friendly_id history rows, and only its own" do
      klass = slugged_class(sluggable: [:name, { history: true }]) { anonymizable :name, with: :redact }
      jane = klass.create!(name: "Jane Smith")
      jane.update!(name: "Jane Doe")
      other = klass.create!(name: "Other Person")
      expect(FriendlyId::Slug.where(sluggable_id: jane.id).pluck(:slug)).to contain_exactly("jane-smith", "jane-doe")

      jane.anonymize!

      expect(FriendlyId::Slug.where(sluggable_id: jane.id)).to be_empty
      expect(FriendlyId::Slug.where(sluggable_id: other.id).pluck(:slug)).to eq(["other-person"])
      expect { klass.friendly.find("jane-smith") }.to raise_error(ActiveRecord::RecordNotFound)
      expect { klass.friendly.find("jane-doe") }.to raise_error(ActiveRecord::RecordNotFound)
      expect(klass.friendly.find(jane.slug)).to eq(jane)
    end

    it "rolls the history deletion back with the erasure when a hook raises" do
      klass = slugged_class(sluggable: [:name, { history: true }]) do
        anonymizable :name, with: :redact
        define_method(:after_anonymize) { raise "veto" }
      end
      jane = klass.create!(name: "Jane Smith")

      expect { jane.anonymize! }.to raise_error("veto")
      expect(klass.find(jane.id).slug).to eq("jane-smith")
      expect(FriendlyId::Slug.where(sluggable_id: jane.id).pluck(:slug)).to eq(["jane-smith"])
    end

    it "rewrites slugs and history in anonymize_all! too" do
      klass = slugged_class(sluggable: [:name, { history: true }]) { anonymizable :name, with: :redact }
      a = klass.create!(name: "Alice Adams")
      b = klass.create!(name: "Bob Brown")

      expect(klass.anonymize_all!).to eq(2)
      slugs = klass.order(:id).pluck(:slug)
      expect(slugs).to all(match(/\Aanon-\h{32}\z/))
      expect(slugs.uniq.size).to eq(2)
      expect(FriendlyId::Slug.where(sluggable_id: [a.id, b.id])).to be_empty
    end
  end
end
