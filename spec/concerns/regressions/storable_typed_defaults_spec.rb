require "spec_helper"

# Audit 2026-10-10 DATA-7: only a :datetime key's `default:` went through the
# key's cast, so every other typed key handed its default back raw — the String
# "false" on a :boolean key is truthy, a :date key read a String, a :decimal
# key an Integer — while the same value STORED under the key read back cast.
describe "Storable: a typed default reads back as the same value stored under the key would" do
  before do
    ActiveRecord::Schema.define do
      create_table :storable_default_accounts, force: true do |t|
        t.text :settings
      end
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.drop_table(:storable_default_accounts, if_exists: true)
  end

  def model_class(&declaration)
    klass = Class.new(TestModel) do
      self.table_name = "storable_default_accounts"
      include ConcernsOnRails::Models::Storable
    end
    klass.class_eval(&declaration)
    klass
  end

  it "casts a :date key's String default to a Date" do
    klass = model_class { storable_by :settings, starts_on: { type: :date, default: "2024-01-01" } }

    expect(klass.new.starts_on).to eq(Date.new(2024, 1, 1))
  end

  it "casts a :decimal key's Integer default to a BigDecimal" do
    klass = model_class { storable_by :settings, price: { type: :decimal, default: 0 } }

    expect(klass.new.price).to be_a(BigDecimal)
    expect(klass.new.price).to eq(BigDecimal("0"))
  end

  it "casts a :boolean key's String default to a boolean (the String \"false\" is truthy)" do
    klass = model_class { storable_by :settings, flag: { type: :boolean, default: "false" } }
    record = klass.new

    expect(record.flag).to be(false)
    expect(record.flag?).to be(false)
  end

  it "casts an :integer key's String default (an ENV value) to an Integer" do
    klass = model_class { storable_by :settings, seats: { type: :integer, default: "25" } }

    expect(klass.new.seats).to eq(25)
  end

  it "casts a Proc default's result too" do
    klass = model_class { storable_by :settings, seats: { type: :integer, default: -> { "7" } } }

    expect(klass.new.seats).to eq(7)
  end

  it "reads the default and the same value stored under the key identically, so the key is not dirty" do
    klass = model_class { storable_by :settings, flag: { type: :boolean, default: "false" } }
    record = klass.new

    expect(record.flag_was).to be(false)
    expect(record.flag_changed?).to be(false)
    record.flag = false
    expect(record.flag_changed?).to be(false)
  end

  it "keeps a :json default uncast and deep-duped, and a nil default nil" do
    klass = model_class do
      storable_by :settings, widgets: { type: :json, default: { "a" => [1] } }, note: { type: :string }
    end
    record = klass.new
    record.widgets["a"] << 2

    expect(klass.new.widgets).to eq("a" => [1])
    expect(record.note).to be_nil
  end

  it "keeps a String default a fresh copy per read" do
    klass = model_class { storable_by :settings, theme: { type: :string, default: +"light" } }
    klass.new.theme << "-custom"

    expect(klass.new.theme).to eq("light")
  end
end
