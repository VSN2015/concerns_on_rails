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

  describe ".capture and .retire!" do
    before do
      ActiveRecord::Schema.define do
        create_table :affix_posts, force: true do |t|
          t.datetime :published_at
        end
      end

      stub_const("AffixPost", Class.new(TestModel) do
        self.table_name = "affix_posts"
        scope :published, -> { where.not(published_at: nil) }
      end)
    end

    after(:each) do
      ActiveRecord::Base.connection.tables.each do |table|
        next if table == "schema_migrations"

        ActiveRecord::Base.connection.drop_table(table)
      end
    end

    it "captures the named scopes as UnboundMethods" do
      captured = described_class.capture(AffixPost, %i[published])
      expect(captured.keys).to eq([:published])
      expect(captured[:published]).to be_a(UnboundMethod)
    end

    it "ignores names that are not defined" do
      captured = described_class.capture(AffixPost, %i[published nope])
      expect(captured.keys).to eq([:published])
    end

    it "removes a captured scope that is untouched" do
      captured = described_class.capture(AffixPost, %i[published])
      removed = described_class.retire!(AffixPost, captured, label: "Test")

      expect(removed).to eq([:published])
      expect(AffixPost.respond_to?(:published)).to be false
    end

    it "leaves a scope the model redefined itself" do
      captured = described_class.capture(AffixPost, %i[published])
      AffixPost.singleton_class.send(:define_method, :published) { :mine }

      removed = described_class.retire!(AffixPost, captured, label: "Test")

      expect(removed).to be_empty
      expect(AffixPost.published).to eq(:mine)
    end

    it "raises when the scope is owned by a parent class" do
      captured = described_class.capture(AffixPost, %i[published])
      subclass = stub_const("AffixSpecialPost", Class.new(AffixPost))

      expect do
        described_class.retire!(subclass, captured, label: "ConcernsOnRails::Models::Publishable")
      end.to raise_error(ArgumentError, /AffixPost/)
    end
  end
end
