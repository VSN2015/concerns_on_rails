require "spec_helper"

describe ConcernsOnRails::Support::HookedWrite do
  before do
    ActiveRecord::Schema.define do
      create_table :hooked_items, force: true do |t|
        t.string :state
        t.string :note
      end
    end

    stub_const("HookedItem", Class.new(TestModel) do
      self.table_name = "hooked_items"

      attr_reader :log

      cattr_accessor :after_action

      private

      def before_write
        (@log ||= []) << :before
        self.class.where(id: id).update_all(note: "before-hook")
      end

      def after_write
        (@log ||= []) << :after
        action = self.class.after_action
        raise ActiveRecord::Rollback if action == :rollback
        raise "boom" if action == :raise
      end
    end)
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  def run(item, **options, &write)
    described_class.run(item, before: :before_write, after: :after_write, restore: [:state], **options, &write)
  end

  let(:item) { HookedItem.create!(state: "old") }

  it "runs before, write, after (private hooks included) and returns true" do
    expect(run(item) { item.update(state: "new") }).to be(true)
    expect(item.log).to eq(%i[before after])
    expect(item.reload.state).to eq("new")
  end

  it "returns false, skips the after hook and rolls the before hook back when the write is falsey" do
    expect(run(item) { false }).to be(false)
    expect(item.log).to eq(%i[before])
    expect(item.reload.note).to be_nil
  end

  it "returns false and rolls everything back when the after hook raises ActiveRecord::Rollback" do
    HookedItem.after_action = :rollback

    expect(run(item) { item.update_column(:state, "new") }).to be(false)
    expect(item.state).to eq("old")
    expect(item.reload.state).to eq("old")
    expect(item.note).to be_nil
  end

  it "honors the Rollback inside a caller's transaction without touching the caller's writes" do
    HookedItem.after_action = :rollback
    other = HookedItem.create!(state: "x")

    result = nil
    ActiveRecord::Base.transaction do
      other.update!(state: "y")
      result = run(item) { item.update(state: "new") }
    end

    expect(result).to be(false)
    expect(other.reload.state).to eq("y")
    expect(item.reload.state).to eq("old")
  end

  it "propagates an exception, rolls back, and restores the in-memory value" do
    HookedItem.after_action = :raise

    expect { run(item) { item.update_column(:state, "new") } }.to raise_error("boom")
    expect(item.state).to eq("old")
    expect(item.changed?).to be(false)
    expect(item.reload.state).to eq("old")
  end

  it "restores an attribute that was already dirty as dirty against its database value" do
    HookedItem.after_action = :rollback
    item.state = "unsaved"

    run(item) { item.update_column(:state, "new") }

    expect(item.state).to eq("unsaved")
    expect(item.state_in_database).to eq("old")
    expect(item.state_changed?).to be(true)
  end

  it "skips a hook passed as nil" do
    expect(described_class.run(item, restore: [:state]) { item.update(state: "new") }).to be(true)
    expect(item.log).to be_nil
  end
end
