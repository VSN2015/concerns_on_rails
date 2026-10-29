require "spec_helper"

# PARAMS-1: Filterable knew nothing about Encryptable. An encrypted column holds
# random-IV ciphertext, so the operand `where` serialized never equalled a stored
# value: `?ssn=` / `?ssn_in=` matched nothing, `?ssn_not=` / `?ssn_not_in=`
# matched EVERY row (the excluded one too), and LIKE / comparisons ran over
# ciphertext. Equality and `in` now go through the blind index when there is
# one; every other operator, and every operator on a field without an index,
# fails closed.
describe ConcernsOnRails::Controllers::Filterable do
  before do
    ConcernsOnRails.encryption.key = "filterable-encryptable-key-filterable"
    ActiveRecord::Schema.define(verbose: false) do
      create_table :filter_secrets, force: true do |t|
        t.string :name
        t.text :ssn
        t.text :email
        t.text :email_bidx
        t.text :note
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

  let(:model) do
    Class.new(TestModel) do
      self.table_name = "filter_secrets"
      include ConcernsOnRails::Models::Encryptable

      encryptable :ssn
      encryptable :email, blind_index: true
      encryptable :note
    end
  end

  let(:controller_class) do
    Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Filterable

      filter_by :ssn, :email, :note, operators: true
    end
  end

  before do
    model.create!(name: "ann", ssn: "123", email: "ann@example.com", note: nil)
    model.create!(name: "bob", ssn: "999", email: "bob@example.com", note: "hello")
    model.create!(name: "cat", ssn: "555", email: nil, note: "world")
  end

  def names(params)
    controller_class.new(params: params).filtered(model.all.order(:id)).pluck(:name)
  end

  describe "a blind-indexed field" do
    it "matches equality through the index" do
      expect(names(email: "ann@example.com")).to eq(%w[ann])
      expect(names(email: "nobody@example.com")).to eq([])
    end

    it "matches in (comma list, array and bracket form) through the index" do
      expect(names(email_in: "ann@example.com, bob@example.com")).to eq(%w[ann bob])
      expect(names(email_in: ["bob@example.com", "zed@example.com"])).to eq(%w[bob])
      expect(names(email: { in: "ann@example.com" })).to eq(%w[ann])
      expect(names(email: %w[ann@example.com bob@example.com])).to eq(%w[ann bob])
    end

    it "fails every other operator closed, not / not_in included" do
      expect(names(email_not: "ann@example.com")).to eq([])
      expect(names(email_not_in: "ann@example.com")).to eq([])
      expect(names(email: { not: "ann@example.com" })).to eq([])
      expect(names(email_gt: "a")).to eq([])
      expect(names(email_lte: "z")).to eq([])
      expect(names(email_contains: "example")).to eq([])
      expect(names(email_starts_with: "ann")).to eq([])
    end

    it "keeps `null` working (IS NULL is true of the stored NULL)" do
      expect(names(email_null: "true")).to eq(%w[cat])
      expect(names(email_null: "false")).to eq(%w[ann bob])
    end
  end

  describe "a field without a blind index" do
    it "fails every operator closed" do
      expect(names(ssn: "123")).to eq([])
      expect(names(ssn_in: "123,999")).to eq([])
      expect(names(ssn_not: "123")).to eq([])
      expect(names(ssn_not_in: "123")).to eq([])
      expect(names(ssn_gt: "1")).to eq([])
      expect(names(ssn_contains: "12")).to eq([])
      expect(names(ssn_starts_with: "1")).to eq([])
    end

    it "keeps `null` working" do
      expect(names(note_null: "true")).to eq(%w[ann])
      expect(names(note_null: "false")).to eq(%w[bob cat])
    end
  end

  it "leaves a plain column on the same model untouched" do
    plain = Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Filterable

      filter_by :name, operators: true
    end
    expect(plain.new(params: { name_not: "ann" }).filtered(model.all.order(:id)).pluck(:name)).to eq(%w[bob cat])
    expect(plain.new(params: { name: "bob" }).filtered(model.all).pluck(:name)).to eq(%w[bob])
  end
end
