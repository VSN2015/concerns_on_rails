require "spec_helper"

# PARAMS-2 (Rails 6.0): Arel::Table#[] does not follow alias_attribute there, so
# ?sort=<alias> ordered by a column that does not exist (500).
describe "controller Sortable alias_attribute keys (PARAMS-2)" do
  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :params_sort_rows, force: true do |t|
        t.string :name
        t.integer :stock
      end
    end
  end
  after { ActiveRecord::Base.connection.drop_table(:params_sort_rows) }

  let(:model) do
    Class.new(TestModel) do
      self.table_name = "params_sort_rows"
      alias_attribute :qty, :stock
    end
  end

  it "orders an alias_attribute key by its column" do
    3.times { |i| model.create!(name: "r#{i}", stock: 3 - i) }
    klass = Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Sortable

      sortable_by :qty
    end

    expect(klass.new(params: { sort: "qty" }).sorted(model.all).map(&:name)).to eq(%w[r2 r1 r0])
    expect(klass.new(params: { sort: "-qty" }).sorted(model.all).map(&:name)).to eq(%w[r0 r1 r2])
  end
end
