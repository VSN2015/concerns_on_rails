require "spec_helper"

# SCOPE-2 (audit 2026-10-10): a number / token / code generated in
# before_create used to survive a failed INSERT, because Rails keeps a rolled
# back record's current attribute values and every producer assigns only into a
# blank column. A retried `save!` of the SAME record re-inserted the loser.
RSpec.describe "Generated values after a failed INSERT" do
  let(:retry_with) { ConcernsOnRails::Support::UniqueRetry }

  describe "Sequenceable" do
    before do
      ActiveRecord::Schema.define do
        create_table :gv_invoices, force: true do |t|
          t.string :number
          t.integer :sequence
          t.timestamps
        end
        add_index :gv_invoices, :sequence, unique: true
      end
      stub_const("GvInvoice", Class.new(TestModel) do
        self.table_name = "gv_invoices"
        include ConcernsOnRails::Models::Sequenceable

        sequenceable_by :sequence, into: :number, prefix: "INV-"
      end)
    end

    after { ActiveRecord::Base.connection.drop_table(:gv_invoices, if_exists: true) }

    # The first draw hands out a number a concurrent writer already holds.
    def collide_once!(taken)
      calls = 0
      allow(GvInvoice).to receive(:sequence_base_value).and_wrap_original do |original, *args|
        calls += 1
        calls == 1 ? taken : original.call(*args)
      end
    end

    it "draws a fresh number when UniqueRetry re-saves the same new record" do
      holder = GvInvoice.create!
      invoice = GvInvoice.new
      collide_once!(holder.sequence)

      retry_with.with_retries { invoice.save! }

      expect(invoice.reload.sequence).to eq(2)
      expect(invoice.number).to eq("INV-2")
    end

    it "draws a fresh number inside a caller's transaction (savepoint: retry)" do
      holder = GvInvoice.create!
      invoice = GvInvoice.new
      collide_once!(holder.sequence)

      GvInvoice.transaction do
        retry_with.with_retries(savepoint: GvInvoice) { invoice.save! }
      end

      expect(invoice.reload.sequence).to eq(2)
    end

    it "puts the drawn number and the into: string back after a failed INSERT" do
      holder = GvInvoice.create!
      invoice = GvInvoice.new
      collide_once!(holder.sequence)

      expect { invoice.save! }.to raise_error(ActiveRecord::RecordNotUnique)
      expect(invoice).to be_new_record
      expect(invoice.sequence).to be_nil
      expect(invoice.number).to be_nil
    end

    it "puts the number back when the caller's transaction rolls the create back" do
      invoice = GvInvoice.new

      GvInvoice.transaction do
        invoice.save!
        raise ActiveRecord::Rollback
      end

      expect(invoice).to be_new_record
      expect(invoice.sequence).to be_nil
      expect(invoice.number).to be_nil
      invoice.save!
      expect(invoice.reload.sequence).to eq(1)
    end

    it "keeps a sequence the caller supplied after a failed INSERT" do
      holder = GvInvoice.create!
      invoice = GvInvoice.new(sequence: 1)

      expect { invoice.save! }.to raise_error(ActiveRecord::RecordNotUnique)
      expect(invoice.sequence).to eq(1)

      holder.destroy
      invoice.save!
      expect(invoice.reload.number).to eq("INV-1")
    end

    it "leaves a persisted record's number alone" do
      invoice = GvInvoice.create!
      expect { invoice.update!(sequence: 1) }.not_to raise_error
      expect(invoice.reload.number).to eq("INV-1")
    end
  end

  describe "Tokenizable" do
    before do
      ActiveRecord::Schema.define do
        create_table :gv_users, force: true do |t|
          t.string :invite_code
          t.datetime :invite_code_expires_at
        end
        add_index :gv_users, :invite_code, unique: true
      end
      stub_const("GvUser", Class.new(TestModel) do
        self.table_name = "gv_users"
        include ConcernsOnRails::Models::Tokenizable

        tokenizable_by :invite_code, type: :numeric, length: 4, expires_in: 1.hour
      end)
    end

    after { ActiveRecord::Base.connection.drop_table(:gv_users, if_exists: true) }

    def collide_once!(user, taken)
      calls = 0
      allow(user).to receive(:tokenizable_unique_value).and_wrap_original do |original, *args|
        calls += 1
        calls == 1 ? taken : original.call(*args)
      end
    end

    it "draws a fresh token when a retried save! re-saves the same new record" do
      GvUser.create!(invite_code: "1111")
      user = GvUser.new
      collide_once!(user, "1111")

      retry_with.with_retries { user.save! }

      expect(user.reload.invite_code).not_to eq("1111")
    end

    it "puts the token and its expiry back after a failed INSERT" do
      GvUser.create!(invite_code: "1111")
      user = GvUser.new
      collide_once!(user, "1111")

      expect { user.save! }.to raise_error(ActiveRecord::RecordNotUnique)
      expect(user.invite_code).to be_nil
      expect(user.invite_code_expires_at).to be_nil
    end

    it "keeps a token the caller supplied after a failed INSERT" do
      GvUser.create!(invite_code: "1111")
      user = GvUser.new(invite_code: "1111")

      expect { user.save! }.to raise_error(ActiveRecord::RecordNotUnique)
      expect(user.invite_code).to eq("1111")
    end

    it "does not overwrite a token the caller assigned after the failure" do
      GvUser.create!(invite_code: "1111")
      user = GvUser.new
      collide_once!(user, "1111")
      expect { user.save! }.to raise_error(ActiveRecord::RecordNotUnique)

      user.invite_code = "2222"
      user.save!

      expect(user.reload.invite_code).to eq("2222")
    end
  end

  describe "Hashable" do
    before do
      ActiveRecord::Schema.define do
        create_table :gv_orders, force: true do |t|
          t.string :code
        end
        add_index :gv_orders, :code, unique: true
      end
      stub_const("GvOrder", Class.new(TestModel) do
        self.table_name = "gv_orders"
        include ConcernsOnRails::Models::Hashable

        hashable_by :code, type: :integer, length: 2
      end)
    end

    after { ActiveRecord::Base.connection.drop_table(:gv_orders, if_exists: true) }

    def collide_once!
      calls = 0
      allow(GvOrder).to receive(:generate_hashable_value).and_wrap_original do |original|
        calls += 1
        calls == 1 ? 42 : original.call
      end
    end

    it "draws a fresh code when a retried save! re-saves the same new record" do
      GvOrder.create!(code: "42")
      collide_once!
      order = GvOrder.new

      retry_with.with_retries { order.save! }

      expect(order.reload.code).not_to eq("42")
    end

    it "puts the code back after a failed INSERT" do
      GvOrder.create!(code: "42")
      collide_once!
      order = GvOrder.new

      expect { order.save! }.to raise_error(ActiveRecord::RecordNotUnique)
      expect(order.code).to be_nil
    end

    it "keeps a code the caller supplied after a failed INSERT" do
      GvOrder.create!(code: "42")
      order = GvOrder.new(code: "42")

      expect { order.save! }.to raise_error(ActiveRecord::RecordNotUnique)
      expect(order.code).to eq("42")
    end

    it "keeps a code assigned before the save" do
      GvOrder.create!(code: "42")
      order = GvOrder.new
      order.assign_hashable_value
      first = order.code
      GvOrder.where(code: first).delete_all
      GvOrder.create!(code: first)

      expect { order.save! }.to raise_error(ActiveRecord::RecordNotUnique)
      expect(order.code).to eq(first)
    end
  end

  describe "Sortable" do
    before do
      ActiveRecord::Schema.define do
        create_table :gv_tasks, force: true do |t|
          t.integer :position
        end
      end
      stub_const("GvTask", Class.new(TestModel) do
        self.table_name = "gv_tasks"
        include ConcernsOnRails::Models::Sortable
      end)
      # Named first: acts_as_list 1.1 (the Rails 6.0 resolution) evals the class name.
      GvTask.sortable_by :position
    end

    after { ActiveRecord::Base.connection.drop_table(:gv_tasks, if_exists: true) }

    it "puts the list position back when the caller's transaction rolls the create back" do
      GvTask.create!
      task = GvTask.new

      GvTask.transaction do
        task.save!
        raise ActiveRecord::Rollback
      end

      expect(task).to be_new_record
      expect(task.position).to be_nil
      task.save!
      expect(task.reload.position).to eq(2)
    end
  end
end
