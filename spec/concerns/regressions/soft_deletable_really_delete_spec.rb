require "spec_helper"

# Audit 2026-10-10 (STATE-3): really_delete! removed the row but left the
# instance persisted? and not destroyed? (only frozen), so code branching on
# them (respond_with, turbo-stream removal) treated a hard-deleted record as
# live. It now marks the instance destroyed the way ActiveRecord's own
# `delete` does.
describe "SoftDeletable#really_delete! instance state" do
  before do
    ActiveRecord::Schema.define do
      create_table :srd_posts, force: true do |t|
        t.string :title
        t.datetime :deleted_at
      end
    end
  end

  after do
    ActiveRecord::Base.connection.drop_table(:srd_posts, if_exists: true)
  end

  let(:model) do
    Class.new(TestModel) do
      self.table_name = "srd_posts"
      include ConcernsOnRails::SoftDeletable
    end
  end

  it "marks the instance destroyed and no longer persisted, as delete does" do
    post = model.create!(title: "a")

    post.really_delete!

    expect(post).to be_destroyed
    expect(post).not_to be_persisted
    expect(post).to be_frozen
    expect(post).to be_is_really_deleted
    expect(model.unscoped.count).to eq(0)
  end

  it "does the same for an already soft-deleted record" do
    post = model.create!(title: "a")
    post.soft_delete!

    post.really_delete!

    expect(post).to be_destroyed
    expect(post).not_to be_persisted
    expect(model.unscoped.count).to eq(0)
  end

  it "reports previously_persisted? like a deleted record", min_rails: "6.1" do
    post = model.create!(title: "a")

    post.really_delete!

    expect(post).to be_previously_persisted
    expect(post).not_to be_previously_new_record
  end

  it "deletes only its own row" do
    keep = model.create!(title: "keep")
    model.create!(title: "gone").really_delete!

    expect(model.unscoped.pluck(:id)).to eq([keep.id])
  end
end
