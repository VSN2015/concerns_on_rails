require "spec_helper"

# Audit 2026-10-10 (STATE-7): a base-class transition_all on an STI table
# chose its rows and its guard method from the BASE class's declaration,
# though each subclass may re-declare stateable_by:
#   * a subclass that dropped the event left its `may_<event>?` behind a
#     private stub, so public_send raised NoMethodError and the whole batch
#     aborted (rows the guard rejects are meant to be skipped);
#   * a subclass that widened `from:` had its eligible rows filtered out by
#     the base's `from:` in SQL, so they were silently skipped.
# Each record is now judged by its own class's declaration.
describe "Stateable transition_all across an STI hierarchy" do
  before do
    ActiveRecord::Schema.define do
      create_table :sts_articles, force: true do |t|
        t.string :type
        t.string :status
        t.string :title
      end
    end

    stub_const("StsArticle", Class.new(TestModel) do
      self.table_name = "sts_articles"
      include ConcernsOnRails::Stateable

      stateable_by :status, states: %i[pending review live archived], default: :pending,
                            transitions: { go_live: { from: :pending, to: :live }, archive: { to: :archived } }
    end)
  end

  after do
    ActiveRecord::Base.connection.drop_table(:sts_articles, if_exists: true)
  end

  it "skips the rows of a subclass that no longer declares the event" do
    stub_const("StsPress", Class.new(StsArticle) do
      stateable_by :status, states: %i[pending archived], transitions: { archive: { to: :archived } }
    end)
    base = StsArticle.create!
    press = StsPress.create!

    expect(StsArticle.transition_all(:go_live)).to eq(1)
    expect(base.reload.status).to eq("live")
    expect(press.reload.status).to eq("pending")
  end

  it "moves a subclass row its own wider guard accepts" do
    stub_const("StsWide", Class.new(StsArticle) do
      stateable_by :status, states: %i[pending review live archived],
                            transitions: { go_live: { from: %i[pending review], to: :live } }
    end)
    row = StsWide.create!(status: "review")
    base_in_review = StsArticle.create!(status: "review")
    expect(row.may_go_live?).to be(true)

    expect(StsArticle.transition_all(:go_live)).to eq(1)
    expect(row.reload.status).to eq("live")
    expect(base_in_review.reload.status).to eq("review") # the base's own guard still rejects it
  end

  it "honours a subclass's own target state and keeps the batch idempotent" do
    stub_const("StsArchiver", Class.new(StsArticle) do
      stateable_by :status, states: %i[pending review live archived],
                            transitions: { go_live: { from: %i[pending live], to: :archived } }
    end)
    archiver = StsArchiver.create!
    already = StsArchiver.create!(status: "archived")
    base_live = StsArticle.create!(status: "live")

    expect(StsArticle.transition_all(:go_live)).to eq(1)
    expect(archiver.reload.status).to eq("archived")
    expect(already.reload.status).to eq("archived")
    expect(base_live.reload.status).to eq("live") # already the base's target: skipped
    expect(StsArticle.transition_all(:go_live)).to eq(0)
  end

  it "still filters by from:/to: in SQL and counts every row on a uniform hierarchy" do
    stub_const("StsNote", Class.new(StsArticle))
    StsArticle.create!
    StsNote.create!
    StsNote.create!(status: "live")
    StsArticle.create!(status: "archived")

    expect(StsArticle.transition_all(:go_live)).to eq(2)
    expect(StsArticle.where(status: "live").count).to eq(3)
  end

  it "still raises for an event the receiving class does not declare" do
    stub_const("StsPress", Class.new(StsArticle) do
      stateable_by :status, states: %i[pending archived], transitions: { archive: { to: :archived } }
    end)

    expect { StsPress.transition_all(:go_live) }.to raise_error(ArgumentError, /unknown transition/)
  end
end
