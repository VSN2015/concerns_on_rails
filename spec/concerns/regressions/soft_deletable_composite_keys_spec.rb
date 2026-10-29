require "spec_helper"

# Audit 2026-10-29 STATE-3: SoftDeletable#really_delete! built
# `where(primary_key => id)` and #is_really_deleted? called `exists?(id)`;
# both raise ArgumentError on a composite primary key (Rails 7.1+). They now
# address the row through Support::PrimaryKey.
describe "SoftDeletable hard-delete helpers on a composite primary key", min_rails: "7.1" do
  before do
    ActiveRecord::Schema.define do
      create_table :sd_cpk_orders, primary_key: %i[shop_id id], force: true do |t|
        t.integer :shop_id
        t.integer :id
        t.datetime :deleted_at
      end
    end
  end

  after(:each) { ActiveRecord::Base.connection.drop_table(:sd_cpk_orders, if_exists: true) }

  let(:model) do
    Class.new(TestModel) do
      self.table_name = "sd_cpk_orders"
      include ConcernsOnRails::Models::SoftDeletable
    end
  end

  it "really_delete! hard-deletes exactly its own row" do
    order = model.create!(id: [1, 1])
    model.create!(id: [1, 2])
    model.create!(id: [2, 1])

    expect { order.really_delete! }.not_to raise_error
    expect(order).to be_destroyed
    expect(model.unscoped.pluck(:shop_id, :id)).to contain_exactly([1, 2], [2, 1])
  end

  it "is_really_deleted? reads the row's presence, live, soft-deleted and gone" do
    order = model.create!(id: [1, 1])
    expect(order.is_really_deleted?).to be(false)

    order.soft_delete!
    expect(order.is_really_deleted?).to be(false)

    model.unscoped.where(shop_id: 1, id: 1).delete_all
    expect(order.is_really_deleted?).to be(true)
  end

  it "the trash purge (soft_delete_purge!) still works" do
    model.create!(id: [1, 1]).soft_delete!
    model.create!(id: [1, 2])

    model.only_deleted.destroy_all
    expect(model.unscoped.pluck(:shop_id, :id)).to eq([[1, 2]])
  end
end

describe "SoftDeletable hard-delete helpers on a simple primary key" do
  before do
    ActiveRecord::Schema.define do
      create_table(:sd_simple_orders, force: true) { |t| t.datetime :deleted_at }
    end
  end

  after(:each) { ActiveRecord::Base.connection.drop_table(:sd_simple_orders, if_exists: true) }

  it "keeps working" do
    model = Class.new(TestModel) do
      self.table_name = "sd_simple_orders"
      include ConcernsOnRails::Models::SoftDeletable
    end
    keep = model.create!
    order = model.create!

    order.really_delete!
    expect(order).to be_destroyed
    expect(model.unscoped.pluck(:id)).to eq([keep.id])
    expect(order.is_really_deleted?).to be(true)
    expect(keep.is_really_deleted?).to be(false)
  end
end
