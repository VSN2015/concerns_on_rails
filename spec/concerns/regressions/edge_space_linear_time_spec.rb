require "spec_helper"
require "benchmark"

# Audit 2026-10-29 TRANS-S4: `gsub(/\A[[:space:]\0]+|[[:space:]\0]+\z/, "")`
# (Normalizable :strip, Searchable's query, Taggable's tags, Money's reader)
# and TimeValue's TRAILING_COMMENTS started a `+\z` attempt at every position
# of an interior whitespace run. Ruby 3.2's match cache keeps that linear, but
# at about a microsecond per character (a 1 MB `"a" + " " * N + "b"` query
# cost ~1 s of CPU, `"a b" * N` 3 MB over 2 s). Support::EdgeSpace strips each
# edge with one anchored match; names_year? answers false before the comment
# regex for a String Date._parse would refuse anyway.
#
# The timing bounds are deliberately loose (seconds, against a pre-fix cost
# that is several times the bound on a fast machine: the inputs are 3-15 MB): they catch a return to a
# per-position scan, not a slow CI box.
describe "Edge-whitespace stripping on large input" do
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
      "interior run" => [->(n) { "a#{" " * n}b" }, 5_000_000, ->(n) { "a#{" " * n}b" }],
      "interior words" => [->(n) { "a b" * n }, 1_700_000, ->(n) { "a b" * n }],
      "NUL run" => [->(n) { "\0" * n }, 1_000_000, ->(_) { "" }],
      "leading run" => [->(n) { "#{" " * n}a" }, 1_000_000, ->(_) { "a" }],
      "trailing run" => [->(n) { "a#{" " * n}" }, 1_000_000, ->(_) { "a" }]
    }.each do |label, (build, size, expected)|
      it "strips a #{size}-unit #{label} in linear time" do
        input = build.call(size)
        result = nil
        elapsed = Benchmark.realtime { result = described_class.strip(input) }
        expect(result).to eq(expected.call(size))
        expect(elapsed).to be < 2.0
      end
    end
  end

  describe "through the concerns" do
    it "Normalizable.strip keeps its result and stays fast" do
      input = "\u00A0a#{" " * 5_000_000}b\0"
      out = nil
      elapsed = Benchmark.realtime { out = ConcernsOnRails::Models::Normalizable.strip(input) }
      expect(out).to eq("a#{" " * 5_000_000}b")
      expect(elapsed).to be < 2.0
    end

    it "Money's writer rejects an oversized padded amount quickly" do
      elapsed = Benchmark.realtime do
        expect(ConcernsOnRails::Support::Money.parse("1#{" " * 5_000_000}2", {})).to be_nil
      end
      expect(elapsed).to be < 2.0
    end
  end

  describe "ConcernsOnRails::Support::TimeValue.names_year?" do
    let(:time_value) { ConcernsOnRails::Support::TimeValue }

    it "answers false quickly for a String past Date._parse's limit" do
      long = "a#{"(x) " * 1_000_000}z"
      expect(Benchmark.realtime { expect(time_value.names_year?(long)).to be(false) }).to be < 2.0
      expect(Benchmark.realtime { expect(time_value.names_year?("2026-10-01#{" " * 3_000_000}x")).to be(false) }).to be < 2.0
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
