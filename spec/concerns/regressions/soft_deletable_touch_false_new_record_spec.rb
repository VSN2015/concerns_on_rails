require "spec_helper"

describe "SoftDeletable touch: false on a NEW record" do
  before do
    ActiveRecord::Schema.define do
      create_table :c_sd_new, force: true do |t|
        t.string :name
        t.datetime :deleted_at
        t.timestamps
      end
    end
  end
  after { ActiveRecord::Base.connection.drop_table(:c_sd_new) }

  let(:klass) do
    Class.new(TestModel) do
      self.table_name = "c_sd_new"
      include ConcernsOnRails::SoftDeletable

      soft_deletable_by :deleted_at, touch: false
    end
  end

  it "soft_delete! transitions a new record (as with touch: true) instead of raising" do
    record = klass.new(name: "x")
    expect(record.soft_delete!).to be(true)
    expect(klass.unscoped.find(record.id).deleted_at).to be_present
  end

  it "restore! transitions a new record too" do
    record = klass.new(name: "x", deleted_at: Time.current)
    expect(record.restore!).to be(true)
    expect(klass.unscoped.find(record.id).deleted_at).to be_nil
  end

  it "still writes a stored record without touching updated_at" do
    record = klass.create!(name: "x")
    before = record.reload.updated_at
    record.soft_delete!
    expect(record.reload.updated_at).to eq(before)
    expect(record.deleted_at).to be_present
  end
end
