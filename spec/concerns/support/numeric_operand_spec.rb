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
    it "reads every operand as an exact decimal of scale 0 — never truncated" do
      expect(classify("12", integer)).to eq([:exact, 12])
      expect(classify(" -08 ", integer)).to eq([:exact, -8])
      expect(classify(12, integer)).to eq([:exact, 12])
      expect(classify(5.0, integer)).to eq([:exact, 5])
      expect(classify("5.0", integer)).to eq([:exact, 5])
      expect(classify("1e3", integer)).to eq([:exact, 1000])
      expect(described_class.classify("1e3", integer).value).to be_a(Integer)

      five_and_a_half = described_class.classify("5.5", integer)
      expect([five_and_a_half.status, five_and_a_half.value, five_and_a_half.floor]).to eq([:inexact, BigDecimal("5.5"), 5])
      expect(described_class.classify(-5.5, integer).floor).to eq(-6)

      %w[0x10 1_000 twelve 5e].each { |raw| expect(classify(raw, integer)).to eq([:uncastable, nil]), raw }
      expect(classify(true, integer)).to eq([:uncastable, nil])
    end

    it "range-checks the floor an inexact value binds on" do
      max = 2**31
      expect(described_class.classify("#{max - 1}.5", integer).status).to eq(:inexact)
      expect(described_class.classify("#{max}.5", integer).status).to eq(:above)
      expect(described_class.classify("-#{max}.5", integer).status).to eq(:below)
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
    end

    # ActiveModel::Type.lookup(:integer) carries a 4-byte range that says
    # nothing about a string column (or one missing from attribute_types):
    # only a real numeric COLUMN bounds the value.
    it "applies no range or precision when the column is not numeric" do
      expect(classify((2**40).to_s, integer, column_type: ActiveModel::Type::String.new)).to eq([:exact, 2**40])
      expect(classify((2**40).to_s, integer, column_type: nil)).to eq([:exact, 2**40])
      expect(classify("1e20", decimal, column_type: nil)).to eq([:exact, BigDecimal("1e20")])
      expect(classify("5.5", integer, column_type: nil).first).to eq(:inexact) # the declared scale still applies
    end

    # A JSON body can carry a Float infinity (1e400) where a query string
    # carries "1e400"; both must answer alike.
    it "reports a non-finite JSON Float as above / below, like its string spelling" do
      expect(classify(Float::INFINITY, integer).first).to eq(:above)
      expect(classify(-Float::INFINITY, decimal).first).to eq(:below)
      expect(classify("1e400", integer).first).to eq(:above)
      expect(classify(Float::NAN, integer)).to eq([:uncastable, nil])
    end
  end

  describe "decimal operands" do
    it "keeps the unrounded value and flags one finer than the scale as inexact" do
      expect(classify("99.99", decimal)).to eq([:exact, BigDecimal("99.99")])
      expect(classify("99.985", decimal)).to eq([:inexact, BigDecimal("99.985")])
      expect(described_class.classify("99.985", decimal).floor).to eq(BigDecimal("99.98"))
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

    # Nothing else bounds an unconstrained decimal, and binding
    # BigDecimal("1e99999999") expands it through to_s("F").
    it "refuses an operand too long or with too wide an exponent, before building it" do
      unbounded = ActiveModel::Type::Decimal.new

      expect(classify("1e1000", unbounded).first).to eq(:exact)
      expect(classify("1e-1000", unbounded).first).to eq(:exact)
      %w[1e1001 1e99999999 -1e999999999 1e-99999999].each do |raw|
        expect(classify(raw, unbounded)).to eq([:uncastable, nil]), raw
      end
      expect(classify("1#{'0' * 100}", unbounded)).to eq([:uncastable, nil])
      expect(classify("1#{'0' * 99}", unbounded).first).to eq(:exact)
      expect(classify(10**5000, unbounded).first).to eq(:above) # a JSON-body Integer
      expect(classify(-10**5000, ActiveModel::Type::Float.new).first).to eq(:below)
    end

    it "treats an Integer-backed decimal (scale 0) as whole numbers" do
      whole = ActiveRecord::Type::DecimalWithoutScale.new(precision: 10)

      expect(classify("5.5", whole)).to eq([:inexact, BigDecimal("5.5")])
      expect(described_class.classify("5.5", whole).floor).to eq(5)
      expect(classify("5", whole)).to eq([:exact, 5])
    end
  end

  describe "float operands" do
    let(:float) { ActiveModel::Type::Float.new }

    it "reads exponents exactly and reports an overflow to infinity as above / below" do
      expect(classify("1e3", float)).to eq([:exact, 1000.0])
      expect(classify("1e400", float)).to eq([:above, Float::INFINITY])
      expect(classify("-1e400", float)).to eq([:below, -Float::INFINITY])
      expect(classify("NaN", float)).to eq([:uncastable, nil])
      expect(classify("1e99999999", float)).to eq([:uncastable, nil])
    end

    # "1e-400".to_f underflows to 0.0; reporting that as :exact made
    # `?score=1e-400` match every 0.0 row and `?score_lt=1e-400` miss them.
    # A nonzero literal no Float can hold is :inexact, floored to the largest
    # Float below it (0.0, or the negative subnormal nearest zero).
    it "reports a nonzero literal that underflows to zero as inexact, never as an exact 0.0" do
      tiny = described_class.classify("1e-400", float)
      expect([tiny.status, tiny.floor]).to eq([:inexact, 0.0])

      negative = described_class.classify("-1e-400", float)
      expect([negative.status, negative.floor]).to eq([:inexact, 0.0.prev_float])
      expect(negative.floor).to be < 0

      decimal_input = described_class.classify(BigDecimal("1e-400"), float)
      expect(decimal_input.status).to eq(:inexact)
    end

    it "keeps a written zero exact, however it is spelled" do
      expect(classify("0e-400", float)).to eq([:exact, 0.0])
      expect(classify("-0.000", float)).to eq([:exact, -0.0])
      expect(classify(0, float)).to eq([:exact, 0.0])
      expect(classify("5e-324", float)).to eq([:exact, 5e-324])
    end

    it "binds through the column's kind, whatever numeric type the operand is read as" do
      expect(classify("5.5", decimal, column_type: integer)).to eq([:inexact, BigDecimal("5.5")])
      expect(classify("99.985", integer, column_type: decimal)).to eq([:inexact, BigDecimal("99.985")])
      expect(classify("1.5", integer, column_type: float)).to eq([:exact, 1.5])
    end
  end
end
