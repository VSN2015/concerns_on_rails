require "spec_helper"

# Rails runs a create's callbacks as before_validation -> before_save ->
# before_create. Tokenizable, Hashable and Sequenceable generate their value in
# before_create, so every sibling that derives something from it earlier in the
# chain used to miss it: Encryptable's blind index (before_save) stored NULL,
# friendly_id's slug (before_validation) stayed nil, and Auditable's creation
# entry (before_save) left the column out. Producers now notify
# Support::GeneratedValues, and each consumer re-derives — whatever the include
# and declaration order.
describe "values generated in before_create reach sibling concerns" do
  CTV_ENCRYPTION_KEY = "create-time-values-spec-key-create-time-values".freeze

  before do
    ConcernsOnRails.encryption.key = CTV_ENCRYPTION_KEY
    ConcernsOnRails.encryption.on_missing_key = :raise
    ConcernsOnRails.encryption.raise_on_decrypt_error = true

    ActiveRecord::Schema.define do
      create_table :ctv_accounts, force: true do |t|
        t.string :name
        t.string :title
        t.text :api_token
        t.string :api_token_bidx
        t.datetime :api_token_expires_at
        t.text :code
        t.string :code_bidx
        t.string :number
        t.integer :sequence
        t.string :slug
        t.text :audit_log
        t.timestamps
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

  def account_model(*concerns, &declaration)
    Class.new(TestModel) do
      self.table_name = "ctv_accounts"
      concerns.each { |concern| include concern }
      class_eval(&declaration)
    end
  end

  let(:tokenizable) { ConcernsOnRails::Models::Tokenizable }
  let(:hashable) { ConcernsOnRails::Models::Hashable }
  let(:sequenceable) { ConcernsOnRails::Models::Sequenceable }
  let(:encryptable) { ConcernsOnRails::Models::Encryptable }
  let(:sluggable) { ConcernsOnRails::Models::Sluggable }
  let(:auditable) { ConcernsOnRails::Models::Auditable }

  describe "Encryptable blind index (XC-01)" do
    [
      ["Tokenizable first, tokenizable_by first", :producer_first, :producer_macro_first],
      ["Encryptable first, encryptable first", :consumer_first, :consumer_macro_first],
      ["Tokenizable first, encryptable first", :producer_first, :consumer_macro_first],
      ["Encryptable first, tokenizable_by first", :consumer_first, :producer_macro_first]
    ].each do |label, include_order, macro_order|
      it "finds a freshly created record by its generated token (#{label})" do
        concerns = include_order == :producer_first ? [tokenizable, encryptable] : [encryptable, tokenizable]
        klass = account_model(*concerns) do
          if macro_order == :producer_macro_first
            tokenizable_by :api_token
            encryptable :api_token, blind_index: true
          else
            encryptable :api_token, blind_index: true
            tokenizable_by :api_token
          end
        end

        account = klass.create!(name: "acme")

        expect(account.api_token).to be_present
        expect(klass.find(account.id).api_token_bidx).to eq(klass.api_token_fingerprint(account.api_token))
        expect(klass.find_by_api_token(account.api_token)&.id).to eq(account.id)
        expect(klass.authenticate_by_api_token(account.api_token)&.id).to eq(account.id)
      end
    end

    it "fingerprints the generated token of an expiring field too" do
      klass = account_model(tokenizable, encryptable) do
        tokenizable_by :api_token, expires_in: 3600
        encryptable :api_token, blind_index: true
      end

      account = klass.create!(name: "acme")

      expect(account.api_token_expires_at).to be_present
      expect(klass.find_by_api_token(account.api_token)&.id).to eq(account.id)
    end

    it "keeps a caller-supplied token (fingerprinted in before_save, as before)" do
      klass = account_model(tokenizable, encryptable) do
        tokenizable_by :api_token
        encryptable :api_token, blind_index: true
      end

      account = klass.create!(name: "acme", api_token: "preset-token")

      expect(account.reload.api_token).to eq("preset-token")
      expect(klass.find_by_api_token("preset-token")&.id).to eq(account.id)
    end

    it "keeps the token findable after regenerate_<field>! (the update path)" do
      klass = account_model(tokenizable, encryptable) do
        tokenizable_by :api_token
        encryptable :api_token, blind_index: true
      end
      account = klass.create!(name: "acme")
      old = account.api_token

      account.regenerate_api_token!

      expect(klass.find_by_api_token(old)).to be_nil
      expect(klass.find_by_api_token(account.api_token)&.id).to eq(account.id)
    end

    [true, false].each do |hashable_first|
      it "finds a freshly created record by its generated Hashable code (#{hashable_first ? 'Hashable' : 'Encryptable'} first) (XC-01b)" do
        concerns = hashable_first ? [hashable, encryptable] : [encryptable, hashable]
        klass = account_model(*concerns) do
          if hashable_first
            hashable_by :code
            encryptable :code, blind_index: true
          else
            encryptable :code, blind_index: true
            hashable_by :code
          end
        end

        account = klass.create!(name: "acme")

        expect(account.code).to be_present
        expect(klass.find_by_code(account.code)&.id).to eq(account.id)
      end
    end
  end

  describe "Sluggable slug from a generated column (XC-02)" do
    [true, false].each do |producer_first|
      order = producer_first ? "Sequenceable first" : "Sluggable first"

      it "builds the slug from the Sequenceable number on create (#{order})" do
        concerns = producer_first ? [sequenceable, sluggable] : [sluggable, sequenceable]
        klass = account_model(*concerns) do
          if producer_first
            sequenceable_by :sequence, into: :number, prefix: "INV-"
            sluggable_by :number
          else
            sluggable_by :number
            sequenceable_by :sequence, into: :number, prefix: "INV-"
          end
        end

        invoice = klass.create!(name: "first")

        expect(invoice.number).to eq("INV-1")
        expect(invoice.slug).to eq("inv-1")
        expect(klass.find(invoice.id).slug).to eq("inv-1")
        expect(klass.friendly.find("inv-1").id).to eq(invoice.id)
      end

      it "builds the slug from the Hashable code on create (#{producer_first ? 'Hashable' : 'Sluggable'} first) (XC-02b)" do
        concerns = producer_first ? [hashable, sluggable] : [sluggable, hashable]
        klass = account_model(*concerns) do
          if producer_first
            hashable_by :code
            sluggable_by :code
          else
            sluggable_by :code
            hashable_by :code
          end
        end

        record = klass.create!(name: "first")

        expect(record.code).to be_present
        expect(klass.find(record.id).slug).to eq(record.code)
      end
    end

    it "rebuilds a candidates: slug that was built before the number existed" do
      klass = account_model(sluggable, sequenceable) do
        sluggable_by :name, candidates: [%i[name number]]
        sequenceable_by :sequence, into: :number, prefix: "INV-"
      end

      invoice = klass.create!(name: "acme")

      expect(klass.find(invoice.id).slug).to eq("acme-inv-1")
    end

    it "never overwrites an explicitly assigned slug" do
      klass = account_model(sluggable, sequenceable) do
        sluggable_by :number
        sequenceable_by :sequence, into: :number, prefix: "INV-"
      end

      invoice = klass.create!(name: "first", slug: "hand-picked")

      expect(invoice.number).to eq("INV-1")
      expect(klass.find(invoice.id).slug).to eq("hand-picked")
    end

    it "keeps friendly_id's conflict resolution for the late slug" do
      klass = account_model(sluggable, sequenceable) do
        sluggable_by :number
        sequenceable_by :sequence, into: :number, prefix: "INV-"
      end
      # Takes "inv-1" by hand (and number 7, so the next number is INV-8 ...).
      squatter = klass.create!(name: "squatter", sequence: 7, number: "custom", slug: "inv-8")

      invoice = klass.create!(name: "second")

      expect(invoice.number).to eq("INV-8")
      expect(invoice.slug).to start_with("inv-8-")
      expect(invoice.slug).not_to eq(squatter.slug)
    end

    # Built after validation, the slug never meets the reserved_words:
    # validator, so a reserved one is resolved like a taken one.
    it "never stores a reserved word as a late-built slug" do
      klass = account_model(sluggable, hashable) do
        sluggable_by :code, reserved_words: %w[new]
        hashable_by :code
      end
      allow(klass).to receive(:generate_hashable_value).and_return("new")

      record = klass.create!(name: "first")

      expect(record.code).to eq("new")
      expect(klass.find(record.id).slug).to start_with("new-")
    end

    it "does not touch the slug when the generated column is not its source" do
      klass = account_model(sluggable, tokenizable) do
        sluggable_by :name
        tokenizable_by :api_token
      end

      record = klass.create!(name: "Acme Corp")

      expect(klass.find(record.id).slug).to eq("acme-corp")
    end
  end

  describe "Auditable creation entry (XC-03)" do
    [true, false].each do |producer_first|
      it "records the generated sequence number (#{producer_first ? 'Sequenceable' : 'Auditable'} first)" do
        concerns = producer_first ? [sequenceable, auditable] : [auditable, sequenceable]
        klass = account_model(*concerns) do
          if producer_first
            sequenceable_by :sequence, into: :number, prefix: "N-"
            auditable_by :number, :name, into: :audit_log
          else
            auditable_by :number, :name, into: :audit_log
            sequenceable_by :sequence, into: :number, prefix: "N-"
          end
        end

        record = klass.create!(name: "a")

        trail = klass.find(record.id).audit_trail
        expect(trail.map { |entry| entry["field"] }).to contain_exactly("number", "name")
        expect(trail.find { |entry| entry["field"] == "number" }).to include("from" => nil, "to" => "N-1")
      end
    end

    it "records a generated token column" do
      klass = account_model(auditable, hashable) do
        auditable_by :code, into: :audit_log
        hashable_by :code
      end

      record = klass.create!(name: "a")

      expect(klass.find(record.id).last_change_for(:code)).to include("from" => nil, "to" => record.code)
    end

    it "records a slug built from a generated column" do
      klass = account_model(auditable, sluggable, sequenceable) do
        auditable_by :slug, into: :audit_log
        sluggable_by :number
        sequenceable_by :sequence, into: :number, prefix: "INV-"
      end

      record = klass.create!(name: "a")

      expect(klass.find(record.id).last_change_for(:slug)).to include("from" => nil, "to" => "inv-1")
    end

    it "still writes exactly one entry per field, and none when nothing tracked was generated" do
      klass = account_model(auditable, sequenceable) do
        auditable_by :name, into: :audit_log
        sequenceable_by :sequence, into: :number, prefix: "N-"
      end

      record = klass.create!(name: "a")

      expect(klass.find(record.id).audit_trail.map { |entry| entry["field"] }).to eq(["name"])
    end
  end

  describe "everything at once" do
    it "slugs, fingerprints and audits the generated values on one create" do
      klass = account_model(auditable, sluggable, encryptable, sequenceable, tokenizable) do
        auditable_by :number, :slug, into: :audit_log
        sluggable_by :number
        encryptable :api_token, blind_index: true
        sequenceable_by :sequence, into: :number, prefix: "INV-"
        tokenizable_by :api_token
      end

      record = klass.create!(name: "a")
      stored = klass.find(record.id)

      expect(stored.slug).to eq("inv-1")
      expect(klass.find_by_api_token(record.api_token)&.id).to eq(record.id)
      expect(stored.audit_trail.map { |entry| entry["field"] }).to contain_exactly("number", "slug")
    end
  end
end

# friendly_id builds the slug in before_validation, registered when Sluggable
# is included; Sanitizable/Normalizable register theirs at their own include.
# Included after Sluggable, they used to transform the title AFTER the slug was
# built from the raw value ("b-hello-b-em-world-em").
describe "Sluggable after a sibling's write-time transform (XC-06)" do
  before do
    ActiveRecord::Schema.define do
      create_table :ctv_posts, force: true do |t|
        t.string :title
        t.string :slug
        t.text :audit_log
        t.timestamps
      end
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  def post_model(*concerns, &declaration)
    Class.new(TestModel) do
      self.table_name = "ctv_posts"
      concerns.each { |concern| include concern }
      class_eval(&declaration)
    end
  end

  let(:sluggable) { ConcernsOnRails::Models::Sluggable }
  let(:sanitizable) { ConcernsOnRails::Models::Sanitizable }
  let(:normalizable) { ConcernsOnRails::Models::Normalizable }

  [true, false].each do |sluggable_first|
    order = sluggable_first ? "Sluggable first" : "Sanitizable first"

    it "slugs the sanitized title (#{order})" do
      concerns = sluggable_first ? [sluggable, sanitizable] : [sanitizable, sluggable]
      klass = post_model(*concerns) do
        sluggable_by :title
        sanitizable :title, with: :strip, on: :write
      end

      post = klass.create!(title: "<b>Hello</b> <em>World</em>")

      expect(post.title).to eq("Hello World")
      expect(post.slug).to eq("hello-world")
      expect(klass.find(post.id).slug).to eq("hello-world")
    end

    it "slugs the normalized title (#{sluggable_first ? 'Sluggable' : 'Normalizable'} first) (XC-06b)" do
      concerns = sluggable_first ? [sluggable, normalizable] : [normalizable, sluggable]
      klass = post_model(*concerns) do
        sluggable_by :title
        normalizable :title, with: ->(value) { value.sub(/\AThe /, "") }
      end

      book = klass.create!(title: "The Hobbit")

      expect(book.title).to eq("Hobbit")
      expect(book.slug).to eq("hobbit")
    end

    it "re-slugs from the sanitized title on update (#{order})" do
      concerns = sluggable_first ? [sluggable, sanitizable] : [sanitizable, sluggable]
      klass = post_model(*concerns) do
        sluggable_by :title
        sanitizable :title, with: :strip, on: :write
      end
      post = klass.create!(title: "First")

      post.update!(title: "<i>Second</i> post")

      expect(post.reload.slug).to eq("second-post")
    end
  end

  it "never overwrites an explicitly assigned slug" do
    klass = post_model(sluggable, sanitizable) do
      sluggable_by :title
      sanitizable :title, with: :strip, on: :write
    end

    post = klass.create!(title: "<b>Hello</b>", slug: "custom")

    expect(post.reload.slug).to eq("custom")
  end

  it "leaves a slug the transform does not change alone" do
    klass = post_model(sluggable, normalizable) do
      sluggable_by :title
      normalizable :title, with: :squish
    end

    post = klass.create!(title: "Hello   World")

    expect(post.slug).to eq("hello-world")
  end

  it "keeps friendly_id's conflict resolution for the rebuilt slug" do
    klass = post_model(sluggable, sanitizable) do
      sluggable_by :title
      sanitizable :title, with: :strip, on: :write
    end
    klass.create!(title: "Hello")

    post = klass.create!(title: "<b>Hello</b>")

    expect(post.slug).to start_with("hello-")
    expect(post.slug).not_to eq("hello")
  end

  it "validates the rebuilt slug against reserved_words: (it is built before validation ends)" do
    klass = post_model(sluggable, sanitizable) do
      sluggable_by :title, reserved_words: %w[new]
      sanitizable :title, with: :strip, on: :write
    end

    expect { klass.create!(title: "<b>new</b>") }.to raise_error(ActiveRecord::RecordInvalid, /reserved/i)
  end

  it "hands the final slug to an Auditable included before Sluggable" do
    klass = post_model(ConcernsOnRails::Models::Auditable, sluggable, sanitizable) do
      auditable_by :slug, into: :audit_log
      sluggable_by :title
      sanitizable :title, with: :strip, on: :write
    end

    post = klass.create!(title: "<b>Hello</b>")

    expect(post.reload.last_change_for(:slug)).to include("to" => "hello")
  end
end
