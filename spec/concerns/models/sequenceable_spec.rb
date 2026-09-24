require "spec_helper"

describe ConcernsOnRails::Sequenceable do
  before do
    ActiveRecord::Schema.define do
      create_table :invoices, force: true do |t|
        t.string  :number
        t.integer :sequence
        t.integer :account_id
        t.timestamps
      end
    end

    class Invoice < TestModel
      include ConcernsOnRails::Sequenceable

      sequenceable_by :sequence, into: :number, prefix: "INV-", padding: 5
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end

    %i[Invoice StartAtInvoice PlainSequence ScopedInvoice YearlyInvoice TemplatedInvoice
       NoColumnInvoice NoIntoInvoice NoScopeColumnInvoice NoCreatedAtInvoice
       BadResetInvoice BadTemplateInvoice ManualInvoice ScopedManualInvoice BadAssignInvoice].each do |const|
      Object.send(:remove_const, const) if Object.const_defined?(const)
    end
  end

  describe "sequential assignment" do
    it "assigns 1, 2, 3 on successive creates" do
      a = Invoice.create!
      b = Invoice.create!
      c = Invoice.create!
      expect([a.sequence, b.sequence, c.sequence]).to eq([1, 2, 3])
    end

    it "does not overwrite a caller-supplied value" do
      invoice = Invoice.create!(sequence: 99)
      expect(invoice.sequence).to eq(99)
      expect(invoice.number).to eq("INV-00099")
    end

    it "persists the formatted string into the :into column" do
      invoice = Invoice.create!
      expect(invoice.number).to eq("INV-00001")
    end
  end

  describe "generated helpers" do
    it "#formatted_<field> returns the persisted formatted value" do
      invoice = Invoice.create!
      expect(invoice.formatted_sequence).to eq("INV-00001")
    end

    it ".next_<field> peeks the next value without creating a record" do
      expect(Invoice.next_sequence).to eq(1)
      Invoice.create!
      Invoice.create!
      expect(Invoice.next_sequence).to eq(3)
      expect(Invoice.count).to eq(2)
    end
  end

  describe "start_at:" do
    it "uses the configured starting value" do
      ActiveRecord::Schema.define do
        create_table :start_at_invoices, force: true do |t|
          t.integer :sequence
        end
      end

      class StartAtInvoice < TestModel
        include ConcernsOnRails::Sequenceable

        sequenceable_by :sequence, start_at: 1000
      end

      expect(StartAtInvoice.create!.sequence).to eq(1000)
      expect(StartAtInvoice.create!.sequence).to eq(1001)
    end
  end

  describe "no prefix / no padding" do
    it "formats the bare integer via formatted_<field>" do
      ActiveRecord::Schema.define do
        create_table :plain_sequences, force: true do |t|
          t.integer :sequence
        end
      end

      class PlainSequence < TestModel
        include ConcernsOnRails::Sequenceable

        sequenceable_by :sequence
      end

      record = PlainSequence.create!
      expect(record.sequence).to eq(1)
      expect(record.formatted_sequence).to eq("1")
    end
  end

  describe "scope:" do
    it "keeps an independent counter per scope value" do
      ActiveRecord::Schema.define do
        create_table :scoped_invoices, force: true do |t|
          t.integer :sequence
          t.integer :account_id
        end
      end

      class ScopedInvoice < TestModel
        include ConcernsOnRails::Sequenceable

        sequenceable_by :sequence, scope: :account_id
      end

      expect(ScopedInvoice.create!(account_id: 1).sequence).to eq(1)
      expect(ScopedInvoice.create!(account_id: 1).sequence).to eq(2)
      expect(ScopedInvoice.create!(account_id: 2).sequence).to eq(1)
      expect(ScopedInvoice.next_sequence(account_id: 1)).to eq(3)
      expect(ScopedInvoice.next_sequence(account_id: 2)).to eq(2)
    end
  end

  describe "reset: :year" do
    before do
      ActiveRecord::Schema.define do
        create_table :yearly_invoices, force: true do |t|
          t.string  :number
          t.integer :sequence
          t.timestamps
        end
      end

      class YearlyInvoice < TestModel
        include ConcernsOnRails::Sequenceable

        sequenceable_by :sequence, into: :number, prefix: "INV-", padding: 4, reset: :year
      end
    end

    it "embeds the year and restarts numbering each calendar year" do
      travel_to(Time.zone.local(2026, 6, 4)) do
        first  = YearlyInvoice.create!
        second = YearlyInvoice.create!
        expect(first.sequence).to eq(1)
        expect(first.number).to eq("INV-2026-0001")
        expect(second.sequence).to eq(2)
        expect(second.number).to eq("INV-2026-0002")
      end

      travel_to(Time.zone.local(2027, 1, 2)) do
        next_year = YearlyInvoice.create!
        expect(next_year.sequence).to eq(1)
        expect(next_year.number).to eq("INV-2027-0001")
      end
    end
  end

  describe "template:" do
    it "uses the custom formatter, overriding prefix/padding/period" do
      ActiveRecord::Schema.define do
        create_table :templated_invoices, force: true do |t|
          t.string  :number
          t.integer :sequence
        end
      end

      class TemplatedInvoice < TestModel
        include ConcernsOnRails::Sequenceable

        sequenceable_by :sequence, into: :number, template: ->(seq, _record) { "T#{seq}" }
      end

      expect(TemplatedInvoice.create!.number).to eq("T1")
      expect(TemplatedInvoice.create!.number).to eq("T2")
    end
  end

  describe "query efficiency" do
    it "assigns MAX+1 with a single SELECT — no exists? probe per create (1.26)" do
      Invoice.create! # sequence 1

      selects = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
        sql = args.last[:sql].to_s
        selects << sql if sql.start_with?("SELECT") && sql.include?("invoices")
      end
      invoice = Invoice.create!
      ActiveSupport::Notifications.unsubscribe(subscriber)

      expect(invoice.sequence).to eq(2)
      # The pre-1.26 taken?-probe emitted `SELECT 1 AS one` on every create,
      # re-verifying that MAX+1 is free — a tautology within one consistent read.
      expect(selects.grep(/SELECT 1/i)).to be_empty
      expect(selects.grep(/MAX/i).length).to eq(1)
    end
  end

  describe "validation" do
    it "raises when the integer field column does not exist" do
      ActiveRecord::Schema.define do
        create_table :no_column_invoices, force: true do |t|
          t.string :name
        end
      end

      expect do
        class NoColumnInvoice < TestModel
          include ConcernsOnRails::Sequenceable

          sequenceable_by :missing
        end
      end.to raise_error(ArgumentError, /does not exist/)
    end

    it "raises when the :into column does not exist" do
      ActiveRecord::Schema.define do
        create_table :no_into_invoices, force: true do |t|
          t.integer :sequence
        end
      end

      expect do
        class NoIntoInvoice < TestModel
          include ConcernsOnRails::Sequenceable

          sequenceable_by :sequence, into: :missing_number
        end
      end.to raise_error(ArgumentError, /does not exist/)
    end

    it "raises when a scope column does not exist" do
      ActiveRecord::Schema.define do
        create_table :no_scope_column_invoices, force: true do |t|
          t.integer :sequence
        end
      end

      expect do
        class NoScopeColumnInvoice < TestModel
          include ConcernsOnRails::Sequenceable

          sequenceable_by :sequence, scope: :account_id
        end
      end.to raise_error(ArgumentError, /does not exist/)
    end

    it "raises when reset is set but created_at is missing" do
      ActiveRecord::Schema.define do
        create_table :no_created_at_invoices, force: true do |t|
          t.integer :sequence
        end
      end

      expect do
        class NoCreatedAtInvoice < TestModel
          include ConcernsOnRails::Sequenceable

          sequenceable_by :sequence, reset: :year
        end
      end.to raise_error(ArgumentError, /does not exist/)
    end

    it "raises on an unknown reset value" do
      ActiveRecord::Schema.define do
        create_table :bad_reset_invoices, force: true do |t|
          t.integer :sequence
          t.timestamps
        end
      end

      expect do
        class BadResetInvoice < TestModel
          include ConcernsOnRails::Sequenceable

          sequenceable_by :sequence, reset: :decade
        end
      end.to raise_error(ArgumentError, /unknown reset/)
    end

    it "raises when template is not callable" do
      ActiveRecord::Schema.define do
        create_table :bad_template_invoices, force: true do |t|
          t.integer :sequence
        end
      end

      expect do
        class BadTemplateInvoice < TestModel
          include ConcernsOnRails::Sequenceable

          sequenceable_by :sequence, template: "not-callable"
        end
      end.to raise_error(ArgumentError, /template must be callable/)
    end
  end

  describe "assign: :manual (number on demand, e.g. when an invoice is finalized)" do
    before do
      class ManualInvoice < TestModel
        self.table_name = "invoices"
        include ConcernsOnRails::Sequenceable

        sequenceable_by :sequence, into: :number, prefix: "INV-", padding: 5, assign: :manual
      end
    end

    it "leaves the sequence blank on create and assigns it on demand, idempotently" do
      invoice = ManualInvoice.create!
      expect(invoice.sequence).to be_nil
      expect(invoice.number).to be_nil
      expect(invoice.sequence_assigned?).to be(false)
      expect(ManualInvoice.pending_sequence).to eq([invoice])

      expect(invoice.assign_sequence!).to be(true)
      expect(invoice.sequence).to eq(1)
      expect(invoice.number).to eq("INV-00001")
      expect(invoice.reload.number).to eq("INV-00001") # persisted
      expect(invoice.sequence_assigned?).to be(true)
      expect(ManualInvoice.pending_sequence).to be_empty

      expect(invoice.assign_sequence!).to be(false) # already numbered — nothing rewritten
      expect(invoice.sequence).to eq(1)

      second = ManualInvoice.create!
      second.assign_sequence!
      expect(second.number).to eq("INV-00002")
    end

    it "numbers in assignment order (not creation order) and respects scope:" do
      class ScopedManualInvoice < TestModel
        self.table_name = "invoices"
        include ConcernsOnRails::Sequenceable

        sequenceable_by :sequence, scope: :account_id, assign: :manual
      end
      a = ScopedManualInvoice.create!(account_id: 1)
      b = ScopedManualInvoice.create!(account_id: 1)
      c = ScopedManualInvoice.create!(account_id: 2)

      b.assign_sequence!
      a.assign_sequence!
      c.assign_sequence!
      expect([b.sequence, a.sequence, c.sequence]).to eq([1, 2, 1])
      expect(ScopedManualInvoice.next_sequence(account_id: 1)).to eq(3)
    end

    it "assigns on an unsaved record without saving it, and validates assign:" do
      invoice = ManualInvoice.new
      expect(invoice.assign_sequence!).to be(true)
      expect(invoice.sequence).to eq(1)
      expect(invoice.number).to eq("INV-00001")
      expect(invoice).to be_new_record
      invoice.save!
      expect(ManualInvoice.find(invoice.id).sequence).to eq(1)

      expect do
        class BadAssignInvoice < TestModel
          self.table_name = "invoices"
          include ConcernsOnRails::Sequenceable

          sequenceable_by :sequence, assign: :later
        end
      end.to raise_error(ArgumentError, /unknown assign ':later'. Valid values: create, manual/)
    end

    it "keeps the create-time default: automatic numbering, assign_<field>! a no-op afterwards" do
      invoice = Invoice.create!
      expect(invoice.sequence).to eq(1)
      expect(invoice.sequence_assigned?).to be(true)
      expect(invoice.assign_sequence!).to be(false)
      expect(Invoice.pending_sequence).to be_empty
    end
  end

  describe "STI subclasses sharing one sequence column (1.29 audit)" do
    before do
      ActiveRecord::Schema.define do
        create_table :sti_documents, force: true do |t|
          t.string  :type
          t.integer :sequence
          t.string  :number
          t.timestamps
        end
        add_index :sti_documents, :sequence, unique: true
      end

      Object.const_set(:StiDocument, Class.new(TestModel) do
        self.table_name = "sti_documents"
        include ConcernsOnRails::Sequenceable

        sequenceable_by :sequence, into: :number, prefix: "DOC-"
      end)
      Object.const_set(:StiCredit, Class.new(StiDocument))
      Object.const_set(:StiDebit, Class.new(StiDocument))
    end

    after do
      %i[StiCredit StiDebit StiDocument StiTypedDocument StiTypedCredit StiTypedDebit].each do |const|
        Object.send(:remove_const, const) if Object.const_defined?(const)
      end
    end

    it "numbers across the whole table, not per subclass" do
      credit = StiCredit.create!
      debit = StiDebit.create!
      base = StiDocument.create!

      expect([credit.sequence, debit.sequence, base.sequence]).to eq([1, 2, 3])
      expect(debit.number).to eq("DOC-2")
      expect(StiCredit.next_sequence).to eq(4)
    end

    it "still offers per-type numbering through scope: :type" do
      ActiveRecord::Base.connection.remove_index(:sti_documents, :sequence)
      Object.const_set(:StiTypedDocument, Class.new(TestModel) do
        self.table_name = "sti_documents"
        include ConcernsOnRails::Sequenceable

        sequenceable_by :sequence, scope: :type
      end)
      Object.const_set(:StiTypedCredit, Class.new(StiTypedDocument))
      Object.const_set(:StiTypedDebit, Class.new(StiTypedDocument))

      expect([StiTypedCredit.create!, StiTypedDebit.create!, StiTypedCredit.create!].map(&:sequence)).to eq([1, 1, 2])
    end
  end

  describe "assign_<field>! when the save fails (1.29 audit)" do
    before do
      ActiveRecord::Base.connection.add_index(:invoices, :sequence, unique: true)

      class ManualInvoice < TestModel
        self.table_name = "invoices"
        include ConcernsOnRails::Sequenceable

        sequenceable_by :sequence, into: :number, prefix: "INV-", assign: :manual
      end
    end

    # The first draw hands out a number another writer already holds — the
    # race the unique index exists for.
    def collide_once!(klass, taken)
      calls = 0
      allow(klass).to receive(:sequence_base_value).and_wrap_original do |original, *args|
        calls += 1
        calls == 1 ? taken : original.call(*args)
      end
    end

    it "puts the field back so UniqueRetry draws a fresh number instead of reporting 'already numbered'" do
      holder = ManualInvoice.create!
      holder.assign_sequence!
      invoice = ManualInvoice.create!
      collide_once!(ManualInvoice, holder.sequence)

      ConcernsOnRails::Support::UniqueRetry.with_retries { invoice.assign_sequence! }

      expect(invoice.reload.sequence).to eq(2)
      expect(invoice.number).to eq("INV-2")
    end

    it "restores both the field and the into: column when save! raises" do
      holder = ManualInvoice.create!
      holder.assign_sequence!
      invoice = ManualInvoice.create!
      collide_once!(ManualInvoice, holder.sequence)

      expect { invoice.assign_sequence! }.to raise_error(ActiveRecord::RecordNotUnique)
      expect(invoice.sequence).to be_nil
      expect(invoice.number).to be_nil
      expect(invoice.sequence_assigned?).to be(false)
    end

    it "restores on a validation failure too, and keeps a caller's transaction usable" do
      ManualInvoice.validate { errors.add(:base, "locked") if sequence.present? && account_id == 13 }
      invoice = ManualInvoice.create!(account_id: 13)

      ActiveRecord::Base.transaction do
        expect { invoice.assign_sequence! }.to raise_error(ActiveRecord::RecordInvalid)
        expect(invoice.sequence).to be_nil
        expect(invoice.number).to be_nil
        ManualInvoice.create! # the outer transaction is still usable
      end
      expect(ManualInvoice.count).to eq(2)
    end
  end

  describe "which rows share a counter: the class that DECLARED the macro (review of #111)" do
    before do
      ActiveRecord::Schema.define do
        create_table :x_docs, force: true do |t|
          t.string  :type
          t.integer :sequence
          t.string  :number
          t.timestamps
        end
        add_index :x_docs, %i[type sequence], unique: true
      end

      Object.const_set(:XDoc, Class.new(TestModel) { self.table_name = "x_docs" })
      Object.const_set(:XInvoice, Class.new(XDoc) do
        include ConcernsOnRails::Sequenceable

        sequenceable_by :sequence, into: :number, prefix: "INV-", padding: 4
      end)
      Object.const_set(:XCredit, Class.new(XDoc) do
        include ConcernsOnRails::Sequenceable

        sequenceable_by :sequence, into: :number, prefix: "CN-", padding: 4
      end)
    end

    after do
      %i[XInvoice XCredit XDoc].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    end

    it "keeps per-subclass numbering when each subclass declares its own sequence (gap-free per type)" do
      numbers = [XInvoice.create!, XInvoice.create!, XCredit.create!, XInvoice.create!].map(&:number)
      expect(numbers).to eq(%w[INV-0001 INV-0002 CN-0001 INV-0003])
    end

    it "previews exactly what the next per-subclass assignment produces" do
      2.times { XInvoice.create! }
      XCredit.create!

      expect(XInvoice.next_sequence).to eq(3)
      expect(XCredit.next_sequence).to eq(2)
      expect(XInvoice.create!.sequence).to eq(3)
      expect(XCredit.create!.sequence).to eq(2)
    end

    it "previews the base-declared, table-wide counter from the base and from any subclass" do
      ActiveRecord::Base.connection.remove_index(:x_docs, %i[type sequence])
      base = Class.new(TestModel) do
        self.table_name = "x_docs"
        include ConcernsOnRails::Sequenceable

        sequenceable_by :sequence
      end
      Object.const_set(:XShared, base)
      Object.const_set(:XSharedSub, Class.new(base))
      XSharedSub.create!
      XShared.create!

      expect(XShared.next_sequence).to eq(3)
      expect(XSharedSub.next_sequence).to eq(3)
      expect(XSharedSub.create!.sequence).to eq(3)
    ensure
      %i[XSharedSub XShared].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    end

    it "previews scope: :type per receiving class when no scope attrs are passed" do
      ActiveRecord::Base.connection.remove_index(:x_docs, %i[type sequence])
      base = Class.new(TestModel) do
        self.table_name = "x_docs"
        include ConcernsOnRails::Sequenceable

        sequenceable_by :sequence, scope: :type
      end
      Object.const_set(:XTyped, base)
      Object.const_set(:XTypedInv, Class.new(base))
      Object.const_set(:XTypedCn, Class.new(base))
      2.times { XTypedInv.create! }
      XTypedCn.create!

      expect(XTypedInv.next_sequence).to eq(3)
      expect(XTypedCn.next_sequence).to eq(2)
      expect(XTyped.next_sequence(type: "XTypedInv")).to eq(3) # explicit scope attrs still win
      expect(XTyped.next_sequence).to eq(1) # base rows carry type NULL
      expect([XTypedInv.create!, XTypedCn.create!, XTyped.create!].map(&:sequence)).to eq([3, 2, 1])
    ensure
      %i[XTypedInv XTypedCn XTyped].each { |c| Object.send(:remove_const, c) if Object.const_defined?(c) }
    end

    it "keeps the declaring class as the owner for a subclass that inherits the config" do
      Object.const_set(:XInvoiceProforma, Class.new(XInvoice))
      XInvoice.create!
      XCredit.create!
      expect(XInvoiceProforma.create!.number).to eq("INV-0002") # shares XInvoice's counter
      expect(XInvoiceProforma.next_sequence).to eq(3)
    ensure
      Object.send(:remove_const, :XInvoiceProforma) if Object.const_defined?(:XInvoiceProforma)
    end
  end

  describe "numbering class edge cases (re-review of #111)" do
    after do
      %i[AbInvSub AbInv AbQuote AbDoc RdInv RdCn RdCnSub RdBase].each do |c|
        Object.send(:remove_const, c) if Object.const_defined?(c)
      end
    end

    it "numbers over the concrete table when the macro is declared on an abstract class" do
      ActiveRecord::Schema.define do
        create_table :ab_invs, force: true do |t|
          t.string  :type
          t.integer :sequence
        end
        create_table :ab_quotes, force: true do |t|
          t.integer :sequence
        end
      end
      Object.const_set(:AbDoc, Class.new(TestModel) do
        self.abstract_class = true
        include ConcernsOnRails::Sequenceable

        sequenceable_by :sequence
      end)
      Object.const_set(:AbInv, Class.new(AbDoc) { self.table_name = "ab_invs" })
      Object.const_set(:AbInvSub, Class.new(AbInv))
      Object.const_set(:AbQuote, Class.new(AbDoc) { self.table_name = "ab_quotes" })

      expect([AbInv.create!, AbInvSub.create!, AbInv.create!].map(&:sequence)).to eq([1, 2, 3])
      expect(AbQuote.create!.sequence).to eq(1) # its own table, its own counter
      expect(AbInvSub.next_sequence).to eq(4)
      expect(AbInv.next_sequence).to eq(4)
      expect(AbQuote.next_sequence).to eq(2)
    end

    it "leaves out the rows of a subclass that re-declared its own sequence" do
      ActiveRecord::Schema.define do
        create_table :rd_docs, force: true do |t|
          t.string  :type
          t.integer :sequence
          t.string  :number
        end
      end
      Object.const_set(:RdBase, Class.new(TestModel) do
        self.table_name = "rd_docs"
        include ConcernsOnRails::Sequenceable

        sequenceable_by :sequence, into: :number, prefix: "INV-", padding: 4
      end)
      Object.const_set(:RdInv, Class.new(RdBase)) # inherits INV-
      Object.const_set(:RdCn, Class.new(RdBase) { sequenceable_by :sequence, into: :number, prefix: "CN-", padding: 4 })
      Object.const_set(:RdCnSub, Class.new(RdCn)) # inherits CN-

      numbers = [RdInv.create!, RdCn.create!, RdCnSub.create!, RdCn.create!, RdInv.create!, RdBase.create!].map(&:number)
      expect(numbers).to eq(%w[INV-0001 CN-0001 CN-0002 CN-0003 INV-0002 INV-0003])
      expect(RdInv.next_sequence).to eq(4)
      expect(RdBase.next_sequence).to eq(4)
      expect(RdCnSub.next_sequence).to eq(4)
    end
  end
end
