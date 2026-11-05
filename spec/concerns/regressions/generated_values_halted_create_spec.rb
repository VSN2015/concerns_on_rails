require "spec_helper"

# DATA-S2 (audit 2026-10-29): a before_create declared AFTER a producer's that
# throws :abort halts the create. Outside a transaction Rails rolls back (so
# Revertible's rolledback! restores the column); inside a caller's transaction
# the Rollback is swallowed by the JOINED transaction, rolledback! never runs,
# and a retried save reused a value that was never inserted.
RSpec.describe "Generated values after a halted create" do
  def run(model, in_transaction, &blk)
    in_transaction ? model.transaction(&blk) : blk.call
  end

  def self.halted_examples(label, &build)
    describe label do
      let(:model) { instance_exec(&build) }

      [false, true].each do |in_transaction|
        context(in_transaction ? "inside a caller's transaction" : "outside a transaction") do
          it "puts the generated value back and draws afresh on the retry" do
            record = model.new
            model.halt = true
            result = nil
            run(model, in_transaction) { result = record.save }

            expect(result).to be(false)
            expect(record).to be_new_record
            expect(record[model.generated_column]).to be_nil

            model.halt = false
            run(model, in_transaction) { record.save! }
            expect(record).to be_persisted
            expect(record[model.generated_column]).not_to be_nil
          end

          it "keeps a value the caller supplied" do
            record = model.new(model.generated_column => model.supplied_value)
            model.halt = true
            run(model, in_transaction) { record.save }

            expect(record).to be_new_record
            expect(record[model.generated_column].to_s).to eq(model.supplied_value.to_s)
          end
        end
      end
    end
  end

  after do
    %i[gvh_users gvh_orders gvh_invoices gvh_tasks].each { |t| ActiveRecord::Base.connection.drop_table(t, if_exists: true) }
  end

  halted_examples("Tokenizable") do
    ActiveRecord::Schema.define do
      create_table :gvh_users, force: true do |t|
        t.string :invite_code
        t.timestamps
      end
    end
    stub_const("GvhUser", Class.new(TestModel) do
      self.table_name = "gvh_users"
      include ConcernsOnRails::Models::Tokenizable

      cattr_accessor :halt
      tokenizable_by :invite_code, type: :hex, length: 8
      before_create { throw :abort if self.class.halt }
      def self.generated_column = :invite_code
      def self.supplied_value = "mine1234"
    end)
  end

  halted_examples("Hashable") do
    ActiveRecord::Schema.define do
      create_table :gvh_orders, force: true do |t|
        t.string :code
        t.timestamps
      end
    end
    stub_const("GvhOrder", Class.new(TestModel) do
      self.table_name = "gvh_orders"
      include ConcernsOnRails::Models::Hashable

      cattr_accessor :halt
      hashable_by :code, type: :hex, length: 8
      before_create { throw :abort if self.class.halt }
      def self.generated_column = :code
      def self.supplied_value = "mine1234"
    end)
  end

  halted_examples("Sequenceable") do
    ActiveRecord::Schema.define do
      create_table :gvh_invoices, force: true do |t|
        t.string :number
        t.integer :sequence
        t.timestamps
      end
    end
    stub_const("GvhInvoice", Class.new(TestModel) do
      self.table_name = "gvh_invoices"
      include ConcernsOnRails::Models::Sequenceable

      cattr_accessor :halt
      sequenceable_by :sequence, into: :number, prefix: "INV-"
      before_create { throw :abort if self.class.halt }
      def self.generated_column = :number
      def self.supplied_value = "INV-99"
    end)
  end

  halted_examples("Sortable") do
    ActiveRecord::Schema.define do
      create_table :gvh_tasks, force: true do |t|
        t.integer :position
      end
    end
    stub_const("GvhTask", Class.new(TestModel) do
      self.table_name = "gvh_tasks"
      include ConcernsOnRails::Models::Sortable
    end)
    # Named first: acts_as_list 1.1 (the Rails 6.0 resolution) evals the class name.
    GvhTask.class_eval do
      cattr_accessor :halt
      sortable_by :position
      before_create { throw :abort if self.class.halt }
      def self.generated_column = :position
      def self.supplied_value = 7
    end
    GvhTask
  end

  describe "Sortable positions after a halted create" do
    before do
      ActiveRecord::Schema.define do
        create_table :gvh_tasks, force: true do |t|
          t.integer :position
        end
      end
      stub_const("GvhTask", Class.new(TestModel) do
        self.table_name = "gvh_tasks"
        include ConcernsOnRails::Models::Sortable
      end)
      GvhTask.class_eval do
        cattr_accessor :halt
        sortable_by :position
        before_create { throw :abort if self.class.halt }
      end
    end

    it "leaves position nil and a retry plus another create yield [1, 2, 3] (inside a transaction)" do
      GvhTask.create!
      record = GvhTask.new
      GvhTask.halt = true
      GvhTask.transaction { expect(record.save).to be(false) }
      expect(record.position).to be_nil

      GvhTask.halt = false
      GvhTask.create!
      GvhTask.transaction { record.save! }
      expect(GvhTask.unscoped.pluck(:position).sort).to eq([1, 2, 3])
    end
  end

  describe "Sequenceable number reuse" do
    before do
      ActiveRecord::Schema.define do
        create_table :gvh_invoices, force: true do |t|
          t.string :number
          t.integer :sequence
          t.timestamps
        end
        add_index :gvh_invoices, :sequence, unique: true
      end
      stub_const("GvhInvoice", Class.new(TestModel) do
        self.table_name = "gvh_invoices"
        include ConcernsOnRails::Models::Sequenceable

        cattr_accessor :halt
        sequenceable_by :sequence, into: :number, prefix: "INV-"
        before_create { throw :abort if self.class.halt }
      end)
    end

    it "does not re-insert a number another row took meanwhile (inside a transaction)" do
      record = GvhInvoice.new
      GvhInvoice.halt = true
      GvhInvoice.transaction { expect(record.save).to be(false) }
      GvhInvoice.halt = false
      GvhInvoice.create!

      GvhInvoice.transaction { record.save! }
      expect(GvhInvoice.pluck(:sequence).sort).to eq([1, 2])
    end
  end
end
