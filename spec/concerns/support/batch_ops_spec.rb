require "spec_helper"

describe ConcernsOnRails::Support::BatchOps do
  before do
    ActiveRecord::Schema.define do
      create_table :batch_items, force: true do |t|
        t.string :state
      end

      create_table :stamped_items, force: true do |t|
        t.string :state
        t.timestamps
      end
    end

    stub_const("BatchItem", Class.new(TestModel) do
      self.table_name = "batch_items"
    end)
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  describe ".unoverridden?" do
    it "is true when no listed method is overridden" do
      owner = Module.new { def touched; end }
      klass = Class.new { include(owner) }

      expect(described_class.unoverridden?(klass, owner, :touched)).to be true
    end

    it "is false when the host overrode a listed method" do
      owner = Module.new { def touched; end }
      klass = Class.new do
        include(owner)

        def touched; end
      end

      expect(described_class.unoverridden?(klass, owner, :touched)).to be false
    end
  end

  describe ".fast_path?" do
    let(:owner) { Module.new { def touched; end } }

    def model_including(owner, &body)
      Class.new(TestModel) do
        self.table_name = "batch_items"
        include(owner)

        class_eval(&body) if body
      end
    end

    it "is true for a bare model with nothing overridden and no validations" do
      expect(described_class.fast_path?(model_including(owner), owner, :touched)).to be true
    end

    it "is false when the host overrode a listed method" do
      klass = model_including(owner) { def touched; end }

      expect(described_class.fast_path?(klass, owner, :touched)).to be false
    end

    it "is false when the model declares validates" do
      klass = model_including(owner) { validates :state, presence: true }

      expect(described_class.fast_path?(klass, owner, :touched)).to be false
    end

    # Regression: `validate :method` populates only _validate_callbacks, so a
    # `validators.empty?` gate waved it through and update_all wrote invalid rows.
    it "is false when the model declares a custom validate method" do
      klass = model_including(owner) do
        validate :state_present

        def state_present; end
      end

      expect(klass.validators).to be_empty
      expect(described_class.fast_path?(klass, owner, :touched)).to be false
    end
  end

  describe ".with_timestamps" do
    it "adds updated_at when the model has the column" do
      klass = Class.new(TestModel) { self.table_name = "stamped_items" }

      payload = described_class.with_timestamps(klass, state: "done")

      expect(payload[:state]).to eq("done")
      expect(payload["updated_at"]).to be_within(5.seconds).of(Time.zone.now)
    end

    it "leaves the payload alone when the model has no timestamp column" do
      klass = Class.new(TestModel) { self.table_name = "batch_items" }

      expect(described_class.with_timestamps(klass, state: "done")).to eq(state: "done")
    end

    it "leaves the payload alone when record_timestamps is off" do
      klass = Class.new(TestModel) do
        self.table_name = "stamped_items"
        self.record_timestamps = false
      end

      expect(described_class.with_timestamps(klass, state: "done")).to eq(state: "done")
    end
  end

  describe ".run" do
    it "returns the count of records the block accepted" do
      3.times { BatchItem.create!(state: "new") }

      count = described_class.run(BatchItem.all, label: "Test") { |r| r.update(state: "done") }

      expect(count).to eq(3)
      expect(BatchItem.where(state: "done").count).to eq(3)
    end

    it "does not count records the block skips" do
      BatchItem.create!(state: "new")
      BatchItem.create!(state: "keep")

      count = described_class.run(BatchItem.all, label: "Test") do |r|
        r.state == "keep" ? :skip : r.update(state: "done")
      end

      expect(count).to eq(1)
    end

    it "raises RecordNotSaved and rolls the batch back when the block returns falsey" do
      BatchItem.create!(state: "a")
      BatchItem.create!(state: "b")

      expect do
        described_class.run(BatchItem.all, label: "Test") do |r|
          r.state == "b" ? false : r.update(state: "done")
        end
      end.to raise_error(ActiveRecord::RecordNotSaved, /Test: failed to update record/)

      expect(BatchItem.where(state: "done").count).to eq(0)
    end

    it "uses a custom message when given" do
      BatchItem.create!(state: "a")

      expect do
        described_class.run(BatchItem.all, label: "Test", message: "failed to soft-delete record") { false }
      end.to raise_error(ActiveRecord::RecordNotSaved, /failed to soft-delete record/)
    end
  end
end
