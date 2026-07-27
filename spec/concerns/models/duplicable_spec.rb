require "spec_helper"

RSpec.describe ConcernsOnRails::Models::Duplicable do
  before do
    ActiveRecord::Schema.define do
      create_table :dup_invoices, force: true do |t|
        t.string :title
        t.string :slug
        t.integer :sequence
        t.string :number
        t.string :token
        t.datetime :issued_at
        t.datetime :deleted_at
        t.text :audit_log
        t.integer :failed_attempts
        t.datetime :locked_at
        t.timestamps null: true
      end
      create_table :dup_line_items, force: true do |t|
        t.integer :dup_invoice_id
        t.string :description
        t.integer :quantity
        t.string :batch_code
        t.timestamps null: true
      end
      create_table :dup_notes, force: true do |t|
        t.integer :dup_invoice_id
        t.string :body
      end
      create_table :dup_tags, force: true do |t|
        t.string :name
      end
      create_table :dup_invoices_dup_tags, id: false, force: true do |t|
        t.integer :dup_invoice_id
        t.integer :dup_tag_id
      end
    end

    line_item = Class.new(TestModel) do
      self.table_name = "dup_line_items"
      include ConcernsOnRails::Models::Duplicable

      duplicable_by reset: %i[batch_code]
    end
    Object.const_set(:DupLineItem, line_item)

    Object.const_set(:DupNote, Class.new(TestModel) { self.table_name = "dup_notes" })
    Object.const_set(:DupTag, Class.new(TestModel) { self.table_name = "dup_tags" })

    # Named BEFORE the associations are declared: has_and_belongs_to_many
    # derives its internals from the model's class name, so it cannot be
    # declared on a still-anonymous class.
    invoice = Class.new(TestModel) { self.table_name = "dup_invoices" }
    Object.const_set(:DupInvoice, invoice)
    invoice.class_eval do
      include ConcernsOnRails::Models::Duplicable

      has_many :dup_line_items, class_name: "DupLineItem", foreign_key: :dup_invoice_id
      has_one :dup_note, class_name: "DupNote", foreign_key: :dup_invoice_id
      has_and_belongs_to_many :dup_tags, class_name: "DupTag",
                                         join_table: "dup_invoices_dup_tags",
                                         foreign_key: :dup_invoice_id,
                                         association_foreign_key: :dup_tag_id

      duplicable_by associations: %i[dup_line_items dup_note dup_tags],
                    reset: %i[issued_at],
                    suffix: { title: " (copy)" }
    end
  end

  after do
    %i[DupInvoice DupLineItem DupNote DupTag].each do |name|
      Object.send(:remove_const, name) if Object.const_defined?(name)
    end
    %i[dup_invoices dup_line_items dup_notes dup_tags dup_invoices_dup_tags].each do |table|
      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  describe "#duplicate" do
    it "returns an unsaved copy with attributes, no id, and blank timestamps" do
      original = DupInvoice.create!(title: "Q1", issued_at: 2.days.ago)
      copy = original.duplicate

      expect(copy).to be_new_record
      expect(copy.id).to be_nil
      expect(copy.created_at).to be_nil
      expect(copy.updated_at).to be_nil
      expect(copy.title).to eq("Q1 (copy)")
    end

    it "blanks reset: columns and applies suffix: only to present values" do
      original = DupInvoice.create!(title: nil, issued_at: Time.zone.now)
      copy = original.duplicate

      expect(copy.issued_at).to be_nil
      expect(copy.title).to be_nil # no suffix appended to a blank value
    end

    it "applies overrides through the writers" do
      original = DupInvoice.create!(title: "Q1")
      copy = original.duplicate(title: "Q2 rebill")
      expect(copy.title).to eq("Q2 rebill")
    end

    it "works with a bare include (no duplicable_by call)" do
      klass = Class.new(TestModel) do
        self.table_name = "dup_notes"
        include ConcernsOnRails::Models::Duplicable
      end
      original = klass.create!(body: "hello")
      copy = original.duplicate
      expect(copy.body).to eq("hello")
      expect(copy).to be_new_record
    end

    it "runs the on_duplicate hook with the unsaved copy" do
      klass = Class.new(TestModel) do
        self.table_name = "dup_notes"
        include ConcernsOnRails::Models::Duplicable

        def on_duplicate(copy)
          copy.body = "#{copy.body} [hooked]"
        end
      end
      copy = klass.create!(body: "note").duplicate
      expect(copy.body).to eq("note [hooked]")
    end
  end

  describe "#duplicate! and associations" do
    it "persists the copy with deep-copied has_many children" do
      original = DupInvoice.create!(title: "Q1")
      original.dup_line_items.create!(description: "Widget", quantity: 2, batch_code: "B-1")
      original.dup_line_items.create!(description: "Gadget", quantity: 5, batch_code: "B-2")

      copy = original.duplicate!

      expect(copy).to be_persisted
      expect(copy.dup_line_items.count).to eq(2)
      expect(copy.dup_line_items.pluck(:description)).to match_array(%w[Widget Gadget])
      expect(copy.dup_line_items.pluck(:id) & original.dup_line_items.pluck(:id)).to be_empty
      expect(original.reload.dup_line_items.count).to eq(2)
    end

    it "copies children through THEIR OWN Duplicable rules (nested resets)" do
      original = DupInvoice.create!(title: "Q1")
      original.dup_line_items.create!(description: "Widget", quantity: 2, batch_code: "B-1")

      copy = original.duplicate!
      expect(copy.dup_line_items.first.batch_code).to be_nil
      expect(original.dup_line_items.first.batch_code).to eq("B-1")
    end

    it "deep-copies a has_one child and tolerates its absence" do
      with_note = DupInvoice.create!(title: "A")
      DupNote.create!(dup_invoice_id: with_note.id, body: "attached")
      without_note = DupInvoice.create!(title: "B")

      copy = with_note.duplicate!
      expect(copy.dup_note.body).to eq("attached")
      expect(copy.dup_note.id).not_to eq(with_note.dup_note.id)

      expect(without_note.duplicate!.dup_note).to be_nil
    end

    it "shares (not copies) has_and_belongs_to_many records" do
      original = DupInvoice.create!(title: "Q1")
      tag = DupTag.create!(name: "urgent")
      original.dup_tags << tag

      copy = original.duplicate!

      expect(copy.dup_tags).to contain_exactly(tag)
      expect(DupTag.count).to eq(1)
    end
  end

  describe "macro validation" do
    it "raises for an undeclared association" do
      expect do
        Class.new(TestModel) do
          self.table_name = "dup_invoices"
          include ConcernsOnRails::Models::Duplicable

          duplicable_by associations: %i[nonexistent]
        end
      end.to raise_error(ArgumentError, /no association `nonexistent`/)
    end

    it "raises for a belongs_to association" do
      expect do
        Class.new(TestModel) do
          self.table_name = "dup_line_items"
          include ConcernsOnRails::Models::Duplicable

          belongs_to :dup_invoice, class_name: "DupInvoice", optional: true
          duplicable_by associations: %i[dup_invoice]
        end
      end.to raise_error(ArgumentError, /belongs_to/)
    end

    it "raises for a has_many :through association" do
      expect do
        Class.new(TestModel) do
          self.table_name = "dup_invoices"
          include ConcernsOnRails::Models::Duplicable

          has_many :dup_line_items, class_name: "DupLineItem", foreign_key: :dup_invoice_id
          has_many :sibling_invoices, through: :dup_line_items, source: :dup_invoice
          duplicable_by associations: %i[sibling_invoices]
        end
      end.to raise_error(ArgumentError, /:through/)
    end

    it "raises for a missing reset: column" do
      expect do
        Class.new(TestModel) do
          self.table_name = "dup_invoices"
          include ConcernsOnRails::Models::Duplicable

          duplicable_by reset: %i[nope]
        end
      end.to raise_error(ArgumentError, /does not exist/)
    end
  end

  describe "concern-aware identity resets" do
    let(:klass) do
      Class.new(TestModel) do
        self.table_name = "dup_invoices"
        include ConcernsOnRails::Models::Duplicable
        include ConcernsOnRails::Models::Tokenizable
        include ConcernsOnRails::Models::Sequenceable
        include ConcernsOnRails::Models::Auditable
        include ConcernsOnRails::Models::SoftDeletable
        include ConcernsOnRails::Models::Lockable

        tokenizable_by :token, type: :hex, length: 12
        sequenceable_by :sequence, into: :number, prefix: "INV-"
        auditable_by :title, into: :audit_log
        soft_deletable_by :deleted_at, default_scope: false
        lockable_by attempts: :failed_attempts, locked_at: :locked_at
      end
    end

    it "regenerates tokens, sequence numbers, and formatted numbers on the copy" do
      original = klass.create!(title: "Q1")
      copy = original.duplicate!

      expect(copy.token).to be_present
      expect(copy.token).not_to eq(original.token)
      expect(copy.sequence).to eq(original.sequence + 1)
      expect(copy.number).to eq("INV-#{copy.sequence}")
    end

    it "does not inherit the original's audit history (only the copy's own creation entry)" do
      original = klass.create!(title: "Q1")
      original.update!(title: "Q1 revised")
      expect(original.audit_trail.length).to eq(2)

      copy = original.duplicate!
      expect(copy.audit_trail.length).to eq(1)
      expect(copy.audit_trail.first).to include("field" => "title", "from" => nil, "to" => "Q1 revised")
    end

    it "copies a soft-deleted record as a live one" do
      original = klass.create!(title: "Q1")
      original.soft_delete!

      copy = original.duplicate!
      expect(copy.deleted_at).to be_nil
      expect(copy.deleted?).to be(false)
    end

    it "resets the lockout state on the copy" do
      original = klass.create!(title: "Q1")
      original.update_columns(failed_attempts: 3, locked_at: Time.zone.now)

      copy = original.reload.duplicate!
      expect(copy.failed_attempts).to eq(0)
      expect(copy.locked_at).to be_nil
    end

    it "gives the copy fresh timestamps" do
      original = klass.create!(title: "Q1")
      original.update_columns(created_at: 2.years.ago)

      copy = original.reload.duplicate!
      expect(copy.created_at).to be > 1.minute.ago
    end
  end

  describe "Sluggable interaction" do
    let(:klass) do
      Class.new(TestModel) do
        self.table_name = "dup_invoices"
        include ConcernsOnRails::Models::Duplicable
        include ConcernsOnRails::Models::Sluggable

        sluggable_by :title
      end
    end

    it "regenerates a unique slug for the copy" do
      original = klass.create!(title: "Hello World")
      expect(original.slug).to eq("hello-world")

      copy = original.duplicate!
      expect(copy.slug).to be_present
      expect(copy.slug).not_to eq(original.slug)
    end
  end
end
