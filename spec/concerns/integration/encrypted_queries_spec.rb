require "spec_helper"

# An `encryptable` column holds an AES-GCM envelope under a random IV, so any
# SQL comparison against the value — LIKE, equality — runs on ciphertext and
# silently matches nothing. Searchable's `search`, Taggable's `tagged_with`
# and Tokenizable's `authenticate_by_`/`consume_` used to do exactly that
# (XC-09). The LIKE queries are now refused at declaration, in either order
# (like the Auditable/Sluggable/Storable guards); Tokenizable's equality goes
# through the blind index, and raises when there is none.
describe "query concerns over an encryptable column" do
  EQ_ENCRYPTION_KEY = "encrypted-queries-spec-key-encrypted-queries".freeze

  before do
    ConcernsOnRails.encryption.key = EQ_ENCRYPTION_KEY
    ConcernsOnRails.encryption.on_missing_key = :raise
    ConcernsOnRails.encryption.raise_on_decrypt_error = true

    ActiveRecord::Schema.define do
      create_table :eq_notes, force: true do |t|
        t.string :title
        t.text :body
        t.text :tags
        t.string :labels
        t.text :api_token
        t.string :api_token_bidx
        t.datetime :api_token_expires_at
        t.text :code
        t.string :code_bidx
      end
    end
  end

  after(:each) do
    ConcernsOnRails.encryption.key = nil
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  def note_model(*concerns, &declaration)
    Class.new(TestModel) do
      self.table_name = "eq_notes"
      concerns.each { |concern| include concern }
      class_eval(&declaration) if declaration
    end
  end

  let(:encryptable) { ConcernsOnRails::Models::Encryptable }
  let(:searchable) { ConcernsOnRails::Models::Searchable }
  let(:taggable) { ConcernsOnRails::Models::Taggable }
  let(:tokenizable) { ConcernsOnRails::Models::Tokenizable }
  let(:hashable) { ConcernsOnRails::Models::Hashable }

  describe "Searchable (XC-09)" do
    it "refuses searchable_by over a column already declared encryptable" do
      expect do
        note_model(encryptable, searchable) do
          encryptable :body
          searchable_by :title, :body
        end
      end.to raise_error(ArgumentError, /Searchable.*:body.*Encryptable|:body.*Encryptable.*Searchable/)
    end

    it "refuses encryptable over a column already searchable (the reverse order)" do
      expect do
        note_model(searchable, encryptable) do
          searchable_by :title, :body
          encryptable :body
        end
      end.to raise_error(ArgumentError, /Searchable/)
    end

    it "leaves the class searching nothing it was refused for" do
      klass = note_model(encryptable, searchable) { encryptable :body }

      expect { klass.searchable_by :title, :body }.to raise_error(ArgumentError)
      expect(klass.searchable_fields).to eq([])
    end

    it "still searches the plaintext columns of a model that encrypts another one" do
      klass = note_model(encryptable, searchable) do
        encryptable :body
        searchable_by :title
      end
      note = klass.create!(title: "quarterly plan", body: "secret")

      expect(klass.search("quarterly").to_a).to eq([note])
    end

    it "refuses an STI subclass encrypting a column its parent searches" do
      parent = note_model(searchable, encryptable) { searchable_by :title, :body }

      expect { Class.new(parent) { encryptable :body } }.to raise_error(ArgumentError, /Searchable/)
    end
  end

  describe "Taggable (XC-09b)" do
    it "refuses taggable_by over a column already declared encryptable" do
      expect do
        note_model(encryptable, taggable) do
          encryptable :tags
          taggable_by :tags
        end
      end.to raise_error(ArgumentError, /Taggable.*:tags.*Encryptable|:tags.*Encryptable.*Taggable/)
    end

    it "refuses encryptable over the tag column (the reverse order)" do
      expect do
        note_model(taggable, encryptable) do
          taggable_by :tags
          encryptable :tags
        end
      end.to raise_error(ArgumentError, /Taggable/)
    end

    it "tags a plaintext column of a model that encrypts another one" do
      klass = note_model(encryptable, taggable) do
        encryptable :tags
        taggable_by :labels
      end
      note = klass.create!(title: "t", labels: "ruby,rails", tags: "secret")

      expect(klass.tagged_with("ruby").to_a).to eq([note])
    end

    # Taggable works on its :tags default without taggable_by, and a
    # taggable_by :labels may still follow `encryptable :tags` — so that shape
    # is refused when tagged_with actually queries the encrypted column.
    it "refuses tagged_with at call time for an undeclared Taggable over an encrypted :tags" do
      klass = note_model(taggable, encryptable) { encryptable :tags }
      klass.create!(title: "t", tags: "ruby")

      expect { klass.tagged_with("ruby") }.to raise_error(ArgumentError, /Taggable.*encrypted/)
    end
  end

  describe "Tokenizable (XC-09c)" do
    context "when the token is encrypted without a blind index" do
      [true, false].each do |encryptable_first|
        order = encryptable_first ? "encryptable first" : "tokenizable_by first"

        it "generates and encrypts the token, but refuses the lookups when CALLED (#{order})" do
          klass = note_model(encryptable, tokenizable) do
            if encryptable_first
              encryptable :api_token
              tokenizable_by :api_token
            else
              tokenizable_by :api_token
              encryptable :api_token
            end
          end

          note = klass.create!(title: "t").reload

          expect(note.api_token).to match(/\A[A-Za-z0-9_-]{32}\z/)
          expect(note.api_token_encrypted?).to be(true)
          expect { klass.authenticate_by_api_token(note.api_token) }
            .to raise_error(ArgumentError, /api_token.*encrypted.*blind index/)
          expect { klass.consume_api_token(note.api_token) }.to raise_error(ArgumentError, /blind index/)
          expect { klass.authenticate_by_api_token(nil) }.to raise_error(ArgumentError, /blind index/)
        end
      end

      it "keeps regenerate_ / revoke_ working" do
        klass = note_model(encryptable, tokenizable) do
          encryptable :api_token
          tokenizable_by :api_token
        end
        note = klass.create!(title: "t")
        old = note.api_token

        note.regenerate_api_token!
        expect(note.reload.api_token).to be_present
        expect(note.api_token).not_to eq(old)

        note.revoke_api_token!
        expect(note.reload.api_token).to be_nil
      end
    end

    context "when the token has a blind index" do
      [true, false].each do |encryptable_first|
        it "authenticates through the blind index (#{encryptable_first ? 'encryptable' : 'tokenizable_by'} first)" do
          klass = note_model(tokenizable, encryptable) do
            if encryptable_first
              encryptable :api_token, blind_index: true
              tokenizable_by :api_token
            else
              tokenizable_by :api_token
              encryptable :api_token, blind_index: true
            end
          end
          note = klass.create!(title: "t")
          other = klass.create!(title: "u")

          expect(klass.authenticate_by_api_token(note.api_token)).to eq(note)
          expect(klass.authenticate_by_api_token(other.api_token)).to eq(other)
          expect(klass.authenticate_by_api_token("#{note.api_token}x")).to be_nil
          expect(klass.authenticate_by_api_token("")).to be_nil
          expect(klass.authenticate_by_api_token(nil)).to be_nil
        end
      end

      it "refuses an expired token" do
        klass = note_model(tokenizable, encryptable) do
          tokenizable_by :api_token, expires_in: 3600
          encryptable :api_token, blind_index: true
        end
        note = klass.create!(title: "t")

        travel_to(2.hours.from_now) do
          expect(klass.authenticate_by_api_token(note.api_token)).to be_nil
        end
      end

      it "consumes once, clearing the token AND its blind index" do
        klass = note_model(tokenizable, encryptable) do
          tokenizable_by :api_token, expires_in: 3600
          encryptable :api_token, blind_index: true
        end
        note = klass.create!(title: "t")
        token = note.api_token

        consumed = klass.consume_api_token(token)

        expect(consumed).to eq(note)
        expect(consumed.api_token).to be_nil
        expect(consumed.api_token_bidx).to be_nil
        expect(consumed.api_token_expires_at).to be_nil
        expect(klass.find_by_api_token(token)).to be_nil
        expect(klass.consume_api_token(token)).to be_nil
      end

      it "prechecks a generated token's uniqueness through the blind index" do
        klass = note_model(tokenizable, encryptable) do
          tokenizable_by :api_token
          encryptable :api_token, blind_index: true
        end
        taken = klass.create!(title: "t", api_token: "taken-token")
        allow(klass).to receive(:generate_tokenizable_value).and_return("taken-token", "fresh-token")

        note = klass.create!(title: "u")

        expect(note.api_token).to eq("fresh-token")
        expect(klass.find_by_api_token("taken-token")).to eq(taken)
      end
    end
  end

  describe "Hashable unique: precheck on an encrypted code" do
    it "checks collisions through the blind index" do
      klass = note_model(hashable, encryptable) do
        hashable_by :code, unique: true
        encryptable :code, blind_index: true
      end
      klass.create!(title: "t", code: "taken")
      allow(klass).to receive(:generate_hashable_value).and_return("taken", "fresh")

      note = klass.create!(title: "u")

      expect(note.code).to eq("fresh")
      expect(klass.find_by_code("fresh")).to eq(note)
    end
  end
end
