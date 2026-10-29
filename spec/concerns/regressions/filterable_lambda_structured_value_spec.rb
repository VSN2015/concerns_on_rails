require "spec_helper"

# PARAMS-S4: a `with:` lambda declared with a `type:` pre-casts its value. A
# numeric type already failed a structured value (Array / Parameters) closed,
# but `type: :boolean` read `?flag[]=0` as true and `type: :string` handed the
# lambda '["a"]'. A non-scalar value now fails closed for every `type:`.
describe ConcernsOnRails::Controllers::Filterable do
  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :lambda_rows, force: true do |t|
        t.string :name
        t.boolean :flag
      end
    end
    stub_const("LambdaRow", Class.new(TestModel) { self.table_name = "lambda_rows" })
    LambdaRow.create!(name: "a", flag: true)
    LambdaRow.create!(name: "b", flag: false)
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  let(:received) { [] }

  let(:controller_class) do
    seen = received
    Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Filterable

      filter_by :flag, type: :boolean, with: ->(rel, v) { rel.where(flag: seen.push(v).last) }
      filter_by :q, type: :string, with: ->(rel, v) { rel.where(name: seen.push(v).last) }
      filter_by :n, type: :integer, with: ->(rel, v) { rel.where(id: seen.push(v).last) }
      filter_by :raw, with: ->(rel, v) { seen.push(v) && rel }
    end
  end

  def names(params)
    controller_class.new(params: params).filtered(LambdaRow.all.order(:id)).pluck(:name)
  end

  it "fails an Array or Hash value closed for type: :boolean, :string and :integer, without calling the lambda" do
    [{ flag: %w[0] }, { flag: { x: "1" } }, { q: %w[a] }, { q: { x: "a" } }, { n: %w[1] }, { n: { x: "1" } }].each do |params|
      expect(names(params)).to eq([]), "expected #{params.inspect} to match nothing"
    end
    expect(received).to eq([])
  end

  it "fails a structured ActionController::Parameters value closed too" do
    expect(names(flag: ActionController::Parameters.new("x" => "1"))).to eq([])
    expect(received).to eq([])
  end

  it "still casts scalars, real booleans included, and leaves an untyped lambda alone" do
    expect(names(flag: "1")).to eq(%w[a])
    expect(names(flag: "0")).to eq(%w[b])
    expect(names(flag: false)).to eq(%w[b])
    expect(names(q: "b")).to eq(%w[b])
    expect(names(raw: %w[x y])).to eq(%w[a b])
    expect(received).to eq([true, false, false, "b", %w[x y]])
  end
end
