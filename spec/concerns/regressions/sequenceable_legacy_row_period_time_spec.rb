require "spec_helper"

# GRAPH-1: after switching a series to a custom period_column:, a row numbered before the
# switch carries NULL there. The MAX range already counted it by its created_at; its
# display (formatted_<field>, sequenceable_period_time) fell back to TODAY, so two rows
# printed the same number.
RSpec.describe "Sequenceable: a pre-switch row's period" do
  before do
    ActiveRecord::Schema.define do
      create_table :lr_invoices, force: true do |t|
        t.integer :sequence
        t.datetime :finalized_at
        t.timestamps null: true
      end
    end
  end

  after { ActiveRecord::Base.connection.drop_table(:lr_invoices, if_exists: true) }

  def klass(**options)
    Class.new(TestModel) do
      self.table_name = "lr_invoices"
      include ConcernsOnRails::Models::Sequenceable

      sequenceable_by :sequence, prefix: "INV-", reset: :year, time_zone: "UTC", **options
    end
  end

  let(:legacy) { klass }
  let!(:old_row) { travel_to(Time.utc(2025, 6, 1)) { legacy.create! } }
  let!(:new_row) { travel_to(Time.utc(2026, 2, 1)) { legacy.create! } }
  let(:switched) { klass(assign: :manual, period_column: :finalized_at) }

  it "formats each pre-switch row in its created_at period" do
    displays = travel_to(Time.utc(2026, 3, 1)) do
      [switched.find(old_row.id).formatted_sequence, switched.find(new_row.id).formatted_sequence]
    end
    expect(displays).to eq(%w[INV-2025-1 INV-2026-1])
  end

  it "reports the created_at instant as sequenceable_period_time" do
    time = travel_to(Time.utc(2026, 3, 1)) { switched.find(old_row.id).sequenceable_period_time(:sequence) }
    expect(time.year).to eq(2025)
  end

  it "still anchors a stamped row to its period column" do
    stamped = travel_to(Time.utc(2026, 3, 1)) do
      row = switched.create!
      row.assign_sequence!
      row
    end
    travel_to(Time.utc(2027, 1, 1)) do
      expect(switched.find(stamped.id).formatted_sequence).to eq("INV-2026-2")
    end
  end

  it "anchors an unnumbered draft (NULL stamp, no number) to now, so assigning draws from today's period" do
    draft = travel_to(Time.utc(2026, 3, 1)) { switched.create! }
    travel_to(Time.utc(2027, 1, 5)) do
      draft.assign_sequence!
      expect(draft.sequence).to eq(1)
      expect(draft.formatted_sequence).to eq("INV-2027-1")
    end
  end
end
