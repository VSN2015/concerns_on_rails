require "spec_helper"

# Audit 2026-10-29 TRANS-S4: `gsub(/\A[[:space:]\0]+|[[:space:]\0]+\z/, "")`
# (Normalizable :strip, Searchable's query, Taggable's tags, Money's reader)
# and TimeValue's TRAILING_COMMENTS started a `+\z` attempt at every position
# of an interior whitespace run. Ruby 3.2's match cache keeps that linear, but
# at about a microsecond per character (a 1 MB `"a" + " " * N + "b"` query
# cost ~1 s of CPU, `"a b" * N` 3 MB over 2 s). Support::EdgeSpace strips each
# edge with one anchored match; names_year? answers false before the comment
# regex for a String Date._parse would refuse anyway.
#
# The timing examples compare against a private copy of the OLD regex in the
# same process (the new strip must beat it by 10x on 1 MB), so a revert fails
# on any machine; the absolute bounds are single loose smoke checks (2 s).
describe "Edge-whitespace stripping on large input" do
  # Process.clock_gettime, not Benchmark.realtime: benchmark is a bundled (not
  # default) gem from Ruby 4.0, and nothing in the bundle depends on it.
  def elapsed_seconds
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  let(:old_edge_space) { /\A[[:space:]\0]+|[[:space:]\0]+\z/ }
  let(:old_money_space) { /\A[[:space:]]+|[[:space:]]+\z/ }

  let(:tricky) do
    [
      "", " ", "\0", "\0 \0", "a", " a ", "\0a\0", " a ", "　a　", "  a b  ",
      "a b", "  a  b  ", "\t\n\v\f\r a \r\n", "\u0085a ", "​a​", "᠎a᠎", "é  ",
      "a\0 b\0 ", "\0  　", " \0 x \0 ", "😀  "
    ]
  end

  describe ConcernsOnRails::Support::EdgeSpace do
    it "returns exactly what the one-regex gsub returned, NUL and Unicode spaces included" do
      tricky.each do |input|
        expect(described_class.strip(input)).to eq(input.gsub(old_edge_space, ""))
        expect(described_class.strip(input).encoding).to eq(input.encoding)
      end
    end

    it "leaves NUL alone with nul: false (Money's reader)" do
      tricky.each do |input|
        expect(described_class.strip(input, nul: false)).to eq(input.gsub(old_money_space, ""))
      end
    end

    it "returns a new String and keeps a non-UTF-8 encoding" do
      input = "  abc  ".encode("ISO-8859-1")
      out = described_class.strip(input)
      expect(out).to eq("abc".encode("ISO-8859-1"))
      expect(out.encoding).to eq(Encoding::ISO_8859_1)
      expect(out).not_to equal(input)
    end

    it "still raises ArgumentError on an invalid byte sequence, as gsub did" do
      expect { described_class.strip(" a\xff ") }.to raise_error(ArgumentError)
    end

    {
      "interior run" => [->(n) { "a#{" " * n}b" }, ->(n) { "a#{" " * n}b" }],
      "interior words" => [->(n) { "a b" * n }, ->(n) { "a b" * n }],
      "NUL run" => [->(n) { "\0" * n }, ->(_) { "" }],
      "leading run" => [->(n) { "#{" " * n}a" }, ->(_) { "a" }],
      "trailing run" => [->(n) { "a#{" " * n}" }, ->(_) { "a" }]
    }.each do |label, (build, expected)|
      it "strips 100k units of #{label} to the expected result" do
        expect(described_class.strip(build.call(100_000))).to eq(expected.call(100_000))
      end
    end

    it "strips 2 MB of interior spaces within a loose absolute bound" do
      input = "a#{" " * 2_000_000}b"
      elapsed = elapsed_seconds { expect(described_class.strip(input)).to eq(input) }
      expect(elapsed).to be < 2.0
    end

    def best_of_two(&block)
      Array.new(2) { elapsed_seconds(&block) }.min
    end

    {
      "an interior run" => "a#{" " * 1_000_000}b",
      "interior words" => "a b" * 333_333
    }.each do |label, input|
      it "is at least 10x faster than the one-regex gsub on #{label} (1M characters)" do
        old_regex = /\A[[:space:]\0]+|[[:space:]\0]+\z/
        new_time = best_of_two { described_class.strip(input) }
        old_time = best_of_two { input.gsub(old_regex, "") }
        expect(new_time).to be < old_time / 10
      end
    end
  end

  describe "through the concerns" do
    it "Normalizable.strip keeps its result" do
      expect(ConcernsOnRails::Models::Normalizable.strip("\u00A0a#{" " * 2_000}b\0")).to eq("a#{" " * 2_000}b")
    end

    it "Money's writer still reads a padded amount and rejects an oversized one" do
      money = ConcernsOnRails::Support::Money
      expect(money.parse("\u00A0$12.50\u3000", {})).to eq(BigDecimal("12.5"))
      expect(money.parse("1#{" " * 100_000}2", {})).to be_nil
    end
  end

  describe "ConcernsOnRails::Support::TimeValue.names_year?" do
    let(:time_value) { ConcernsOnRails::Support::TimeValue }

    it "answers false quickly for a String past Date._parse's limit" do
      long = "a#{"(x) " * 500_000}z"
      expect(elapsed_seconds { expect(time_value.names_year?(long)).to be(false) }).to be < 2.0
      expect(elapsed_seconds { expect(time_value.names_year?("2026-10-01#{" " * 2_000_000}x")).to be(false) }).to be < 2.0
    end

    it "still reads a trailing comment and a 128-byte boundary as before" do
      expect(time_value.names_year?("Thu, 01 Oct 2026 10:00:00 -0330 (Newfoundland Time)")).to be(true)
      expect(time_value.names_year?("2026-10-01T10:00:00[America/New_York]")).to be(true)
      padded = "2026-10-01#{" " * (128 - 10)}"
      expect(padded.bytesize).to eq(128)
      expect(time_value.names_year?(padded)).to be(true)
      expect(time_value.names_year?("#{padded} ")).to be(false)
      expect(time_value.names_year?("2026-10-01#{"é" * 60}")).to be(false)
    end
  end
end
