require "spec_helper"

# SCOPE-5 (audit 2026-10-10): with `assign: :manual` + `reset:` a draft was
# numbered in the period it was DRAFTED (the row's created_at), not the one it
# is finalized in. `period_column:` lets the host name the stored instant the
# period is cut from (default :created_at, the long-standing behaviour).
RSpec.describe "Sequenceable period_column:" do
  before do
    ActiveRecord::Schema.define do
      create_table :pc_invoices, force: true do |t|
        t.integer :sequence
        t.string :number
        t.datetime :finalized_at
        t.date :finalized_on
        t.string :type
        t.timestamps null: true
      end
    end
  end

  after { ActiveRecord::Base.connection.drop_table(:pc_invoices, if_exists: true) }

  def build_class(**options)
    Class.new(TestModel) do
      self.table_name = "pc_invoices"
      include ConcernsOnRails::Models::Sequenceable

      sequenceable_by :sequence, into: :number, prefix: "INV-", reset: :year, assign: :manual,
                                 time_zone: "UTC", **options
    end
  end

  # Issued in Dec 2025, drafted in Dec 2025, then another issued in Jan 2026;
  # the draft is finalized last (2026-01-05).
  def finalize_scenario(klass)
    issued = travel_to(Time.utc(2025, 12, 10)) { klass.create!.tap(&:assign_sequence!) }
    draft = travel_to(Time.utc(2025, 12, 20)) { klass.create! }
    fresh = travel_to(Time.utc(2026, 1, 3)) { klass.create!.tap(&:assign_sequence!) }
    travel_to(Time.utc(2026, 1, 5)) { draft.assign_sequence! }
    [issued, draft, fresh]
  end

  context "with the default anchor (created_at)" do
    it "numbers a late-finalized draft into the period it was created in" do
      issued, draft, fresh = finalize_scenario(build_class)

      expect([issued.number, fresh.number]).to eq(%w[INV-2025-1 INV-2026-1])
      expect(draft.number).to eq("INV-2025-2")
    end

    it "keeps :created_at as the default period_column" do
      expect(build_class.sequenceable_config[:sequence][:period_column]).to eq(:created_at)
    end
  end

  context "with period_column: :finalized_at" do
    let(:klass) { build_class(period_column: :finalized_at) }

    it "numbers a draft in the period it is finalized in" do
      issued, draft, fresh = finalize_scenario(klass)

      expect(issued.number).to eq("INV-2025-1")
      expect(fresh.number).to eq("INV-2026-1")
      expect(draft.number).to eq("INV-2026-2")
      expect(draft.reload.number).to eq("INV-2026-2")
    end

    it "stamps the period column when assigning, and persists it" do
      draft = travel_to(Time.utc(2025, 12, 20)) { klass.create! }
      expect(draft.finalized_at).to be_nil

      travel_to(Time.utc(2026, 1, 5, 9)) { draft.assign_sequence! }

      expect(draft.reload.finalized_at).to eq(Time.utc(2026, 1, 5, 9))
    end

    it "counts the finalized period (not creation time) when later rows are numbered" do
      finalize_scenario(klass)
      another = travel_to(Time.utc(2026, 1, 9)) { klass.create!.tap(&:assign_sequence!) }

      expect(another.number).to eq("INV-2026-3")
    end

    it "keeps a period column the caller already set" do
      draft = travel_to(Time.utc(2026, 1, 5)) { klass.create!(finalized_at: Time.utc(2025, 12, 31, 12)) }
      travel_to(Time.utc(2026, 1, 5)) { draft.assign_sequence! }

      expect(draft.number).to eq("INV-2025-1")
      expect(draft.finalized_at).to eq(Time.utc(2025, 12, 31, 12))
    end

    it "anchors sequenceable_period_time and formatted_<field> on the period column" do
      plain = Class.new(TestModel) do
        self.table_name = "pc_invoices"
        include ConcernsOnRails::Models::Sequenceable

        sequenceable_by :sequence, prefix: "INV-", reset: :year, assign: :manual, time_zone: "UTC",
                                   period_column: :finalized_at
      end
      draft = travel_to(Time.utc(2025, 12, 20)) { plain.create! }
      travel_to(Time.utc(2026, 1, 5)) { draft.assign_sequence! }

      expect(draft.sequenceable_period_time(:sequence).year).to eq(2026)
      expect(draft.formatted_sequence).to eq("INV-2026-1")
    end

    it "cuts the period in the field's zone" do
      tokyo = Class.new(TestModel) do
        self.table_name = "pc_invoices"
        include ConcernsOnRails::Models::Sequenceable

        sequenceable_by :sequence, into: :number, prefix: "INV-", reset: :year, assign: :manual,
                                   time_zone: "Tokyo", period_column: :finalized_at
      end
      draft = tokyo.create!
      draft.finalized_at = Time.utc(2025, 12, 31, 16) # 2026-01-01 01:00 in Tokyo
      draft.assign_sequence!

      expect(draft.number).to eq("INV-2026-1")
    end

    it "puts the stamped period column back when the assigning save fails" do
      draft = travel_to(Time.utc(2025, 12, 20)) { klass.create! }
      allow(draft).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique)

      expect { draft.assign_sequence! }.to raise_error(ActiveRecord::RecordNotUnique)
      expect(draft.finalized_at).to be_nil
      expect(draft.sequence).to be_nil
    end

    it "stamps the column at create under assign: :create" do
      auto = Class.new(TestModel) do
        self.table_name = "pc_invoices"
        include ConcernsOnRails::Models::Sequenceable

        sequenceable_by :sequence, into: :number, prefix: "INV-", reset: :year, time_zone: "UTC",
                                   period_column: :finalized_at
      end
      invoice = travel_to(Time.utc(2026, 3, 1, 8)) { auto.create! }

      expect(invoice.finalized_at).to eq(Time.utc(2026, 3, 1, 8))
      expect(invoice.number).to eq("INV-2026-1")
    end
  end

  describe "macro validation" do
    it "refuses a period column the table lacks" do
      expect { build_class(period_column: :settled_at) }.to raise_error(ArgumentError, /settled_at/)
    end

    it "refuses a non-datetime period column" do
      expect { build_class(period_column: :number) }.to raise_error(ArgumentError, /number/)
    end

    it "refuses updated_at, which Rails rewrites on every save" do
      expect { build_class(period_column: :updated_at) }.to raise_error(ArgumentError, /updated_at/)
    end

    it "does not need the column when reset: is :never" do
      expect do
        Class.new(TestModel) do
          self.table_name = "pc_invoices"
          include ConcernsOnRails::Models::Sequenceable

          sequenceable_by :sequence, period_column: :settled_at
        end
      end.not_to raise_error
    end
  end

  describe "re-declaration" do
    it "lets a manual Draft that re-declares only assign: keep the parent's period_column and counter" do
      parent = Class.new(TestModel) do
        self.table_name = "pc_invoices"
        include ConcernsOnRails::Models::Sequenceable

        sequenceable_by :sequence, into: :number, prefix: "INV-", reset: :year, time_zone: "UTC",
                                   period_column: :finalized_at
      end
      stub_const("PcInvoice", parent)
      draft_class = Class.new(parent) { sequenceable_by :sequence, assign: :manual }

      config = draft_class.sequenceable_config[:sequence]
      expect(config).to include(period_column: :finalized_at, assign: :manual, owner: parent)
    end

    # Review of SCOPE-5: a different period_column under an otherwise identical
    # visible format would be its own owner (MAX over its own type-filtered
    # rows) and print the parent's numbers again (INV-2026-1 twice).
    it "refuses a re-declaration that restates the parent's visible format with a different period_column" do
      parent = Class.new(TestModel) do
        self.table_name = "pc_invoices"
        include ConcernsOnRails::Models::Sequenceable

        sequenceable_by :sequence, into: :number, prefix: "INV-", reset: :year, time_zone: "UTC"
      end
      stub_const("PcInvoice", parent)

      expect do
        Class.new(parent) do
          sequenceable_by :sequence, into: :number, prefix: "INV-", reset: :year, time_zone: "UTC",
                                     assign: :manual, period_column: :finalized_at
        end
      end.to raise_error(ArgumentError, /period_column.*finalized_at.*created_at|created_at.*finalized_at/m)
    end

    it "refuses the reverse too (the parent anchors on a stamp, the subclass restates on created_at)" do
      parent = build_class(period_column: :finalized_at)
      stub_const("PcInvoice", parent)

      expect do
        Class.new(parent) do
          sequenceable_by :sequence, into: :number, prefix: "INV-", reset: :year, time_zone: "UTC"
        end
      end.to raise_error(ArgumentError, /period_column/)
    end

    it "refuses it past an intermediate subclass that numbers its own series" do
      parent = build_class
      stub_const("PcInvoice", parent)
      middle = Class.new(parent) { sequenceable_by :sequence, prefix: "CN-" }
      stub_const("PcCredit", middle)

      expect do
        Class.new(middle) do
          sequenceable_by :sequence, into: :number, prefix: "INV-", reset: :year, time_zone: "UTC",
                                     assign: :manual, period_column: :finalized_at
        end
      end.to raise_error(ArgumentError, /period_column/)
    end

    it "lets a different period_column start its own series when the visible format differs" do
      parent = build_class(period_column: :finalized_at)
      stub_const("PcInvoice", parent)
      sibling = Class.new(parent) do
        sequenceable_by :sequence, into: :number, prefix: "CN-", reset: :year, time_zone: "UTC"
      end

      expect(sibling.sequenceable_config[:sequence]).to include(period_column: :created_at, owner: sibling)
    end

    it "does not refuse a different period_column under reset: :never, and keeps the shared counter" do
      parent = Class.new(TestModel) do
        self.table_name = "pc_invoices"
        include ConcernsOnRails::Models::Sequenceable

        sequenceable_by :sequence, into: :number, prefix: "INV-"
      end
      stub_const("PcInvoice", parent)
      child = Class.new(parent) do
        sequenceable_by :sequence, into: :number, prefix: "INV-", period_column: :finalized_at
      end

      expect(child.sequenceable_config[:sequence][:owner]).to eq(parent)
    end

    it "restates the format (period_column back to created_at) on a call without it" do
      parent = build_class(period_column: :finalized_at)
      stub_const("PcInvoice", parent)
      other = Class.new(parent) { sequenceable_by :sequence, prefix: "CN-" }

      expect(other.sequenceable_config[:sequence][:period_column]).to eq(:created_at)
    end
  end

  # Review of SCOPE-5, MEDIUM-2: rows numbered BEFORE the switch have a NULL
  # period column; they must keep counting by their created_at.
  describe "switching an existing series to a period_column" do
    def legacy_class(**options)
      Class.new(TestModel) do
        self.table_name = "pc_invoices"
        include ConcernsOnRails::Models::Sequenceable

        sequenceable_by :sequence, prefix: "INV-", reset: :year, time_zone: "UTC", **options
      end
    end

    it "counts rows numbered before the switch (NULL period column) by their created_at" do
      legacy = legacy_class
      travel_to(Time.utc(2025, 6, 1)) { legacy.create! }
      travel_to(Time.utc(2026, 2, 1)) { legacy.create! }

      switched = legacy_class(assign: :manual, period_column: :finalized_at)
      draft = travel_to(Time.utc(2026, 3, 1)) { switched.create! }
      travel_to(Time.utc(2026, 3, 2)) { draft.assign_sequence! }

      expect(draft.sequence).to eq(2)
      expect(draft.formatted_sequence).to eq("INV-2026-2")
    end

    it "counts them too under a template:" do
      legacy = legacy_class(template: ->(seq, _record) { "N#{seq}" })
      travel_to(Time.utc(2026, 2, 1)) { legacy.create! }

      switched = legacy_class(template: legacy.sequenceable_config[:sequence][:template],
                              assign: :manual, period_column: :finalized_at)
      draft = travel_to(Time.utc(2026, 3, 1)) { switched.create! }
      travel_to(Time.utc(2026, 3, 2)) { draft.assign_sequence! }

      expect(draft.sequence).to eq(2)
    end

    it "does not count a pre-switch row of an earlier period, nor an unnumbered draft" do
      legacy = legacy_class
      travel_to(Time.utc(2025, 6, 1)) { legacy.create! }

      switched = legacy_class(assign: :manual, period_column: :finalized_at)
      travel_to(Time.utc(2026, 2, 1)) { switched.create! } # a draft: no number, NULL stamp
      draft = travel_to(Time.utc(2026, 3, 1)) { switched.create! }
      travel_to(Time.utc(2026, 3, 2)) { draft.assign_sequence! }

      expect(draft.sequence).to eq(1)
    end

    it "keeps counting by the stamp where one is set (a row created in 2025, finalized in 2026)" do
      switched = legacy_class(assign: :manual, period_column: :finalized_at)
      early = travel_to(Time.utc(2025, 12, 20)) { switched.create! }
      travel_to(Time.utc(2026, 1, 3)) { early.assign_sequence! }
      late = travel_to(Time.utc(2026, 1, 4)) { switched.create! }
      travel_to(Time.utc(2026, 1, 5)) { late.assign_sequence! }

      expect([early.sequence, late.sequence]).to eq([1, 2])
    end

    it "works on a table without created_at" do
      ActiveRecord::Schema.define do
        create_table :pc_stamped, force: true do |t|
          t.integer :sequence
          t.datetime :finalized_at
        end
      end
      klass = Class.new(TestModel) do
        self.table_name = "pc_stamped"
        include ConcernsOnRails::Models::Sequenceable

        sequenceable_by :sequence, reset: :year, time_zone: "UTC", assign: :manual, period_column: :finalized_at
      end
      first = travel_to(Time.utc(2026, 1, 3)) { klass.create!.tap(&:assign_sequence!) }
      second = travel_to(Time.utc(2026, 1, 4)) { klass.create!.tap(&:assign_sequence!) }

      expect([first.sequence, second.sequence]).to eq([1, 2])
    ensure
      ActiveRecord::Base.connection.drop_table(:pc_stamped, if_exists: true)
    end
  end

  # Review of SCOPE-5, LOW-1: a date column is stamped in the field's fixed
  # zone, never the request's Time.zone.
  describe "a date period column" do
    let(:klass) do
      Class.new(TestModel) do
        self.table_name = "pc_invoices"
        include ConcernsOnRails::Models::Sequenceable

        sequenceable_by :sequence, into: :number, prefix: "INV-", reset: :year, assign: :manual,
                                   time_zone: "UTC", period_column: :finalized_on
      end
    end

    it "stamps the date in the field's zone even while a request zone is active" do
      draft = travel_to(Time.utc(2025, 12, 20)) { klass.create! }

      # 2025-12-31 20:00 UTC is already 2026-01-01 in Auckland
      travel_to(Time.utc(2025, 12, 31, 20)) do
        Time.use_zone("Auckland") { draft.assign_sequence! }
      end

      expect(draft.reload.finalized_on).to eq(Date.new(2025, 12, 31))
      expect(draft.number).to eq("INV-2025-1")
    end

    it "keeps the same period on the next number (the stored date is found in the range)" do
      first = travel_to(Time.utc(2025, 12, 20)) { klass.create! }
      travel_to(Time.utc(2025, 12, 31, 20)) { Time.use_zone("Auckland") { first.assign_sequence! } }
      second = travel_to(Time.utc(2025, 12, 31, 21)) { klass.create! }
      travel_to(Time.utc(2025, 12, 31, 21)) { second.assign_sequence! }

      expect(second.number).to eq("INV-2025-2")
    end
  end

  # Review of SCOPE-5, LOW-2: the type allow-list is for a CUSTOM column; the
  # default created_at keeps whatever the adapter reports.
  describe "the default created_at column" do
    it "is not held to the period-column type allow-list" do
      expect do
        Class.new(TestModel) do
          self.table_name = "pc_invoices"
          include ConcernsOnRails::Models::Sequenceable

          # an adapter reporting its own name for the timestamp type
          def self.columns_hash
            column = Class.new(SimpleDelegator) { def type = :datetimeoffset }.new(super["created_at"])
            super.merge("created_at" => column)
          end

          sequenceable_by :sequence, prefix: "INV-", reset: :year, time_zone: "UTC"
        end
      end.not_to raise_error
    end

    it "still refuses a custom column of an unlisted type" do
      expect { build_class(period_column: :number) }.to raise_error(ArgumentError, /string column/)
    end
  end

  # Review of SCOPE-5, LOW-3: the memoized "now" must not outlive a failed
  # assign_<field>!, or a retry after midnight reuses the old instant.
  describe "a retried assign_<field>! after a failed save" do
    it "reads a fresh clock instead of the instant memoized by the failed attempt" do
      klass = build_class(period_column: :finalized_at)
      draft = travel_to(Time.utc(2025, 12, 20)) { klass.create! }
      calls = 0
      allow(draft).to receive(:save!).and_wrap_original do |original, *args|
        calls += 1
        raise ActiveRecord::RecordNotUnique if calls == 1

        original.call(*args)
      end

      travel_to(Time.utc(2025, 12, 31, 23, 59)) do
        expect { draft.assign_sequence! }.to raise_error(ActiveRecord::RecordNotUnique)
      end
      travel_to(Time.utc(2026, 1, 1, 0, 1)) { draft.assign_sequence! }

      expect(draft.number).to eq("INV-2026-1")
      expect(draft.reload.finalized_at).to eq(Time.utc(2026, 1, 1, 0, 1))
    end
  end

  describe "Duplicable" do
    it "numbers a copy in its own period under the default created_at anchor too" do
      klass = Class.new(TestModel) do
        self.table_name = "pc_invoices"
        include ConcernsOnRails::Models::Sequenceable
        include ConcernsOnRails::Models::Duplicable

        sequenceable_by :sequence, into: :number, prefix: "INV-", reset: :year, time_zone: "UTC"
      end
      original = travel_to(Time.utc(2025, 6, 1)) { klass.create! }
      copy = travel_to(Time.utc(2026, 2, 1)) { original.duplicate! }

      expect(copy.number).to eq("INV-2026-1")
    end

    it "blanks the period column on a copy so the copy is numbered in its own period" do
      klass = Class.new(TestModel) do
        self.table_name = "pc_invoices"
        include ConcernsOnRails::Models::Sequenceable
        include ConcernsOnRails::Models::Duplicable

        sequenceable_by :sequence, into: :number, prefix: "INV-", reset: :year, time_zone: "UTC",
                                   period_column: :finalized_at
      end
      original = travel_to(Time.utc(2025, 6, 1)) { klass.create! }
      copy = travel_to(Time.utc(2026, 2, 1)) { original.duplicate! }

      expect(copy.finalized_at).to eq(Time.utc(2026, 2, 1))
      expect(copy.number).to eq("INV-2026-1")
    end
  end
end
