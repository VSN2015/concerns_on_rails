require "spec_helper"
require "action_controller"

RSpec.describe ConcernsOnRails::Support::ScalarParam do
  describe ".scalar?" do
    it "accepts Strings and Numerics" do
      expect(described_class.scalar?("5")).to be(true)
      expect(described_class.scalar?(5)).to be(true)
      expect(described_class.scalar?(5.5)).to be(true)
    end

    it "rejects nil, Arrays, Hashes and Parameters" do
      expect(described_class.scalar?(nil)).to be(false)
      expect(described_class.scalar?(["5"])).to be(false)
      expect(described_class.scalar?({ "x" => "5" })).to be(false)
      expect(described_class.scalar?(ActionController::Parameters.new("x" => "5"))).to be(false)
    end
  end

  describe ".to_i" do
    it "coerces scalars and falls back for everything else" do
      expect(described_class.to_i("7", default: 0)).to eq(7)
      expect(described_class.to_i(7, default: 0)).to eq(7)
      expect(described_class.to_i("abc", default: 0)).to eq(0)
      expect(described_class.to_i(nil, default: 3)).to eq(3)
      expect(described_class.to_i(["7"], default: 3)).to eq(3)
      expect(described_class.to_i(ActionController::Parameters.new("x" => "1"), default: 3)).to eq(3)
    end

    # A JSON body's 1e400 is Float::INFINITY; `.to_i` on it (or on NaN, or a
    # non-finite BigDecimal) raises FloatDomainError.
    it "falls back for non-finite numbers instead of raising" do
      [Float::INFINITY, -Float::INFINITY, Float::NAN, BigDecimal("Infinity"), BigDecimal("NaN")].each do |junk|
        expect(described_class.to_i(junk, default: 3)).to eq(3)
      end
      expect(described_class.to_i(5.9, default: 3)).to eq(5)
    end
  end

  # The ONE per_page resolver both paginators route through — CursorPaginatable
  # used to carry its own copy without the absolute ceiling, so its
  # `max_per_page: 0` ("no cap") let `?per_page=99999999999999999999` reach
  # LIMIT and 500, a bug Paginatable had already fixed in its own copy.
  describe ".per_page" do
    let(:ceiling) { described_class::MAX_PER_PAGE }

    it "reads a positive request, falling back to the default for anything else" do
      expect(described_class.per_page("7", default: 25, cap: 200)).to eq(7)
      expect(described_class.per_page(7, default: 25, cap: 200)).to eq(7)
      expect(described_class.per_page("0", default: 25, cap: 200)).to eq(25)
      expect(described_class.per_page("-3", default: 25, cap: 200)).to eq(25)
      expect(described_class.per_page("abc", default: 25, cap: 200)).to eq(25)
      expect(described_class.per_page(nil, default: 25, cap: 200)).to eq(25)
      expect(described_class.per_page(["7"], default: 25, cap: 200)).to eq(25)
    end

    it "applies a positive cap, and ignores a non-positive one" do
      expect(described_class.per_page("999", default: 25, cap: 200)).to eq(200)
      expect(described_class.per_page("999", default: 25, cap: 0)).to eq(999)
      expect(described_class.per_page("999", default: 25, cap: -1)).to eq(999)
    end

    it "clamps to the absolute ceiling whatever the cap says" do
      huge = "99999999999999999999"

      expect(described_class.per_page(huge, default: 25, cap: 0)).to eq(ceiling)
      expect(described_class.per_page(huge, default: 25, cap: 10**30)).to eq(ceiling)
      expect(described_class.per_page(nil, default: 10**30, cap: 0)).to eq(ceiling)
    end

    it "is the ceiling Paginatable has always used" do
      expect(ceiling).to eq(ConcernsOnRails::Controllers::Paginatable::MAX_PER_PAGE)
      expect(ceiling).to eq(ConcernsOnRails::Controllers::CursorPaginatable::MAX_PER_PAGE)
    end
  end

  describe ".where_safe?" do
    it "accepts scalars, nil and arrays of scalars (IN queries)" do
      expect(described_class.where_safe?("a")).to be(true)
      expect(described_class.where_safe?(nil)).to be(true)
      expect(described_class.where_safe?(%w[a b])).to be(true)
    end

    it "rejects Hash-likes, and arrays containing them (the ?status[][x]=1 shape)" do
      expect(described_class.where_safe?({ "gt" => 1 })).to be(false)
      expect(described_class.where_safe?(ActionController::Parameters.new("x" => 1))).to be(false)
      expect(described_class.where_safe?([ActionController::Parameters.new("x" => 1)])).to be(false)
      expect(described_class.where_safe?([["a"], { "x" => 1 }])).to be(false)
    end
  end
end
