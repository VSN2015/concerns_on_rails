require "spec_helper"
require "support/integration_harness"

# Audit 2026-10-10 PARAM-1. Comparison and LIKE operands are inlined as quoted
# SQL literals (Arel Casted / Quoted nodes), not bound, and a NUL byte ends the
# statement text at the C boundary (SQLite, PostgreSQL): `?title_gte=a%00b`
# was an unauthenticated StatementInvalid 500. Rack decodes %00 and Rails'
# encoding check only refuses INVALID UTF-8, so the byte reaches the concern.
# The equality path binds — but the pg driver refuses NUL in a bound text
# parameter too. No text column can hold a NUL, so every such operand fails
# the filter closed.
describe ConcernsOnRails::Controllers::Filterable do
  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :nul_items, force: true do |t|
        t.string :title
        t.binary :digest
      end
    end
    stub_const("NulItem", Class.new(TestModel) { self.table_name = "nul_items" })
    NulItem.create!(title: "alpha", digest: "a\0b".b)
    NulItem.create!(title: "beta", digest: "zz".b)
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

      filter_by :title, :digest, operators: true
    end
  end

  def titles(params)
    controller_class.new(params: params).filtered(NulItem.all).pluck(:title)
  end

  it "fails a gt/gte/lt/lte operand carrying a NUL byte closed instead of raising" do
    expect(titles(title_gte: "a\0b")).to eq([])
    expect(titles(title_lt: "\0")).to eq([])
    expect(titles(title: { gt: "a\0" })).to eq([])
  end

  it "fails a contains / starts_with operand carrying a NUL byte closed instead of raising" do
    expect(titles(title_contains: "a\0b")).to eq([])
    expect(titles(title_starts_with: "\0")).to eq([])
  end

  it "fails equality, not, in and not_in closed on a NUL member" do
    expect(titles(title: "alpha\0")).to eq([])
    expect(titles(title: ["alpha", "b\0"])).to eq([])
    expect(titles(title_not: "alpha\0")).to eq([])
    expect(titles(title_in: "alpha,b\0c")).to eq([])
    expect(titles(title_not_in: "x\0y")).to eq([])
  end

  it "keeps NUL-free operands working" do
    expect(titles(title_gte: "b")).to eq(["beta"])
    expect(titles(title_contains: "lph")).to eq(["alpha"])
    expect(titles(title_in: "alpha,beta")).to contain_exactly("alpha", "beta")
  end

  it "leaves a binary column alone: a NUL byte is an ordinary byte there" do
    expect(titles(digest: "a\0b".b)).to eq(["alpha"])
  end

  it "answers ?title_gte=a%00b with a 200 through real ActionController dispatch" do
    controller = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Filterable

      filter_by :title, operators: true

      def index
        render json: filtered(NulItem.all).pluck(:title)
      end
    end

    %w[title_gte=a%00b title_contains=%00 title=a%00b title_in=alpha,a%00b].each do |query|
      result = IntegrationHarness.dispatch(controller, :index, query: query)
      expect(result.status).to eq(200)
      expect(JSON.parse(result.body)).to eq([])
    end
  end
end
