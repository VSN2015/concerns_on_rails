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
