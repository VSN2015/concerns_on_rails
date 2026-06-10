# frozen_string_literal: true

require "spec_helper"

describe ConcernsOnRails::Auditable do
  before(:each) do
    ActiveRecord::Schema.define do
      create_table :audit_products, force: true do |t|
        t.string :name
        t.integer :price
        t.string :status
        t.text :audit_log
        t.timestamps
      end
    end

    class AuditProduct < TestModel
      include ConcernsOnRails::Auditable

      auditable_by :price, :status
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
    Object.send(:remove_const, :AuditProduct) if defined?(AuditProduct)
  end

  describe ".auditable_by" do
    it "raises if the audit column does not exist" do
      ActiveRecord::Schema.define do
        create_table :no_audit_models, force: true do |t|
          t.integer :price
        end
      end

      expect do
        Class.new(TestModel) do
          self.table_name = "no_audit_models"
          include ConcernsOnRails::Auditable

          auditable_by :price
        end
      end.to raise_error(ArgumentError, /'audit_log' does not exist/)
    end

    it "raises if a tracked field column does not exist" do
      expect do
        Class.new(TestModel) do
          self.table_name = "audit_products"
          include ConcernsOnRails::Auditable

          auditable_by :nope
        end
      end.to raise_error(ArgumentError, /'nope' does not exist/)
    end

    it "raises when no fields are given" do
      expect do
        Class.new(TestModel) do
          self.table_name = "audit_products"
          include ConcernsOnRails::Auditable

          auditable_by
        end
      end.to raise_error(ArgumentError, /requires at least one field/)
    end

    it "raises when the audit column itself is tracked" do
      expect do
        Class.new(TestModel) do
          self.table_name = "audit_products"
          include ConcernsOnRails::Auditable

          auditable_by :audit_log
        end
      end.to raise_error(ArgumentError, /cannot track the audit column/)
    end

    it "raises when max_entries is not a positive Integer or nil" do
      [0, "10"].each do |bad|
        expect do
          Class.new(TestModel) do
            self.table_name = "audit_products"
            include ConcernsOnRails::Auditable

            auditable_by :price, max_entries: bad
          end
        end.to raise_error(ArgumentError, /max_entries must be a positive Integer or nil/)
      end
    end

    it "raises when max_value_length is not a positive Integer or nil" do
      [0, "10"].each do |bad|
        expect do
          Class.new(TestModel) do
            self.table_name = "audit_products"
            include ConcernsOnRails::Auditable

            auditable_by :price, max_value_length: bad
          end
        end.to raise_error(ArgumentError, /max_value_length must be a positive Integer or nil/)
      end
    end

    it "raises when actor is not callable" do
      expect do
        Class.new(TestModel) do
          self.table_name = "audit_products"
          include ConcernsOnRails::Auditable

          auditable_by :price, actor: "me"
        end
      end.to raise_error(ArgumentError, /actor must be callable/)
    end

    it "reconfigures on a second call (last wins) without double-recording" do
      AuditProduct.auditable_by :status
      p = AuditProduct.create!(price: 1, status: "new")
      expect(p.audit_trail.map { |e| e["field"] }).to eq(["status"])
      p.update!(status: "live")
      expect(p.audit_trail.size).to eq(2)
    end
  end

  describe "change capture" do
    it "records one entry per changed field on update" do
      p = AuditProduct.create!(name: "Widget", price: 100)
      p.update!(price: 200)
      expect(p.audit_trail.last).to include("field" => "price", "from" => 100, "to" => 200)
    end

    it "records from: nil entries on create" do
      p = AuditProduct.create!(price: 100, status: "new")
      expect(p.audit_trail.map { |e| e["field"] }).to contain_exactly("price", "status")
      expect(p.audit_trail.map { |e| e["from"] }).to eq([nil, nil])
    end

    it "shares one timestamp when several tracked fields change in one save" do
      p = travel_to(Time.utc(2026, 6, 10, 12, 0, 0)) { AuditProduct.create!(price: 1, status: "new") }
      expect(p.audit_trail.map { |e| e["at"] }.uniq).to eq(["2026-06-10T12:00:00Z"])
    end

    it "ignores changes to untracked fields" do
      p = AuditProduct.create!(name: "a", price: 1)
      before_trail = p.audit_trail
      p.update!(name: "b")
      expect(p.reload.audit_trail).to eq(before_trail)
    end

    it "leaves the audit column untouched when nothing tracked changed" do
      p = AuditProduct.create!(name: "a")
      expect(p.reload[:audit_log]).to be_nil
      p.update!(name: "b")
      expect(p.reload[:audit_log]).to be_nil
    end

    it "stamps at as ISO8601 UTC" do
      travel_to(Time.utc(2026, 6, 10, 12, 34, 56)) do
        p = AuditProduct.create!(price: 1)
        expect(p.audit_trail.first["at"]).to eq("2026-06-10T12:34:56Z")
      end
    end
  end

  context "with time and decimal fields" do
    before do
      ActiveRecord::Schema.define do
        create_table :audit_shipments, force: true do |t|
          t.datetime :shipped_at
          t.decimal :cost, precision: 10, scale: 2
          t.text :audit_log
        end
      end

      class AuditShipment < TestModel
        include ConcernsOnRails::Auditable

        auditable_by :shipped_at, :cost
      end
    end

    after { Object.send(:remove_const, :AuditShipment) if defined?(AuditShipment) }

    it "serializes times as ISO8601 strings and decimals as plain number strings" do
      s = AuditShipment.create!(shipped_at: Time.utc(2026, 1, 2, 3, 4, 5), cost: BigDecimal("19.99"))
      by_field = s.audit_trail.to_h { |e| [e["field"], e["to"]] }
      expect(by_field["shipped_at"]).to eq("2026-01-02T03:04:05Z")
      expect(by_field["cost"]).to eq("19.99")
    end
  end

  describe "actor" do
    before do
      class AuditEdit < TestModel
        self.table_name = "audit_products"
        include ConcernsOnRails::Auditable

        auditable_by :price, actor: -> { "#{name}-editor" }
      end
    end

    after { Object.send(:remove_const, :AuditEdit) if defined?(AuditEdit) }

    it "records by from the actor proc, instance_exec'd on the record" do
      e = AuditEdit.create!(name: "alice", price: 1)
      expect(e.audit_trail.first["by"]).to eq("alice-editor")
    end

    it "omits by when the actor returns nil" do
      klass = Class.new(TestModel) do
        self.table_name = "audit_products"
        include ConcernsOnRails::Auditable

        auditable_by :price, actor: -> {}
      end
      rec = klass.create!(price: 1)
      expect(rec.audit_trail.first).not_to have_key("by")
    end

    it "omits by when no actor is configured" do
      p = AuditProduct.create!(price: 1)
      expect(p.audit_trail.first).not_to have_key("by")
    end
  end

  describe "#audit_trail" do
    it "returns [] for a blank column" do
      expect(AuditProduct.new.audit_trail).to eq([])
    end

    it "returns [] for corrupt or non-array JSON" do
      p = AuditProduct.create!(name: "x")
      p.update_column(:audit_log, "{oops")
      expect(p.reload.audit_trail).to eq([])
      p.update_column(:audit_log, '{"a":1}')
      expect(p.reload.audit_trail).to eq([])
    end

    it "returns entries oldest first across multiple saves" do
      p = AuditProduct.create!(price: 1)
      p.update!(price: 2)
      p.update!(price: 3)
      expect(p.audit_trail.map { |e| e["to"] }).to eq([1, 2, 3])
    end
  end

  describe "#last_change_for" do
    it "returns the most recent entry for the field" do
      p = AuditProduct.create!(price: 1)
      p.update!(price: 2)
      expect(p.last_change_for(:price)).to include("from" => 1, "to" => 2)
    end

    it "returns nil for a never-changed or unknown field" do
      p = AuditProduct.create!(price: 1)
      expect(p.last_change_for(:status)).to be_nil
      expect(p.last_change_for(:bogus)).to be_nil
    end
  end

  describe "#audited_changes_since" do
    it "returns only entries at or after the given time" do
      p = travel_to(Time.utc(2026, 6, 1, 12, 0, 0)) { AuditProduct.create!(price: 1) }
      travel_to(Time.utc(2026, 6, 9, 12, 0, 0)) { p.update!(price: 2) }
      expect(p.audited_changes_since(Time.utc(2026, 6, 5)).map { |e| e["to"] }).to eq([2])
    end
  end

  describe "max_entries trimming" do
    before do
      class AuditTrim < TestModel
        self.table_name = "audit_products"
        include ConcernsOnRails::Auditable

        auditable_by :price, max_entries: 2
      end
    end

    after { Object.send(:remove_const, :AuditTrim) if defined?(AuditTrim) }

    it "keeps only the newest entries" do
      p = AuditTrim.create!(price: 1)
      p.update!(price: 2)
      p.update!(price: 3)
      expect(p.audit_trail.map { |e| e["to"] }).to eq([2, 3])
    end

    it "keeps everything with max_entries: nil" do
      klass = Class.new(TestModel) do
        self.table_name = "audit_products"
        include ConcernsOnRails::Auditable

        auditable_by :price, max_entries: nil
      end
      p = klass.create!(price: 1)
      210.times { |i| p.update!(price: i + 2) }
      expect(p.audit_trail.size).to eq(211)
    end
  end

  describe "max_value_length truncation" do
    before do
      class AuditNote < TestModel
        self.table_name = "audit_products"
        include ConcernsOnRails::Auditable

        auditable_by :status, max_value_length: 4
      end
    end

    after { Object.send(:remove_const, :AuditNote) if defined?(AuditNote) }

    it "truncates long string values to the limit with a trailing ellipsis" do
      n = AuditNote.create!(status: "approved")
      n.update!(status: "rejected")
      entry = n.audit_trail.last
      expect(entry["from"]).to eq("appr…")
      expect(entry["to"]).to eq("reje…")
    end

    it "leaves values at or under the limit unchanged" do
      n = AuditNote.create!(status: "done")
      expect(n.audit_trail.first["to"]).to eq("done")
    end

    it "does not truncate non-string values" do
      klass = Class.new(TestModel) do
        self.table_name = "audit_products"
        include ConcernsOnRails::Auditable

        auditable_by :price, max_value_length: 2
      end
      rec = klass.create!(price: 12_345)
      expect(rec.audit_trail.first["to"]).to eq(12_345)
    end
  end

  describe "#clear_audit_trail!" do
    it "nils the column without recording a new entry" do
      p = AuditProduct.create!(price: 1)
      expect(p.audit_trail).not_to be_empty
      p.clear_audit_trail!
      expect(p.reload[:audit_log]).to be_nil
      expect(p.audit_trail).to eq([])
    end

    it "raises a labeled error on a new record" do
      expect { AuditProduct.new.clear_audit_trail! }
        .to raise_error(ArgumentError, /clear_audit_trail! cannot be called on a new record/)
    end
  end

  describe "aborted saves" do
    it "does not duplicate entries when a later before_save aborts and the save is retried" do
      klass = Class.new(TestModel) do
        self.table_name = "audit_products"
        include ConcernsOnRails::Auditable

        auditable_by :price

        attr_accessor :block_save

        before_save { throw :abort if block_save }
      end

      rec = klass.create!(price: 1)
      rec.block_save = true
      rec.price = 2
      expect(rec.save).to be(false)
      rec.block_save = false
      rec.save!
      expect(rec.audit_trail.map { |e| e["to"] }).to eq([1, 2])
    end
  end

  context "with non-finite float values" do
    before do
      ActiveRecord::Schema.define do
        create_table :audit_metrics, force: true do |t|
          t.float :score
          t.text :audit_log
        end
      end

      class AuditMetric < TestModel
        include ConcernsOnRails::Auditable

        auditable_by :score
      end
    end

    after { Object.send(:remove_const, :AuditMetric) if defined?(AuditMetric) }

    it "stores NaN and Infinity as strings instead of raising" do
      m = AuditMetric.create!(score: 1.0)
      m.score = Float::NAN
      expect { m.save! }.not_to raise_error
      expect(m.audit_trail.last["to"]).to eq("NaN")

      m.score = Float::INFINITY
      m.save!
      expect(m.audit_trail.last["to"]).to eq("Infinity")
    end
  end

  describe "callback-skipping writes (gotcha)" do
    it "does not record changes made via update_columns" do
      p = AuditProduct.create!(price: 1)
      p.update_columns(price: 99)
      expect(p.reload.audit_trail.map { |e| e["to"] }).to eq([1])
    end
  end
end
