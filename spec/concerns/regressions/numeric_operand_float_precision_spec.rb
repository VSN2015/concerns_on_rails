require "spec_helper"

# PARAMS-8: a float-column operand was rounded to the nearest double and bound
# as :exact, so `?score_gt=0.1000000000000000000001` ran `score > 0.1` and
# dropped a stored 0.1 that IS greater than the operand, and `?score=<that>`
# matched the 0.1 row although no double equals it. A literal the double does not
# keep is now :inexact (floored to the largest double at or below it), like an
# integer column's 5.5.
describe ConcernsOnRails::Support::NumericOperand do
  let(:float) { ActiveModel::Type::Float.new }

  def classify(raw, type = float)
    operand = described_class.classify(raw, type)
    [operand.status, operand.value, operand.floor]
  end

  describe ".classify on a float type" do
    it "keeps every literal the double reads back as exact" do
      expect(classify("0.1")).to eq([:exact, 0.1, nil])
      expect(classify("0.30000000000000004")).to eq([:exact, 0.30000000000000004, nil])
      expect(classify("1e3")).to eq([:exact, 1000.0, nil])
      expect(classify("-2.5")).to eq([:exact, -2.5, nil])
      expect(classify("5e-324")).to eq([:exact, 5e-324, nil])
      expect(classify("1.7976931348623157e308")).to eq([:exact, Float::MAX, nil])
      expect(classify(7)).to eq([:exact, 7.0, nil])
      expect(classify(0.1)).to eq([:exact, 0.1, nil])
      expect(classify(BigDecimal("0.25"))).to eq([:exact, 0.25, nil])
    end

    it "reads a literal ABOVE its nearest double as inexact, floored to that double" do
      status, value, floor = classify("0.10000000000000001")
      expect([status, floor]).to eq([:inexact, 0.1])
      expect(value).to eq(BigDecimal("0.10000000000000001"))
    end

    it "reads a literal BELOW its nearest double as inexact, floored to the double before it" do
      status, _value, floor = classify("0.1000000000000000000001")
      expect([status, floor]).to eq([:inexact, 0.1.prev_float])
      # the double -0.1 lies below the real number -0.1000000000000000000001, so it IS the floor
      expect(classify("-0.1000000000000000000001")[2]).to eq(-0.1)
      expect(classify("0.09999999999999999999")[2]).to eq(0.1.prev_float)
    end

    it "judges an Integer beyond the 2**53 range the same way" do
      expect(classify(2**53)[0]).to eq(:exact)
      expect(classify((2**53) + 1)).to eq([:inexact, BigDecimal((2**53) + 1), (2**53).to_f])
      expect(classify((2**53) + 3)[2]).to eq(((2**53) + 2).to_f)
    end

    it "keeps the underflow answer" do
      expect(classify("1e-400")[0]).to eq(:inexact)
      expect(classify("0.000")).to eq([:exact, 0.0, nil])
    end
  end

  describe "through Filterable on a float column" do
    before do
      ActiveRecord::Schema.define(verbose: false) do
        create_table :float_rows, force: true do |t|
          t.string :name
          t.float :score
        end
      end
      stub_const("FloatRow", Class.new(TestModel) { self.table_name = "float_rows" })
      FloatRow.create!(name: "half", score: 0.5)
      FloatRow.create!(name: "high", score: 0.75)
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

        filter_by :score, operators: true
      end
    end

    def names(params)
      controller_class.new(params: params).filtered(FloatRow.all.order(:id)).pluck(:name)
    end

    it "compares an operand just above 0.5 exactly" do
      above = "0.5000000000000000000001"
      expect(names(score_gt: above)).to eq(%w[high])
      expect(names(score_gte: above)).to eq(%w[high])
      expect(names(score_lt: above)).to eq(%w[half])
      expect(names(score_lte: above)).to eq(%w[half])
      expect(names(score: above)).to eq([])
      expect(names(score_in: above)).to eq([])
      expect(names(score_not_in: above)).to eq(%w[half high])
    end

    it "compares an operand just below 0.5 exactly (the stored 0.5 is greater)" do
      below = "0.4999999999999999999999"
      expect(names(score_gt: below)).to eq(%w[half high])
      expect(names(score_gte: below)).to eq(%w[half high])
      expect(names(score_lt: below)).to eq([])
      expect(names(score_lte: below)).to eq([])
      expect(names(score: below)).to eq([])
    end

    it "still matches a literal the double keeps" do
      expect(names(score: "0.5")).to eq(%w[half])
      expect(names(score_gte: "0.5")).to eq(%w[half high])
      expect(names(score_gt: "0.5")).to eq(%w[high])
      expect(names(score_in: "0.5,0.75")).to eq(%w[half high])
    end
  end
end
