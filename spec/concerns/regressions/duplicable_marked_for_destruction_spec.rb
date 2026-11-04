# Regression (audit 2026-10-29, GRAPH-6): Duplicable keeps an already-loaded association's
# in-memory edits, but ignored the one removal edit — a child (or has_one target) marked
# for destruction (nested attributes `_destroy`, `mark_for_destruction`) was copied as a
# live child in a "save as copy" flow.
RSpec.describe "Duplicable and children marked for destruction" do
  before do
    ActiveRecord::Schema.define do
      create_table :mfd_lists, force: true do |t|
        t.string :name
      end
      create_table :mfd_entries, force: true do |t|
        t.integer :mfd_list_id
        t.string :body
        t.datetime :deleted_at
      end
      create_table :mfd_covers, force: true do |t|
        t.integer :mfd_list_id
        t.string :body
      end
    end
    stub_const("MfdEntry", Class.new(TestModel) { self.table_name = "mfd_entries" })
    stub_const("MfdCover", Class.new(TestModel) { self.table_name = "mfd_covers" })
    stub_const("MfdList", Class.new(TestModel) do
      self.table_name = "mfd_lists"
      include ConcernsOnRails::Models::Duplicable

      has_many :mfd_entries, class_name: "MfdEntry", foreign_key: :mfd_list_id
      has_one :mfd_cover, class_name: "MfdCover", foreign_key: :mfd_list_id
      accepts_nested_attributes_for :mfd_entries, :mfd_cover, allow_destroy: true
      duplicable_by associations: %i[mfd_entries mfd_cover]
    end)
  end

  after { %w[mfd_lists mfd_entries mfd_covers].each { |t| ActiveRecord::Base.connection.drop_table(t, if_exists: true) } }

  let(:list) do
    MfdList.create!(name: "l").tap do |l|
      l.mfd_entries.create!(body: "keep")
      l.mfd_entries.create!(body: "drop")
      l.mfd_cover = MfdCover.create!(body: "cover")
    end
  end

  def entry(body)
    list.mfd_entries.find { |e| e.body == body }
  end

  it "leaves out a child marked via nested attributes _destroy" do
    drop_id = entry("drop").id
    list.reload # the association is NOT loaded: nested attributes pull in only the addressed row
    list.assign_attributes(mfd_entries_attributes: [{ id: drop_id, _destroy: "1" }])
    expect(list.mfd_entries).not_to be_loaded
    expect(list.duplicate!.mfd_entries.map(&:body)).to eq(["keep"])
  end

  it "leaves out a child marked via _destroy on an already-loaded association" do
    list.mfd_entries.load
    list.assign_attributes(mfd_entries_attributes: [{ id: entry("drop").id, _destroy: "1" }])
    expect(list.duplicate!.mfd_entries.map(&:body)).to eq(["keep"])
  end

  it "leaves out a loaded child marked with mark_for_destruction" do
    entry("drop").mark_for_destruction
    expect(list.duplicate!.mfd_entries.map(&:body)).to eq(["keep"])
  end

  it "leaves out an unsaved child marked for destruction on a new owner" do
    fresh = MfdList.new(name: "n")
    fresh.mfd_entries.build(body: "a")
    fresh.mfd_entries.build(body: "b").mark_for_destruction
    expect(fresh.duplicate.mfd_entries.map(&:body)).to eq(["a"])
  end

  it "leaves out a has_one target marked for destruction" do
    list.reload
    list.mfd_cover.mark_for_destruction
    expect(list.duplicate!.mfd_cover).to be_nil
  end

  it "still copies unmarked children and an unmarked has_one" do
    list.reload
    copy = list.duplicate!
    expect(copy.mfd_entries.map(&:body)).to match_array(%w[keep drop])
    expect(copy.mfd_cover.body).to eq("cover")
  end

  it "still copies everything from a freshly loaded (not edited) owner whose child model hides rows" do
    stub_const("MfdEntry", Class.new(TestModel) do
      self.table_name = "mfd_entries"
      include ConcernsOnRails::Models::SoftDeletable
    end)
    list
    reloaded = MfdList.find(list.id)
    reloaded.mfd_entries.load
    reloaded.mfd_entries.find { |e| e.body == "drop" }.mark_for_destruction
    expect(reloaded.duplicate!.mfd_entries.map(&:body)).to eq(["keep"])
  end
end
