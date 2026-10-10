require "spec_helper"

# Audit 2026-10-10 PARAM-7 (Rails 7.0+). An enum label the enum does not know
# serializes to nil, and EnumType has a subtype, so ActiveRecord's
# QueryAttribute reports nil? and the predicate builder emits `status IS
# NULL`: `?status=drfat` (a typo) returned exactly the rows with NO status, and
# `?status_in=drfat,draft` the draft rows PLUS the NULL ones. Filterable
# already answers "a value the column cannot hold equals nothing" for numbers
# and dates; an unknown enum member now drops out of the list the same way.
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
      create_table :label_tickets, force: true do |t|
        t.string :title
        t.integer :status
      end
    end
    model = Class.new(TestModel) { self.table_name = "label_tickets" }
    define_enum(model, :status, { draft: 0, review: 1, published: 2 })
    stub_const("LabelTicket", model)
    LabelTicket.create!(title: "alpha", status: :draft)
    LabelTicket.create!(title: "beta", status: :review)
    LabelTicket.create!(title: "orphan", status: nil)
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

      filter_by :status, operators: %i[not in not_in]
    end
  end

  def titles(params)
    controller_class.new(params: params).filtered(LabelTicket.all).pluck(:title).sort
  end

  it "matches nothing for an unknown label in equality and in, never the NULL rows" do
    expect(titles(status: "drfat")).to eq([])
    expect(titles(status: %w[drfat])).to eq([])
    expect(titles(status_in: "drfat")).to eq([])
  end

  it "drops an unknown label from an in list and keeps the known ones" do
    expect(titles(status_in: "drfat,draft")).to eq(%w[alpha])
    expect(titles(status: %w[drfat review])).to eq(%w[beta])
  end

  it "answers not / not_in on an unknown label as every row with a status" do
    expect(titles(status_not: "drfat")).to eq(%w[alpha beta])
    expect(titles(status_not_in: "drfat,draft")).to eq(%w[beta])
  end

  it "keeps known labels, stored values and an explicit nil member (IS NULL) working" do
    expect(titles(status: "review")).to eq(%w[beta])
    expect(titles(status: "1")).to eq(%w[beta])
    expect(titles(status: [nil, "draft"])).to eq(%w[alpha orphan])
    expect(titles(status: [nil, "drfat"])).to eq(%w[orphan])
  end
end
