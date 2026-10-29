require "spec_helper"

# PARAMS-6: `?<field>_null=` ran the value through ActiveModel's Boolean cast,
# which reads every non-blank string outside Rails' FALSE_VALUES as TRUE — so
# `?deleted_at_null=maybe` (or a typo such as `ture` / `nope`) ran IS NULL. Only
# an explicit true/false spelling is read; anything else fails closed (`none`),
# as every other unreadable operand in this concern does.
describe ConcernsOnRails::Controllers::Filterable do
  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :null_flag_items, force: true do |t|
        t.string :name
        t.datetime :deleted_at
      end
    end
    stub_const("NullFlagItem", Class.new(TestModel) { self.table_name = "null_flag_items" })
    NullFlagItem.create!(name: "live")
    NullFlagItem.create!(name: "gone", deleted_at: Time.utc(2026, 1, 1))
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  let(:controller_class) do
    Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Filterable

      filter_by :deleted_at, operators: true
    end
  end

  def names(params)
    controller_class.new(params: params).filtered(NullFlagItem.all.order(:id)).pluck(:name)
  end

  it "reads the explicit true spellings as IS NULL, case-insensitively" do
    ["true", "TRUE", "True", "1", "t", "T", "yes", "YES", " true ", true].each do |value|
      expect(names(deleted_at_null: value)).to eq(["live"]), "expected #{value.inspect} to read as true"
    end
  end

  it "reads the explicit false spellings as IS NOT NULL" do
    ["false", "FALSE", "0", "f", "F", "no", "No", false].each do |value|
      expect(names(deleted_at_null: value)).to eq(["gone"]), "expected #{value.inspect} to read as false"
    end
  end

  it "fails closed for anything else, in the suffix and the bracket form" do
    %w[maybe ture nope on off 2 nil null].each do |value|
      expect(names(deleted_at_null: value)).to eq([]), "expected #{value.inspect} to match nothing"
      expect(names(deleted_at: { null: value })).to eq([]), "expected [null]=#{value.inspect} to match nothing"
    end
  end

  it "still skips a blank value" do
    expect(names(deleted_at_null: "")).to eq(%w[live gone])
    expect(names(deleted_at: { null: " " })).to eq(%w[live gone])
  end
end
