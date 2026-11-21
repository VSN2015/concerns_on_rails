require "spec_helper"

RSpec.describe "Hashable: a refused re-declaration" do
  before do
    ActiveRecord::Schema.define do
      create_table :refused_orders, force: true do |t|
        t.string :token
      end
    end
  end
  after { ActiveRecord::Base.connection.drop_table(:refused_orders) }

  let(:klass) do
    Class.new(TestModel) do
      self.table_name = "refused_orders"
      include ConcernsOnRails::Models::Hashable

      hashable_by :token
    end
  end

  {
    "unknown type" => { type: :bogus },
    "non-positive length" => { length: 0 },
    "custom without an alphabet" => { type: :custom },
    "non-String prefix" => { prefix: 5 },
    "non-boolean to_param" => { to_param: "yes" }
  }.each do |label, options|
    it "keeps the previous declaration live after #{label} is refused" do
      expect { klass.hashable_by :token, **options }.to raise_error(ArgumentError)

      expect(klass.hashable_type).to eq(:hex)
      expect(klass.hashable_length).to eq(16)
      expect(klass.hashable_prefix).to be_nil
      expect(klass.hashable_to_param).to be(false)
      expect(klass.create!.token).to match(/\A[0-9a-f]{32}\z/)
    end
  end

  it "keeps the previous alphabet when a duplicate-laden one is refused as too short" do
    klass.hashable_by :token, type: :custom, length: 4, alphabet: "ab"
    expect do
      ConcernsOnRails.deprecator.silence { klass.hashable_by :token, type: :custom, length: 4, alphabet: "aaa" }
    end.to raise_error(ArgumentError)

    expect(klass.hashable_alphabet).to eq("ab")
  end

  it "refuses an unknown type at generation time rather than returning a nil value" do
    klass.hashable_type = :bogus
    expect { klass.generate_hashable_value }.to raise_error(ArgumentError, /unknown type/)
  end
end
