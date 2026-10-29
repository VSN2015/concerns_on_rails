require "spec_helper"

# DATA-2: a per-field `key:` that resolves to nil/empty used to be treated as
# "no field key declared", so the value was sealed under the GLOBAL key as a
# key_id-0 envelope. Once the field key resolved, those rows could not be
# decrypted (the per-field path never uses the global key) and rotation could
# never find them; under on_missing_key: :passthrough they were plaintext.
describe "Encryptable per-field key: that resolves to nil" do
  let(:global_key) { "field-key-nil-global-key" }

  before do
    ActiveRecord::Schema.define do
      create_table(:field_key_nils, force: true) do |t|
        t.text :ssn
        t.string :ssn_bidx
      end
    end
    ConcernsOnRails.encryption.key = global_key
  end

  after(:each) do
    ActiveRecord::Base.connection.drop_table(:field_key_nils, if_exists: true)
    ConcernsOnRails.encryption.key = nil
    ConcernsOnRails.encryption.on_missing_key = :raise
    ConcernsOnRails.encryption.raise_on_decrypt_error = true
    ConcernsOnRails.encryption.key_id = 0
    ConcernsOnRails.encryption.previous_keys = {}
  end

  def model_with(key_proc, **opts)
    Class.new(TestModel) do
      self.table_name = "field_key_nils"
      include ConcernsOnRails::Models::Encryptable

      encryptable :ssn, key: key_proc, **opts
    end
  end

  def raw_ssn(id)
    ActiveRecord::Base.connection.select_value("SELECT ssn FROM field_key_nils WHERE id = #{id.to_i}")
  end

  it "raises MissingKeyError naming the field on create when the key resolves to nil" do
    klass = model_with(-> {})
    expect { klass.create!(ssn: "123-45-6789") }
      .to raise_error(ConcernsOnRails::Encryption::MissingKeyError, /`ssn`/)
    expect(klass.count).to eq(0)
  end

  it "raises MissingKeyError when the key resolves to an empty String" do
    expect { model_with(-> { "" }).create!(ssn: "123-45-6789") }
      .to raise_error(ConcernsOnRails::Encryption::MissingKeyError)
    expect { model_with("").create!(ssn: "123-45-6789") }
      .to raise_error(ConcernsOnRails::Encryption::MissingKeyError)
  end

  it "raises on reading a stored row while the field key is missing" do
    field_key = "the-field-key"
    klass = model_with(-> { field_key })
    id = klass.create!(ssn: "123-45-6789").id

    field_key = nil
    expect { klass.find(id).ssn }.to raise_error(ConcernsOnRails::Encryption::MissingKeyError)

    field_key = "the-field-key"
    expect(klass.find(id).ssn).to eq("123-45-6789")
  end

  it "still works when the Proc resolves, and never writes under the global key" do
    klass = model_with(-> { "the-field-key" })
    record = klass.create!(ssn: "123-45-6789").reload
    expect(record.ssn).to eq("123-45-6789")

    stored = raw_ssn(record.id)
    expect(ConcernsOnRails::Support::Encryptor.key_id(stored)).to eq(0)
    expect { ConcernsOnRails::Support::Encryptor.decrypt(stored, key: global_key) }
      .to raise_error(ConcernsOnRails::Encryption::DecryptionError)
    expect(ConcernsOnRails::Support::Encryptor.decrypt(stored, key: "the-field-key")).to eq("123-45-6789")
  end

  it "writes nothing under the global key on an update while the key is missing" do
    field_key = "the-field-key"
    klass = model_with(-> { field_key })
    id = klass.create!(ssn: "123-45-6789").id
    before_stored = raw_ssn(id)

    field_key = nil
    expect { klass.find(id).update!(ssn: "987-65-4321") }
      .to raise_error(ConcernsOnRails::Encryption::MissingKeyError)
    expect(raw_ssn(id)).to eq(before_stored)
  end

  describe "key: passed but evaluated eagerly to nil" do
    def eager_model(**opts)
      Class.new(TestModel) do
        self.table_name = "field_key_nils"
        include ConcernsOnRails::Models::Encryptable

        encryptable :ssn, **opts
      end
    end

    it "treats a literal key: nil as a declared, missing key" do
      expect { eager_model(key: nil).create!(ssn: "123-45-6789") }
        .to raise_error(ConcernsOnRails::Encryption::MissingKeyError, /`ssn`/)
    end

    it "treats key: ENV[...] of an unset variable the same" do
      expect { eager_model(key: ENV.fetch("COR_UNSET_FIELD_KEY_VAR", nil)).create!(ssn: "x") }
        .to raise_error(ConcernsOnRails::Encryption::MissingKeyError, /`ssn`/)
    end

    it "raises at blind-index lookup and passes through under :passthrough" do
      klass = eager_model(key: nil, blind_index: true)
      expect { klass.where_ssn("x").to_a }.to raise_error(ConcernsOnRails::Encryption::MissingKeyError)
      ConcernsOnRails.encryption.on_missing_key = :passthrough
      expect(raw_ssn(klass.create!(ssn: "plain").id)).to eq("plain")
    end

    it "keeps an omitted key: on the global key" do
      record = eager_model.create!(ssn: "123-45-6789")
      expect(ConcernsOnRails::Support::Encryptor.decrypt(raw_ssn(record.id), key: global_key)).to eq("123-45-6789")
    end

    it "keeps a key: nil field out of rotation like any per-field key" do
      expect(eager_model(key: nil).encryptable_rules[:ssn][:key]).not_to be_nil
      expect(eager_model.encryptable_rules[:ssn][:key]).to be_nil
    end

    it "refuses a key: that is neither a String nor callable" do
      [false, 123, :sym].each do |bad|
        expect { eager_model(key: bad) }.to raise_error(ArgumentError, /key: must be a String or a callable/)
      end
    end
  end

  it "leaves a gem-keyed field on the global key (key_id stamped) as before" do
    klass = Class.new(TestModel) do
      self.table_name = "field_key_nils"
      include ConcernsOnRails::Models::Encryptable

      encryptable :ssn
    end
    ConcernsOnRails.encryption.key_id = 3
    record = klass.create!(ssn: "123-45-6789")
    expect(ConcernsOnRails::Support::Encryptor.key_id(raw_ssn(record.id))).to eq(3)
    expect(klass.find(record.id).ssn).to eq("123-45-6789")
  end

  describe "blind_index: true" do
    it "raises at write when the field key is nil" do
      klass = model_with(-> {}, blind_index: true)
      expect { klass.create!(ssn: "123-45-6789") }
        .to raise_error(ConcernsOnRails::Encryption::MissingKeyError, /`ssn`/)
    end

    it "raises at lookup when the field key is nil (never the global key's digest)" do
      field_key = "the-field-key"
      klass = model_with(-> { field_key }, blind_index: true)
      klass.create!(ssn: "123-45-6789")

      field_key = nil
      expect { klass.where_ssn("123-45-6789").to_a }
        .to raise_error(ConcernsOnRails::Encryption::MissingKeyError, /`ssn`/)
      expect { klass.find_by_ssn("123-45-6789") }.to raise_error(ConcernsOnRails::Encryption::MissingKeyError)
    end

    it "indexes under the field key when it resolves" do
      klass = model_with(-> { "the-field-key" }, blind_index: true)
      record = klass.create!(ssn: "123-45-6789")
      expect(klass.find_by_ssn("123-45-6789")).to eq(record)
      expect(record.ssn_bidx).to eq(ConcernsOnRails::Support::Encryptor.blind_index("123-45-6789", key: "the-field-key"))
    end
  end

  describe "on_missing_key: :passthrough" do
    before { ConcernsOnRails.encryption.on_missing_key = :passthrough }

    it "keeps the value plaintext for a nil field key, as for a missing global key, even with a global key set" do
      klass = model_with(-> {})
      record = klass.create!(ssn: "plain")
      expect(raw_ssn(record.id)).to eq("plain")
      expect(klass.find(record.id).ssn).to eq("plain")
    end

    it "behaves the same when there is no global key either" do
      ConcernsOnRails.encryption.key = nil
      record = model_with(-> {}).create!(ssn: "plain")
      expect(raw_ssn(record.id)).to eq("plain")
    end

    it "does not index under the global key for a nil field key" do
      klass = model_with(-> {}, blind_index: true)
      record = klass.create!(ssn: "plain")
      # passthrough digests nothing: the input itself, exactly as for a missing global key
      expect(record.ssn_bidx).to eq("plain")
    end
  end
end
