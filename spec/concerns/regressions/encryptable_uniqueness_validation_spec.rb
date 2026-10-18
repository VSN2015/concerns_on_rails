require "spec_helper"

# Audit 2026-10-10 DATA-3: `validates :email, uniqueness: true` on an
# encrypted field always passed. UniquenessValidator builds
# `where(email: value)`, which serializes the value into a fresh random-IV
# envelope that matches no row, so the second sign-up with the same email was
# saved. The same no-match hit `uniqueness: { scope: :ssn }` over an
# encrypted scope column. Both are now refused, in either declaration order,
# as Searchable/Taggable LIKE over ciphertext already is.
describe "Encryptable: a uniqueness validation over an encrypted field" do
  before do
    ConcernsOnRails.encryption.key = "concerns-on-rails-uniqueness-key"
    ConcernsOnRails.encryption.on_missing_key = :raise
    ConcernsOnRails.encryption.raise_on_decrypt_error = true

    ActiveRecord::Schema.define do
      create_table :enc_unique_users, force: true do |t|
        t.text :email
        t.string :email_bidx
        t.text :ssn
        t.string :handle
      end
    end
  end

  after(:each) do
    ConcernsOnRails.encryption.key = nil
    ActiveRecord::Base.connection.drop_table(:enc_unique_users, if_exists: true)
  end

  def model(&declaration)
    klass = Class.new(TestModel) do
      self.table_name = "enc_unique_users"
      include ConcernsOnRails::Models::Encryptable
    end
    klass.class_eval(&declaration)
    klass
  end

  it "is refused when declared after `encryptable`, pointing a blind-indexed field at where_<field>" do
    expect do
      model do
        encryptable :email, blind_index: true
        validates :email, uniqueness: true
      end
    end.to raise_error(ArgumentError, /':email' is encrypted.*uniqueness.*where_email/m)
  end

  it "is refused when declared before `encryptable`" do
    expect do
      model do
        validates :email, uniqueness: true
        encryptable :email, blind_index: true
      end
    end.to raise_error(ArgumentError, /':email' is encrypted.*uniqueness/m)
  end

  it "is refused through validates_uniqueness_of too" do
    expect do
      model do
        encryptable :email, blind_index: true
        validates_uniqueness_of :email
      end
    end.to raise_error(ArgumentError, /':email' is encrypted/)
  end

  it "points a field without a blind index at `blind_index: true`" do
    expect do
      model do
        encryptable :ssn
        validates :ssn, uniqueness: true
      end
    end.to raise_error(ArgumentError, /blind_index: true/)
  end

  it "is refused when an encrypted field is a uniqueness `scope:`, in either order" do
    expect do
      model do
        encryptable :ssn
        validates :handle, uniqueness: { scope: :ssn }
      end
    end.to raise_error(ArgumentError, /':ssn' is encrypted.*scope/m)

    expect do
      model do
        validates :handle, uniqueness: { scope: [:ssn] }
        encryptable :ssn
      end
    end.to raise_error(ArgumentError, /':ssn' is encrypted.*scope/m)
  end

  it "is refused in a subclass of an encrypting model" do
    parent = model { encryptable :email, blind_index: true }

    expect { Class.new(parent) { validates :email, uniqueness: true } }.to raise_error(ArgumentError, /':email'/)
  end

  it "is refused through an explicit validates_with call on the class" do
    klass = model { encryptable :email, blind_index: true }

    expect { klass.validates_with(ActiveRecord::Validations::UniquenessValidator, attributes: [:email]) }
      .to raise_error(ArgumentError, /':email' is encrypted/)
  end

  it "keeps a uniqueness validation on a plain column of the same model working" do
    klass = model do
      encryptable :email, blind_index: true
      validates :handle, uniqueness: true
      validates :email, presence: true
    end
    klass.create!(email: "a@b.com", handle: "alice")

    expect(klass.new(email: "c@d.com", handle: "alice").valid?).to be(false)
    expect(klass.new(email: "c@d.com", handle: "bob").valid?).to be(true)
  end
end
