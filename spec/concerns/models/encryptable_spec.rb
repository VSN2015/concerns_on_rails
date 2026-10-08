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

    # Time#utc converts its receiver IN PLACE. The serializer rewrote the
    # caller's own Time to UTC, and on a frozen one it raised FrozenError,
    # which the type swallowed, so the field was saved as NULL.
    it "stores a frozen non-UTC Time (:datetime) and never touches the caller's Time" do
      klass = model_class { encryptable :meeting_at, type: :datetime }
      frozen = Time.new(2026, 1, 2, 3, 4, 5, "+07:00").freeze
      record = klass.create!(meeting_at: frozen)
      expect(klass.find(record.id).meeting_at).to eq(frozen)

      local = Time.new(2026, 1, 2, 3, 4, 5, "+07:00")
      klass.create!(meeting_at: local)
      expect(local.utc_offset).to eq(7 * 3600)
    end

    # Time.iso8601 reads a zone-less "...T13:00:00" in the SERVER's zone. Only
    # a plaintext carrying Z or an offset takes that path; any other form is a
    # database value, read in default_timezone (UTC) as a datetime column is.
    it "reads a zone-less ISO8601 plaintext in default_timezone, not the server's zone" do
      previous_tz = ENV.fetch("TZ", nil)
      ENV["TZ"] = "Asia/Tokyo"
      klass = model_class { encryptable :meeting_at, type: :datetime }
      ConcernsOnRails.encryption.key = nil
      ConcernsOnRails.encryption.on_missing_key = :passthrough
      record = klass.create!
      klass.where(id: record.id).update_all("meeting_at = '2026-10-01T13:00:00'")

      expect(klass.find(record.id).meeting_at).to eq(Time.utc(2026, 10, 1, 13))
    ensure
      ENV["TZ"] = previous_tz
    end

    # The cast parsed a zone-less String with Time.iso8601 (the process's
    # SYSTEM zone) or ActiveModel's DateTime (UTC), a Date as UTC midnight, and
    # read back plain UTC Times. A datetime column on the same model reads that
    # input in Time.zone. Every Rails app sets time_zone_aware_attributes; the
    # harness does not, so it is set here.
    describe "type: :datetime in a time-zone-aware app" do
      around { |example| Time.use_zone("America/New_York") { example.run } }

      # A real datetime column to compare with. clear_cache! drops the prepared
      # `SELECT *` earlier examples cached with the old column list.
      before do
        ActiveRecord::Base.connection.add_column :encryptable_records, :meeting_column_at, :datetime
        ActiveRecord::Base.connection.clear_cache!
      end

      let(:klass) do
        model_class do
          self.time_zone_aware_attributes = true
          encryptable :meeting_at, type: :datetime
        end
      end

      it "parses a zone-less String in Time.zone, like a datetime column" do
        record = klass.new(meeting_at: "2026-10-01T09:00", meeting_column_at: "2026-10-01T09:00")

        expect(record.meeting_column_at.getutc).to eq(Time.utc(2026, 10, 1, 13)) # 09:00 EDT
        expect(record.meeting_at).to eq(record.meeting_column_at)
        record.save!
        expect(klass.find(record.id).meeting_at).to eq(record.meeting_column_at)
      end

      it "treats a Date as midnight in Time.zone, like a datetime column" do
        record = klass.new(meeting_at: Date.new(2026, 10, 1), meeting_column_at: Date.new(2026, 10, 1))
        expect(record.meeting_at).to eq(record.meeting_column_at)
      end

      it "reads back as a TimeWithZone in the reader's Time.zone" do
        record = klass.create!(meeting_at: Time.utc(2026, 10, 1, 13))

        reloaded = klass.find(record.id)
        expect(reloaded.meeting_at).to be_a(ActiveSupport::TimeWithZone)
        expect([reloaded.meeting_at.time_zone.name, reloaded.meeting_at.hour]).to eq(["America/New_York", 9])
        Time.use_zone("Tokyo") { expect(klass.find(record.id).meeting_at.hour).to eq(22) }
      end

      it "reads a row written before the fix (a UTC ISO8601 plaintext) as the same instant" do
        plain = model_class { encryptable :meeting_at, type: :datetime }
        record = plain.create!(meeting_at: Time.utc(2026, 10, 1, 13))

        expect(klass.find(record.id).meeting_at).to eq(Time.utc(2026, 10, 1, 13))
        expect(klass.find(record.id).meeting_at_changed?).to be(false)
      end

      # A plaintext not in the gem's own ISO8601 form (a plain column adopted
      # under on_missing_key: :passthrough) is a DATABASE value: it is read
      # the way a datetime column reads one, in default_timezone (UTC), and
      # only then shown in Time.zone. It is not wall-clock time in Time.zone.
      it "reads a zone-less stored plaintext as UTC, like a datetime column reads the database" do
        ConcernsOnRails.encryption.key = nil
        ConcernsOnRails.encryption.on_missing_key = :passthrough
        record = klass.create!
        klass.where(id: record.id).update_all("meeting_at = '2026-10-01 13:00:00'")

        expect(klass.find(record.id).meeting_at).to eq(Time.utc(2026, 10, 1, 13))
        expect(klass.find(record.id).meeting_at.time_zone.name).to eq("America/New_York")
      end

      # Rails itself decides whether a declared datetime attribute converts:
      # per class at schema load up to 7.1, on the declaring class when it is
      # declared from 7.2. Up to 7.1 the field follows a subclass's (or a
      # later) skip list exactly as a declared attribute does. From 7.2 that
      # skip list cannot reach it, and saying so beats converting silently.
      describe "a skip list set on a subclass, or after the encryptable line" do
        let(:declaration_time) { ConcernsOnRails::Models::Encryptable.declaration_time_zone_conversion? }
        let(:parent) do
          model_class do
            self.time_zone_aware_attributes = true
            encryptable :meeting_at, type: :datetime
            attribute :declared_at, :datetime
          end
        end

        # The refusal comes when ActiveRecord first builds the class's
        # attributes, never while the class body runs (no schema access).
        it "on a subclass: honoured like a declared attribute up to Rails 7.1, refused at first use from 7.2" do
          child = Class.new(parent) { self.skip_time_zone_conversion_for_attributes = %i[meeting_at declared_at] }
          build = -> { child.new(meeting_at: "2026-10-01T09:00", declared_at: "2026-10-01T09:00") }
          if declaration_time
            expect(&build).to raise_error(ArgumentError, /set the skip list before the `encryptable` line, or re-declare/)
          else
            record = build.call
            expect(record.meeting_at).to eq(record.declared_at)
            expect(record.meeting_at).to eq(Time.utc(2026, 10, 1, 9))
          end
          expect(parent.new(meeting_at: "2026-10-01T09:00").meeting_at.getutc).to eq(Time.utc(2026, 10, 1, 13))
        end

        it "on a subclass that re-declares the field after its skip list: honoured on every Rails line" do
          child = Class.new(parent) do
            self.skip_time_zone_conversion_for_attributes = %i[meeting_at]
            encryptable :meeting_at, type: :datetime
          end

          expect(child.new(meeting_at: "2026-10-01T09:00").meeting_at).to eq(Time.utc(2026, 10, 1, 9))
          expect(parent.new(meeting_at: "2026-10-01T09:00").meeting_at.getutc).to eq(Time.utc(2026, 10, 1, 13))
        end

        it "after the encryptable line in the same class: honoured up to Rails 7.1, refused at first use from 7.2" do
          late = model_class do
            self.time_zone_aware_attributes = true
            encryptable :meeting_at, type: :datetime
            self.skip_time_zone_conversion_for_attributes = %i[meeting_at meeting_column_at]
          end
          build = -> { late.new(meeting_at: "2026-10-01T09:00", meeting_column_at: "2026-10-01T09:00") }
          if declaration_time
            expect(&build).to raise_error(ArgumentError, /skip_time_zone_conversion_for_attributes names :meeting_at/)
          else
            record = build.call
            expect(record.meeting_at).to eq(record.meeting_column_at)
          end
        end

        it "before the encryptable line: honoured on every Rails line, like the column" do
          early = model_class do
            self.time_zone_aware_attributes = true
            self.skip_time_zone_conversion_for_attributes = %i[meeting_at meeting_column_at]
            encryptable :meeting_at, type: :datetime
          end
          record = early.new(meeting_at: "2026-10-01T09:00", meeting_column_at: "2026-10-01T09:00")

          expect(record.meeting_column_at).to eq(Time.utc(2026, 10, 1, 9))
          expect(record.meeting_at).to eq(record.meeting_column_at)
        end

        # ActiveRecord reads the list with include?(name.to_sym), so a String
        # entry skips nothing, for the column and the field alike.
        it "a String entry skips nothing, like for the column, and is not refused" do
          strings = model_class do
            self.time_zone_aware_attributes = true
            self.skip_time_zone_conversion_for_attributes = %w[meeting_at meeting_column_at]
            encryptable :meeting_at, type: :datetime
          end
          record = strings.new(meeting_at: "2026-10-01T09:00", meeting_column_at: "2026-10-01T09:00")

          expect(record.meeting_column_at.getutc).to eq(Time.utc(2026, 10, 1, 13))
          expect(record.meeting_at).to eq(record.meeting_column_at)
        end

        # PR #125 review round 6 (R6-01): every *_by macro's column check
        # loads the schema mid-body, and 7.2+ builds the attribute set there.
        it "allows a column-checking macro between a late skip list and the re-declaration" do
          child = Class.new(parent) do
            self.skip_time_zone_conversion_for_attributes = %i[meeting_at]
            column_names # what every *_by macro's ColumnGuard does
            encryptable :meeting_at, type: :datetime
          end

          expect(child.new(meeting_at: "2026-10-01T09:00").meeting_at).to eq(Time.utc(2026, 10, 1, 9))
        end

        it "is also refused on a query that builds no record, from Rails 7.2" do
          late = model_class do
            self.time_zone_aware_attributes = true
            encryptable :meeting_at, type: :datetime
            self.skip_time_zone_conversion_for_attributes = %i[meeting_at]
          end
          query = -> { late.pluck(:meeting_at) }
          if declaration_time
            expect(&query).to raise_error(ArgumentError, /skip_time_zone_conversion_for_attributes names :meeting_at/)
          else
            expect(query.call).to eq([])
          end
        end
      end

      # PR #125 review round 5 (R5-04): the Infinity writer guard (since
      # removed) defined `<field>=` above an abstract class, so ActiveRecord
      # never generated the concrete subclass's writer.
      it "an abstract base class may declare the field" do
        base = Class.new(TestModel) do
          self.abstract_class = true
          include ConcernsOnRails::Models::Encryptable

          self.time_zone_aware_attributes = true
          encryptable :meeting_at, type: :datetime
        end
        concrete = Class.new(base) { self.table_name = "encryptable_records" }

        record = concrete.create!(meeting_at: "2026-10-01T09:00")
        expect(concrete.find(record.id).meeting_at.getutc).to eq(Time.utc(2026, 10, 1, 13))
      end

      # PR #125 review round 2 (R2-02): re-declaring the field on every
      # subclass replaced the type, dropping the parent's `normalizes`.
      it "keeps the parent's normalizes in an STI subclass", min_rails: "7.1" do
        parent = model_class do
          self.time_zone_aware_attributes = true
          encryptable :meeting_at, type: :datetime
          normalizes :meeting_at, :meeting_column_at, with: ->(time) { time.change(sec: 0) }
        end
        record = Class.new(parent).new(meeting_at: "2026-10-01T09:00:30", meeting_column_at: "2026-10-01T09:00:30")

        expect(record.meeting_column_at.sec).to eq(0)
        expect(record.meeting_at.sec).to eq(0)
      end

      # R2-03: a subclass defined before the parent re-declared the field
      # kept the old key, so the parent could not read what it wrote.
      it "a subclass picks up the parent's later re-declaration of the field (its key)" do
        parent = model_class do
          self.time_zone_aware_attributes = true
          encryptable :meeting_at, type: :datetime
        end
        child = Class.new(parent)
        parent.encryptable :meeting_at, type: :datetime, key: "concerns-on-rails-rotated-field-key"
        record = child.create!(meeting_at: Time.utc(2026, 10, 1, 13))

        expect(parent.find(record.id).meeting_at).to eq(Time.utc(2026, 10, 1, 13))
      end

      # datetime_select posts a multiparameter Hash. It was cast as UTC
      # wall-clock time and then moved into Time.zone, so 09:00 became 05:00.
      it "reads datetime_select (multiparameter) input as wall-clock time in Time.zone, like a column" do
        parts = { "1i" => "2026", "2i" => "10", "3i" => "1", "4i" => "09", "5i" => "00" }
        attributes = %w[meeting_at meeting_column_at].each_with_object({}) do |name, all|
          parts.each { |part, value| all["#{name}(#{part})"] = value }
        end
        record = klass.new(attributes)

        expect(record.meeting_column_at.getutc).to eq(Time.utc(2026, 10, 1, 13)) # 09:00 EDT
        expect(record.meeting_at).to eq(record.meeting_column_at)
      end
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

    # Normalizable's before_save backstop (saves that skip validation) is
    # prepended: registered after Encryptable's blind-index refresh, it ran
    # after it, so the row stored the normalized value but fingerprinted the
    # raw one and find_by_email missed it forever.
    it "fingerprints the value Normalizable's before_save backstop stores (update_attribute)" do
      klass = model_class do
        include ConcernsOnRails::Models::Normalizable

        encryptable :email, blind_index: true
        normalizable :email, with: :email
      end
      user = klass.create!(email: "a@b.com")
      user.update_attribute(:email, "  Foo@Example.COM ")

      stored = user.reload.email
      expect(stored).to eq("foo@example.com")
      expect(klass.find_by_email(stored)).to eq(user)
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

      # alias_attribute's reader returns the column's value, so a slug built
      # from the alias stored the plaintext SSN.
      it "raises when a slug candidate is an alias_attribute of an encrypted field, either order" do
        expect do
          model_class do
            include ConcernsOnRails::Models::Sluggable

            alias_attribute :tax_id, :ssn
            sluggable_by :name, candidates: [:tax_id]
            encryptable :ssn
          end
        end.to raise_error(ArgumentError, /:ssn.*slug source/)

        expect do
          model_class do
            include ConcernsOnRails::Models::Sluggable

            encryptable :ssn
            alias_attribute :tax_id, :ssn
            sluggable_by :name, candidates: [:tax_id]
          end
        end.to raise_error(ArgumentError, /Sluggable/)

        # An alias of an alias still reads the column on Rails <= 7.0.
        expect do
          model_class do
            include ConcernsOnRails::Models::Sluggable

            encryptable :ssn
            alias_attribute :tax_id, :ssn
            alias_attribute :tid, :tax_id
            sluggable_by :name, candidates: [:tid]
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

      it "also refuses save(validate: false), which skips friendly_id's before_validation" do
        klass = model_class do
          include ConcernsOnRails::Models::Sluggable

          encryptable :name
        end
        stub_const("EncSlugNoValidate", klass)
        expect { klass.new(name: "Jane Smith").save(validate: false) }.to raise_error(ArgumentError)
        expect(klass.connection.select_value("SELECT COUNT(*) FROM encryptable_records").to_i).to eq(0)
      end

      it "STI: a subclass encrypting its parent's implicit :name source is refused; the parent is not" do
        parent = Class.new(TestModel) do
          self.table_name = "encryptable_records"
          include ConcernsOnRails::Models::Sluggable
        end
        stub_const("EncSlugParent", parent)
        child = Class.new(parent) do
          include ConcernsOnRails::Models::Encryptable

          encryptable :name
        end
        stub_const("EncSlugChild", child)

        expect(parent.create!(name: "Ok").slug).to eq("ok")
        expect { child.create!(name: "Jane Smith") }.to raise_error(ArgumentError, /:name/)
      end

      it "no false positives: a safe slug source (explicit or the implicit :name) keeps slugging" do
        explicit = model_class do
          include ConcernsOnRails::Models::Sluggable

          sluggable_by :name
          encryptable :ssn
        end
        stub_const("EncSlugSafe", explicit)
        record = explicit.create!(name: "Hello World", ssn: "123-45-6789")
        record.update!(name: "New Title", ssn: "999-99-9999")
        record.regenerate_slug!
        expect(raw_slug(explicit, record.id)).to eq("new-title")

        implicit = model_class do
          encryptable :ssn
          include ConcernsOnRails::Models::Sluggable
        end
        stub_const("EncSlugSafeImplicit", implicit)
        expect(raw_slug(implicit, implicit.create!(name: "Jane", ssn: "1").id)).to eq("jane")
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

  # The blind index hashed `value.to_s`: the CAST value on write, the RAW
  # argument on lookup. Under time-zone awareness the written :datetime is a
  # TimeWithZone in the request's zone, so `find_by_meeting_at(the same
  # instant)` missed as soon as the zones differed (and a String never found a
  # typed field). Both sides now hash the canonical plaintext the cipher gets;
  # lookups also try the old digest, so rows indexed before stay findable.
  describe "blind index on a typed field (canonical fingerprint)" do
    before do
      connection = ActiveRecord::Base.connection
      %i[meeting_at_bidx age_bidx amount_bidx].each { |column| connection.add_column :encryptable_records, column, :string }
      connection.clear_cache!
    end

    let(:klass) do
      model_class do
        self.time_zone_aware_attributes = true
        encryptable :meeting_at, type: :datetime, blind_index: true
        encryptable :age, type: :integer, blind_index: true
        encryptable :amount, type: :decimal, blind_index: true
      end
    end

    # What the code before this change wrote: the digest of `value.to_s`.
    def legacy_digest(value)
      config = ConcernsOnRails.encryption
      ConcernsOnRails::Support::Encryptor.blind_index(value.to_s, key: config.resolve_material(nil), salt: config.key_derivation_salt)
    end

    let(:instant) { Time.utc(2026, 10, 1, 13) }

    it "finds a :datetime record by the very Time it was written with, in a non-UTC zone" do
      Time.use_zone("America/New_York") do
        record = klass.create!(meeting_at: instant)

        expect(klass.find_by_meeting_at(instant)).to eq(record)
        expect(klass.where_meeting_at(instant).to_a).to eq([record])
      end
    end

    it "finds it whatever zone the writer and the reader run in, by any rendering of the instant" do
      record = Time.use_zone("Tokyo") { klass.create!(meeting_at: "2026-10-01T13:00:00Z") }

      Time.use_zone("UTC") do
        expect(klass.find_by_meeting_at(klass.find(record.id).meeting_at)).to eq(record)
        expect(klass.find_by_meeting_at(instant)).to eq(record)
      end
      Time.use_zone("America/New_York") do
        expect(klass.find_by_meeting_at("2026-10-01T13:00:00Z")).to eq(record)
        expect(klass.find_by_meeting_at("2026-10-01T09:00")).to eq(record) # wall clock in Time.zone, as the writer reads it
        expect(klass.find_by_meeting_at(instant.in_time_zone("Tokyo"))).to eq(record)
        expect(klass.meeting_at_fingerprint(instant)).to eq(klass.find(record.id).meeting_at_bidx)
      end
    end

    it "casts a lookup through the field's type, so any spelling of the value finds it" do
      record = klass.create!(age: 42, amount: BigDecimal("19.99"))

      expect([klass.find_by_age("042"), klass.find_by_age(" 42 "), klass.find_by_age(42)]).to eq([record] * 3)
      expect([klass.find_by_amount("19.990"), klass.find_by_amount(BigDecimal("19.99"))]).to eq([record] * 2)
    end

    it "writes the same digest whatever zone reencrypt! runs in" do
      record = Time.use_zone("Tokyo") { klass.create!(meeting_at: instant) }
      ConcernsOnRails.configure_encryption do |c|
        c.key = "concerns-on-rails-encryptable-rotated-key"
        c.key_id = 1
        c.previous_keys = { 0 => TEST_KEY }
      end

      expect(Time.use_zone("Pacific/Honolulu") { klass.find(record.id).reencrypt! }).to be(true)
      expect(klass.find(record.id).meeting_at_bidx).to eq(Time.use_zone("Tokyo") { klass.meeting_at_fingerprint(instant) })
      expect(Time.use_zone("UTC") { klass.find_by_meeting_at(instant) }).to eq(record)
    end

    it "hands expression: the typed value, a :datetime in UTC, so the request zone never reaches the digest" do
      dated = model_class do
        self.time_zone_aware_attributes = true
        encryptable :meeting_at, type: :datetime, blind_index: { expression: :to_date.to_proc }
      end
      record = Time.use_zone("Tokyo") { dated.create!(meeting_at: Time.utc(2026, 10, 1, 20)) } # Oct 2 in Tokyo

      expect(Time.use_zone("America/New_York") { dated.find_by_meeting_at(Time.utc(2026, 10, 1, 5)) }).to eq(record)
    end

    it "still finds a row indexed before the change, and the documented reindex moves it to the canonical digest" do
      record = klass.create!(meeting_at: instant, age: 42)
      record.update_columns(meeting_at_bidx: legacy_digest(instant))
      # Every other type's canonical form IS its to_s: nothing to reindex.
      expect(klass.find(record.id).age_bidx).to eq(legacy_digest(42))

      # The value the old code was looked up with still matches...
      expect(klass.find_by_meeting_at(instant)).to eq(record)
      # ...but only the canonical digest knows every other rendering.
      expect(klass.find_by_meeting_at("2026-10-01T13:00:00Z")).to be_nil

      reindex(klass)

      expect(klass.find_by_meeting_at("2026-10-01T13:00:00Z")).to eq(record)
      expect(klass.find(record.id).meeting_at_bidx).to eq(klass.meeting_at_fingerprint(instant))
    end

    # The reindex recipe in docs/concerns/encryptable.md, verbatim apart from names.
    def reindex(model)
      model.unscoped.where.not(meeting_at: nil).find_each do |meeting|
        meeting_at = meeting.meeting_at
        next if meeting_at.nil? # undecryptable (raise_on_decrypt_error off): keep the digest it has

        meeting.update_columns(meeting_at_bidx: model.meeting_at_fingerprint(meeting_at))
      end
    end

    # PR #125 review round 2 (R2-05): the recipe wrote the fingerprint of the
    # nil an undecryptable row reads as, erasing its digest.
    it "the documented reindex keeps the digest of a row it cannot decrypt" do
      record = klass.create!(meeting_at: instant)
      digest = klass.find(record.id).meeting_at_bidx
      ConcernsOnRails.encryption.key = "concerns-on-rails-a-key-whose-previous-was-lost"
      ConcernsOnRails.encryption.raise_on_decrypt_error = false

      reindex(klass)

      expect(klass.unscoped.where(id: record.id).pick(:meeting_at_bidx)).to eq(digest)
    end

    # R2-01: "abc" casts to 0, but an integer column's where(age: "abc")
    # finds nothing (Integer#serialize refuses a non-numeric String).
    it "finds nothing for a non-numeric String on an :integer field, as an integer column's where does" do
      klass.create!(age: 0, amount: BigDecimal("0"))

      expect(klass.find_by_age("abc")).to be_nil
      expect(klass.where_age("abc", "none").to_a).to eq([])
      expect(klass.find_by_amount("abc")).to be_nil
      expect(klass.find_by_age("0")).not_to be_nil
    end

    # R3-04: a decimal column reads ".5" as 0.5, in `where` as on assignment.
    it "finds a :decimal row by a leading-dot String, as a decimal column's where does" do
      record = klass.create!(amount: "-.5")

      expect(klass.find(record.id).amount).to eq(BigDecimal("-0.5"))
      expect(klass.find_by_amount("-.5")).to eq(record)
      expect(klass.where_amount("-0.50").to_a).to eq([record])
    end

    # R3-05: from Rails 7.0 the time-zone converter hands Infinity through
    # uncast. It is stored as NULL, so no digest may be written beside it.
    it "writes no digest for a value that does not cast" do
      record = klass.create!(meeting_at: Float::INFINITY)

      expect(klass.unscoped.where(id: record.id).pick(:meeting_at, :meeting_at_bidx)).to eq([nil, nil])
      expect(klass.find_by_meeting_at(Float::INFINITY)).to be_nil
    end

    # Whichever class decides the conversion (see the skip-list specs), a
    # lookup reads a zone-less String exactly as an assignment on that class.
    it "a lookup on a subclass reads a zone-less String as that subclass's assignment does" do
      child = Class.new(klass) { self.time_zone_aware_attributes = false }
      Time.use_zone("America/New_York") do
        record = child.create!(meeting_at: "2026-10-01T09:00")

        expect(child.find_by_meeting_at("2026-10-01T09:00")).to eq(record)
        expect(child.find_by_meeting_at(child.find(record.id).meeting_at)).to eq(record)
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

  describe "plaintext encoding" do
    let(:klass) { model_class { encryptable :name } }

    it "reads non-ASCII text back as UTF-8, equal to what was written" do
      record = klass.create!(name: "José Müller").reload
      expect(record.name.encoding).to eq(Encoding::UTF_8)
      expect(record.name).to eq("José Müller")
    end

    it "does not mark a non-ASCII value changed when the same text is assigned again" do
      record = klass.create!(name: "José").reload
      record.name = "José"
      expect(record.name_changed?).to be(false)
    end

    it "keeps bytes that are not valid UTF-8 binary" do
      record = klass.create!(name: "\xFF\xFE".b).reload
      expect(record.name.encoding).to eq(Encoding::BINARY)
      expect(record.name.bytes).to eq([0xFF, 0xFE])
    end

    it "re-fingerprints non-ASCII text identically after a key rotation" do
      indexed = model_class { encryptable :email, blind_index: { expression: ->(v) { v.to_s.downcase } } }
      record = indexed.create!(email: "JOSÉ@Example.com")

      ConcernsOnRails.encryption.key = "#{TEST_KEY}-rotated"
      ConcernsOnRails.encryption.key_id = 1
      ConcernsOnRails.encryption.previous_keys = { 0 => TEST_KEY }
      expect(indexed.reencrypt_all!).to eq(1)

      ConcernsOnRails.encryption.previous_keys = {}
      expect(indexed.find_by_email("josé@example.com")&.id).to eq(record.id)
    end
  end

  describe "an empty-string column default" do
    before do
      ActiveRecord::Schema.define do
        create_table :encryptable_defaults, force: true do |t|
          t.text :notes, null: false, default: ""
        end
      end
    end

    let(:klass) do
      Class.new(TestModel) do
        self.table_name = "encryptable_defaults"
        include ConcernsOnRails::Models::Encryptable

        encryptable :notes
      end
    end

    it "reads the default as the plaintext \"\" instead of raising DecryptionError" do
      expect(klass.new.notes).to eq("")
      expect(klass.create!.reload.notes).to eq("")
      expect(klass.create!(notes: "x").reload.notes).to eq("x")
    end
  end

  describe "blind index refresh timing" do
    it "fingerprints the value a later before_save rewrote, not the assigned one" do
      klass = model_class do
        encryptable :email, blind_index: true
        before_save { self.email = email.downcase if email }
      end
      record = klass.create!(email: "Alice@Example.com")
      expect(klass.find_by_email("alice@example.com")).to eq(record)

      record.update!(email: "Bob@Example.com")
      expect(klass.find_by_email("bob@example.com")).to eq(record)
      expect(klass.find_by_email("alice@example.com")).to be_nil
    end

    it "never lets a new row carry a digest its own value does not have" do
      klass = model_class { encryptable :email, blind_index: true }
      original = klass.create!(email: "a@b.com")

      copy = klass.create!(email_bidx: original.reload.email_bidx)
      expect(copy.reload.email_bidx).to be_nil
      expect(klass.where_email("a@b.com").pluck(:id)).to eq([original.id])
    end

    it "clears the digest of a field Duplicable resets on the copy" do
      klass = model_class do
        include ConcernsOnRails::Models::Duplicable

        encryptable :email, blind_index: true
        duplicable_by reset: %i[email]
      end
      original = klass.create!(email: "a@b.com")
      copy = original.duplicate!

      expect(copy.reload.email_bidx).to be_nil
      expect(klass.where_email("a@b.com").pluck(:id)).to eq([original.id])
    end
  end

  describe "lookups through a native `normalizes`", min_rails: "7.1" do
    it "normalizes the lookup value as Rails' own finders do" do
      klass = model_class do
        encryptable :email, blind_index: true
        normalizes :email, with: ->(email) { email.strip.downcase }
      end
      record = klass.create!(email: "  Alice@Example.COM ")

      expect(klass.find_by_email("Alice@Example.COM")).to eq(record)
      expect(klass.where_email(" ALICE@example.com").to_a).to eq([record])
      expect(klass.email_fingerprint("ALICE@EXAMPLE.COM")).to eq(record.reload.email_bidx)
      expect(klass.find_by_email(nil)).to be_nil
    end

    it "still refuses a non-numeric String on a normalized :integer field" do
      klass = model_class do
        encryptable :age, type: :integer, blind_index: { column: :email_bidx }
        normalizes :age, with: ->(age) { age.to_i.abs }
      end
      klass.create!(age: 0)
      negative = klass.create!(age: -5)

      expect(klass.find_by_age(-5)).to eq(negative)
      expect(klass.find_by_age("abc")).to be_nil
      expect(klass.where_age("abc")).to be_empty
    end
  end

  describe "Lockable's unlock_token" do
    before do
      ActiveRecord::Schema.define do
        create_table :encryptable_lockables, force: true do |t|
          t.integer :failed_attempts, default: 0, null: false
          t.datetime :locked_at
          t.text :unlock_token
          t.string :unlock_token_bidx
        end
      end
    end

    def lockable_model(&declaration)
      klass = Class.new(TestModel) do
        self.table_name = "encryptable_lockables"
        include ConcernsOnRails::Models::Encryptable
        include ConcernsOnRails::Models::Lockable
      end
      klass.class_eval(&declaration)
      klass
    end

    it "refuses an encrypted unlock_token declared after lockable_by" do
      expect do
        lockable_model do
          lockable_by unlock_token: :unlock_token
          encryptable :unlock_token, blind_index: true
        end
      end.to raise_error(ArgumentError, /unlock_token.*never found/)
    end

    it "refuses an encrypted unlock_token declared before lockable_by" do
      expect do
        lockable_model do
          encryptable :unlock_token, blind_index: true
          lockable_by unlock_token: :unlock_token
        end
      end.to raise_error(ArgumentError, /unlock_token.*never found/)
    end
  end
end
