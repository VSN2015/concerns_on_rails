require "spec_helper"

describe ConcernsOnRails::Support::Affix do
  describe ".name" do
    it "returns the bare base as a Symbol when neither affix is given" do
      expect(described_class.name(:active)).to eq(:active)
    end

    it "prepends the prefix" do
      expect(described_class.name(:active, prefix: "subscription")).to eq(:subscription_active)
    end

    it "appends the suffix" do
      expect(described_class.name(:active, suffix: "window")).to eq(:active_window)
    end

    it "applies both" do
      expect(described_class.name(:active, prefix: "sub", suffix: "window")).to eq(:sub_active_window)
    end

    it "accepts a String base" do
      expect(described_class.name("active", prefix: "sub")).to eq(:sub_active)
    end
  end

  describe ".normalize" do
    it "returns nil for nil" do
      expect(described_class.normalize(nil, default: :status)).to be_nil
    end

    it "returns nil for false" do
      expect(described_class.normalize(false, default: :status)).to be_nil
    end

    it "returns the default as a String for true" do
      expect(described_class.normalize(true, default: :status)).to eq("status")
    end

    it "returns a Symbol option as a String" do
      expect(described_class.normalize(:archived, default: :status)).to eq("archived")
    end

    it "returns a String option unchanged" do
      expect(described_class.normalize("archived", default: :status)).to eq("archived")
    end
  end
end
