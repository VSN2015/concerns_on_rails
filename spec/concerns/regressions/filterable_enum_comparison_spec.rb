require "spec_helper"

# Audit 2026-10-10 PARAM-4 and PARAM-12 (one root cause: Filterable had no enum
# branch for gt/gte/lt/lte).
#   PARAM-4: EnumType reports `type == :integer`, so a LABEL operand
#     (`?status_gte=review`) was judged non-numeric garbage and failed closed —
#     every comparison on an enum column came back empty, on every Rails line.
#   PARAM-12: on Rails 6.0 / 6.1 a numeric operand (`?status_gte=1`) reached
#     EnumType#cast, which raises ArgumentError ("'1' is not a valid status")
#     for anything that is neither a label nor a mapped Integer — a 500.
# An enum operand is now its label (or the value a label stores), compared
# through the enum's own serialization; anything else matches nothing.
describe ConcernsOnRails::Controllers::Filterable do
  def define_enum(klass, name, mapping)
    # The positional form is Rails 7+; the keyword form is gone in 8.0.
    if ActiveRecord::VERSION::MAJOR >= 7
      klass.enum name, mapping
    else
      klass.enum name => mapping
    end
  end

  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :enum_tickets, force: true do |t|
        t.string :title
        t.integer :status
        t.string :state
      end
    end
    model = Class.new(TestModel) { self.table_name = "enum_tickets" }
    define_enum(model, :status, { draft: 0, review: 1, published: 2 })
    define_enum(model, :state, { open: "o", closed: "c" })
    stub_const("EnumTicket", model)
    EnumTicket.create!(title: "alpha", status: :draft, state: :open)
    EnumTicket.create!(title: "beta", status: :review, state: :closed)
    EnumTicket.create!(title: "gamma", status: :published, state: :open)
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

      filter_by :status, :state, operators: %i[gt gte lt lte]
    end
  end

  def titles(params)
    controller_class.new(params: params).filtered(EnumTicket.all).pluck(:title).sort
  end

  it "compares an enum column against a label through the value it stores" do
    expect(titles(status_gte: "review")).to eq(%w[beta gamma])
    expect(titles(status_lt: "published")).to eq(%w[alpha beta])
    expect(titles(status: { gt: "draft", lte: "review" })).to eq(%w[beta])
  end

  it "reads a String-backed enum's label as the String it stores" do
    # open stores "o", closed stores "c": `state < 'o'` is the closed row.
    expect(titles(state_lt: "open")).to eq(%w[beta])
    expect(titles(state_gte: "closed")).to eq(%w[alpha beta gamma])
  end

  it "accepts a stored value in its String or JSON form, on every Rails line (no ArgumentError)" do
    expect(titles(status_gte: "1")).to eq(%w[beta gamma])
    expect(titles(status_lt: 2)).to eq(%w[alpha beta])
  end

  it "matches nothing for an unknown label or a value the enum does not map, and never raises" do
    expect(titles(status_gte: "drfat")).to eq([])
    expect(titles(status_gt: "7")).to eq([])
    expect(titles(status_lt: "1.5")).to eq([])
    expect(titles(state_lt: "zzz")).to eq([])
  end
end
