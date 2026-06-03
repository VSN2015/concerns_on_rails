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
       BadResetInvoice BadTemplateInvoice].each do |const|
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

  describe "uniqueness guard" do
    it "increments past an already-taken candidate value" do
      Invoice.create! # sequence 1
      allow(Invoice).to receive(:sequence_base_value).and_return(1)

      expect(Invoice.create!.sequence).to eq(2)
    end

    it "raises after MAX_GENERATION_ATTEMPTS consecutive collisions" do
      allow(Invoice).to receive(:sequence_value_taken?).and_return(true)

      expect { Invoice.create! }.to raise_error(/could not find a free value/)
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
end
