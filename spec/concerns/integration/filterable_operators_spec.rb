require "spec_helper"
require "support/integration_harness"

# The bracket form (`?price[gte]=10`) arrives as ActionController::Parameters in
# a real app and as a HashWithIndifferentAccess under the FakeController — a
# difference the fake harness structurally cannot reproduce, and exactly the gap
# that let the 1.22 Parameters regressions stay green. These run the operators
# through the real ActionController stack.
RSpec.describe "Filterable operators through real ActionController dispatch" do
  before do
    ActiveRecord::Schema.define do
      create_table :widgets, force: true do |t|
        t.string :name
        t.string :status
        t.integer :stock
        t.datetime :discontinued_at
      end
    end

    class Widget < TestModel
      self.table_name = "widgets"
    end

    Widget.create!(name: "Lamp", status: "active", stock: 5)
    Widget.create!(name: "Desk", status: "active", stock: 0, discontinued_at: Time.zone.now)
    Widget.create!(name: "Chair", status: "archived", stock: 12)
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end

    Object.send(:remove_const, :Widget) if Object.const_defined?(:Widget)
  end

  let(:controller) do
    IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Filterable

      filter_by :stock, :status, :name, :discontinued_at, operators: true

      def index
        render json: filtered(Widget.order(:id)).pluck(:name)
      end
    end
  end

  def names(query)
    result = IntegrationHarness.dispatch(controller, :index, query: query)
    expect(result.status).to eq(200)
    JSON.parse(result.body)
  end

  it "reads the bracket form off ActionController::Parameters" do
    expect(names("stock[gte]=5")).to eq(%w[Lamp Chair])
    expect(names("stock[gte]=1&stock[lte]=5")).to eq(%w[Lamp])
    expect(names("status[in]=archived,active")).to eq(%w[Lamp Desk Chair])
    expect(names("discontinued_at[null]=true")).to eq(%w[Lamp Chair])
    expect(names("name[starts_with]=La")).to eq(%w[Lamp])
  end

  it "does not narrow the relation for a blank bracket value" do
    expect(names("stock[gte]=")).to eq(%w[Lamp Desk Chair])
    expect(names("stock[gte]=&stock[lte]=")).to eq(%w[Lamp Desk Chair])
  end

  it "matches nothing for a comparison value the column type cannot represent" do
    expect(names("stock[gt]=twelve")).to eq([])
    expect(names("stock_gt=twelve")).to eq([])
  end

  # Integer#cast is `to_i`: `1e3` ran `stock > 1`, `5.5` ran `stock = 5`.
  it "reads exponent / fractional integer operands exactly in every form" do
    expect(names("stock[gt]=1e3")).to eq([])
    expect(names("stock_lt=1e3")).to eq(%w[Lamp Desk Chair])
    expect(names("stock[gte]=5.5")).to eq(%w[Chair])
    expect(names("stock_lte=5.5")).to eq(%w[Lamp Desk])
    expect(names("stock=5.5")).to eq([])
    expect(names("stock=5.0")).to eq(%w[Lamp])
    expect(names("stock[in]=5.5,12")).to eq(%w[Chair])
    expect(names("stock_not_in[]=1e1")).to eq(%w[Lamp Desk Chair])
  end

  it "answers an out-of-range integer per operator in both forms" do
    huge = "99999999999999999999"

    expect(names("stock[lt]=#{huge}")).to eq(%w[Lamp Desk Chair])
    expect(names("stock_gte=#{huge}")).to eq([])
    expect(names("stock[in][]=#{huge}&stock[in][]=12")).to eq(%w[Chair])
  end

  # PostgreSQL has no `integer ~~* unknown` operator: `?stock_contains=1` was a 500.
  it "fails closed for contains / starts_with on a non-string column" do
    expect(names("stock[contains]=1")).to eq([])
    expect(names("stock_starts_with=12")).to eq([]) # SQLite used to run `stock LIKE 12`
    expect(names("discontinued_at[contains]=20")).to eq([])
  end

  it "ignores a nested or array-shaped operand instead of 500ing" do
    expect(names("stock[gt][x]=1")).to eq(%w[Lamp Desk Chair])
    expect(names("stock_gt[]=1&stock_gt[]=2")).to eq(%w[Lamp Desk Chair])
    expect(names("status_in[x]=1")).to eq(%w[Lamp Desk Chair])
  end
end
