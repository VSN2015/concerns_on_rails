require "spec_helper"

# GRAPH-1 (audit v1.35.2): an UNLOADED association whose target holds nested-attributes
# records was copied from the DB rows, honouring only `_destroy`.
RSpec.describe "Duplicable with nested-attribute edits on an unloaded association" do
  before do
    ActiveRecord::Schema.define do
      create_table :g1_lists, force: true do |t|
        t.string :name
      end
      create_table :g1_entries, force: true do |t|
        t.integer :g1_list_id
        t.string :body
      end
    end
    stub_const("G1Entry", Class.new(TestModel) { self.table_name = "g1_entries" })
    stub_const("G1List", Class.new(TestModel) do
      self.table_name = "g1_lists"
      include ConcernsOnRails::Models::Duplicable

      has_many :g1_entries, class_name: "G1Entry", foreign_key: :g1_list_id
      accepts_nested_attributes_for :g1_entries, allow_destroy: true
      duplicable_by associations: %i[g1_entries]
    end)
  end

  after { %w[g1_lists g1_entries].each { |t| ActiveRecord::Base.connection.drop_table(t, if_exists: true) } }

  def reload_list(list)
    G1List.find(list.id)
  end

  it "copies a child's unsaved nested-attributes edit (save-as-copy flow)" do
    list = G1List.create!(name: "l")
    a = list.g1_entries.create!(body: "old")
    list = reload_list(list)
    list.assign_attributes(g1_entries_attributes: [{ id: a.id, body: "edited" }])
    expect(list.g1_entries).not_to be_loaded
    expect(list.duplicate!.g1_entries.map(&:body)).to eq(["edited"])
  end

  it "copies a child added through nested attributes" do
    list = G1List.create!(name: "l")
    list.g1_entries.create!(body: "kept")
    list = reload_list(list)
    list.assign_attributes(g1_entries_attributes: [{ body: "added" }])
    expect(list.duplicate!.g1_entries.map(&:body)).to match_array(%w[kept added])
  end

  it "copies a child built with assoc.build" do
    list = G1List.create!(name: "l")
    list.g1_entries.create!(body: "kept")
    list = reload_list(list)
    list.g1_entries.build(body: "built")
    expect(list.duplicate!.g1_entries.map(&:body)).to match_array(%w[kept built])
  end

  it "drops a marked child, keeps an edited sibling and an untouched row" do
    list = G1List.create!(name: "l")
    a = list.g1_entries.create!(body: "a")
    b = list.g1_entries.create!(body: "b")
    list.g1_entries.create!(body: "c")
    list = reload_list(list)
    list.assign_attributes(g1_entries_attributes: [{ id: a.id, _destroy: "1" }, { id: b.id, body: "B" }])
    expect(list.duplicate!.g1_entries.map(&:body)).to match_array(%w[B c])
  end
end
