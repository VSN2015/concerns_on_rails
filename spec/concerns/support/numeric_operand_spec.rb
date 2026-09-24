require "spec_helper"

RSpec.describe ConcernsOnRails::Support::NumericOperand do
  def classify(raw, type, **)
    result = described_class.classify(raw, type, **)
    result && [result.status, result.value]
  end

  let(:integer) { ActiveModel::Type::Integer.new } # 4-byte range, like an unsized integer column
  let(:decimal) { ActiveModel::Type::Decimal.new(precision: 10, scale: 2) }

  describe ".kind" do
    it "names plain numeric types by their own type, and nothing else" do
      expect(described_class.kind(integer)).to eq(:integer)
      expect(described_class.kind(ActiveModel::Type::BigInteger.new)).to eq(:integer)
      expect(described_class.kind(decimal)).to eq(:decimal)
      expect(described_class.kind(ActiveModel::Type::Float.new)).to eq(:float)
      # decimal(10,0) — MySQL's default decimal — is an Integer subclass
      # reporting :decimal, and must be read as one.
      expect(described_class.kind(ActiveRecord::Type::DecimalWithoutScale.new(precision: 10))).to eq(:decimal)

      expect(described_class.kind(ActiveModel::Type::String.new)).to be_nil
      expect(described_class.kind(ActiveModel::Type::DateTime.new)).to be_nil
      expect(described_class.kind(nil)).to be_nil
      expect(classify("5", ActiveModel::Type::String.new)).to be_nil
    end
  end

  describe "integer operands" do
    it "accepts whole numbers only — never an exponent, a fraction, or another base" do
      expect(classify("12", integer)).to eq([:exact, 12])
      expect(classify(" -08 ", integer)).to eq([:exact, -8])
      expect(classify(12, integer)).to eq([:exact, 12])
      expect(classify(5.0, integer)).to eq([:exact, 5])

      %w[1e3 5.5 0x10 1_000 twelve].each { |raw| expect(classify(raw, integer)).to eq([:uncastable, nil]), raw }
      expect(classify(5.5, integer)).to eq([:uncastable, nil])
      expect(classify(true, integer)).to eq([:uncastable, nil])
    end

    it "reports a value beyond the column's range as above / below" do
      expect(classify((2**40).to_s, integer)).to eq([:above, 2**40])
      expect(classify((-2**40).to_s, integer)).to eq([:below, -2**40])
      expect(classify((2**40).to_s, ActiveModel::Type::Integer.new(limit: 8))).to eq([:exact, 2**40])
      expect(classify("9" * 30, ActiveModel::Type::BigInteger.new)).to eq([:exact, ("9" * 30).to_i])
    end

    it "takes the range from the column type when the read type is the same kind" do
      wide = ActiveModel::Type::Integer.new(limit: 8)

      expect(classify((2**40).to_s, integer, column_type: wide)).to eq([:exact, 2**40])
      expect(classify((2**40).to_s, integer, column_type: ActiveModel::Type::String.new)).to eq([:above, 2**40])
    end
  end

  describe "decimal operands" do
    it "keeps the unrounded value and flags one finer than the scale as inexact" do
      expect(classify("99.99", decimal)).to eq([:exact, BigDecimal("99.99")])
      expect(classify("99.985", decimal)).to eq([:inexact, BigDecimal("99.985")])
      expect(described_class.classify("99.985", decimal).scale).to eq(2)
      expect(classify("1e2", decimal)).to eq([:exact, BigDecimal("100")])
      expect(classify(".5", decimal)).to eq([:exact, BigDecimal("0.5")])
      expect(classify("abc", decimal)).to eq([:uncastable, nil])
    end

    it "reports a value beyond the column's precision as above / below" do
      expect(classify("1e8", decimal)).to eq([:above, BigDecimal("1e8")])
      expect(classify("-1e8", decimal)).to eq([:below, BigDecimal("-1e8")])
      expect(classify("99999999.99", decimal).first).to eq(:exact)
      expect(classify("1e400", ActiveModel::Type::Decimal.new).first).to eq(:exact) # unconstrained numeric
    end

    it "treats an Integer-backed decimal (scale 0) as whole numbers" do
      whole = ActiveRecord::Type::DecimalWithoutScale.new(precision: 10)

      expect(classify("5.5", whole)).to eq([:inexact, BigDecimal("5.5")])
      expect(described_class.classify("5.5", whole).scale).to eq(0)
      expect(classify("5", whole)).to eq([:exact, BigDecimal("5")])
    end
  end

  describe "float operands" do
    let(:float) { ActiveModel::Type::Float.new }

    it "reads exponents exactly and reports an overflow to infinity as above / below" do
      expect(classify("1e3", float)).to eq([:exact, 1000.0])
      expect(classify("1e400", float)).to eq([:above, Float::INFINITY])
      expect(classify("-1e400", float)).to eq([:below, -Float::INFINITY])
      expect(classify("NaN", float)).to eq([:uncastable, nil])
    end
  end
end
