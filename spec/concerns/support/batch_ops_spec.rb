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

    # find_each pages by primary key: it dropped the relation's ORDER but kept
    # its LIMIT, so `order(id: :desc).limit(2)` batched the two LOWEST ids —
    # not the rows the fast path's update_all touches for the same relation.
    it "visits exactly the rows an ordered, limited relation selects" do
      ids = Array.new(4) { BatchItem.create!(state: "new").id }

      count = described_class.run(BatchItem.order(id: :desc).limit(2), label: "Test") { |r| r.update(state: "done") }

      expect(count).to eq(2)
      expect(BatchItem.where(state: "done").pluck(:id).sort).to eq(ids.last(2))
    end

    it "honors an offset the same way" do
      ids = Array.new(5) { BatchItem.create!(state: "new").id }

      described_class.run(BatchItem.order(id: :desc).offset(1).limit(2), label: "Test") { |r| r.update(state: "done") }

      expect(BatchItem.where(state: "done").pluck(:id).sort).to eq(ids[2, 2])
    end

    it "still applies the relation's own conditions once the limit is resolved" do
      keep = BatchItem.create!(state: "keep")
      2.times { BatchItem.create!(state: "new") }

      described_class.run(BatchItem.where(state: "new").order(id: :desc).limit(5), label: "Test") do |r|
        r.update(state: "done")
      end

      expect(keep.reload.state).to eq("keep")
      expect(BatchItem.where(state: "done").count).to eq(2)
    end

    # Handing the whole plucked key list to find_each re-sent all of it in
    # every 1000-row batch — quadratic in the limit.
    it "sends at most one batch of keys per query for a large limited relation" do
      BatchItem.insert_all(Array.new(2500) { { state: "new" } })
      in_lists = []
      counter = lambda do |*, payload|
        sql = payload[:sql].to_s
        in_lists << sql.scan(/\d+/).size if sql.include?("batch_items") && sql.match?(/ IN \(/)
      end

      seen = 0
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        described_class.each_record(BatchItem.order(id: :desc).limit(2500)) { seen += 1 }
      end

      expect(seen).to eq(2500)
      expect(in_lists.size).to eq(3)
      expect(in_lists.max).to be <= 1010
    end

    it "handles a joined, DISTINCT relation ordered by a column it does not pluck" do
      ActiveRecord::Schema.define do
        create_table :batch_owners, force: true do |t|
          t.string :name
        end
        add_column :batch_items, :batch_owner_id, :integer
      end
      stub_const("BatchOwner", Class.new(TestModel) { self.table_name = "batch_owners" })
      joined = Class.new(TestModel)
      stub_const("JoinedBatchItem", joined) # joins(:assoc) needs a named class
      joined.class_eval do
        self.table_name = "batch_items"
        belongs_to :batch_owner, class_name: "BatchOwner", optional: true
      end
      owner = BatchOwner.create!(name: "o")
      items = %w[c a b].map { |state| joined.create!(state: state, batch_owner_id: owner.id) }

      seen = []
      relation = joined.joins(:batch_owner).distinct.order(:state).limit(2)
      described_class.each_record(relation) { |record| seen << record.state }

      expect(seen.sort).to eq(%w[a b])
      expect(items.size).to eq(3)
    end

    it "handles a composite primary key", min_rails: "7.1" do
      ActiveRecord::Schema.define do
        create_table :batch_pairs, primary_key: %i[a b], force: true do |t|
          t.integer :a
          t.integer :b
        end
      end
      pair = Class.new(TestModel) { self.table_name = "batch_pairs" }
      [[1, 1], [1, 2], [2, 1]].each { |a, b| pair.create!(a: a, b: b) }

      seen = []
      described_class.each_record(pair.order(a: :desc, b: :desc).limit(2)) { |r| seen << [r.a, r.b] }

      expect(seen).to eq([[1, 2], [2, 1]])
    end

    describe "under error_on_ignored_order" do
      around do |example|
        config = ActiveRecord.respond_to?(:error_on_ignored_order=) ? ActiveRecord : ActiveRecord::Base
        previous = config.error_on_ignored_order
        config.error_on_ignored_order = true
        example.run
      ensure
        config.error_on_ignored_order = previous
      end

      # A Sortable model's default_scope ORDER BY made every slow-path verb
      # raise "Scoped order is ignored" instead of running.
      it "does not raise for an ordered relation (a default_scope order included)" do
        ordered = Class.new(TestModel) do
          self.table_name = "batch_items"
          default_scope { order(:state) }
        end
        2.times { ordered.create!(state: "new") }

        expect(described_class.run(ordered.all, label: "Test") { |r| r.update(state: "done") }).to eq(2)
      end
    end
  end
end
