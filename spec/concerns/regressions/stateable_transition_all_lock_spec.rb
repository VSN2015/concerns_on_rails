require "spec_helper"

# Audit 2026-10-10 (STATE-11): on a `lock: true` model, transition_all
# loaded the rows, passed each record's in-memory guard, and then
# <event>! locked the row, re-checked the guard against the row's state and
# raised InvalidTransition when another process had moved it in between.
# The batch's savepoint then rolled back EVERY row already transitioned.
# A row the guard rejects is skipped, as the batch contract says; the
# single-record <event>! keeps raising.
describe "Stateable transition_all with lock: true under a concurrent writer" do
  before do
    ActiveRecord::Schema.define do
      create_table :stl_tickets, force: true do |t|
        t.string :status
      end
    end
  end

  after do
    ActiveRecord::Base.connection.drop_table(:stl_tickets, if_exists: true)
  end

  def ticket_model(lock:)
    Class.new(TestModel) do
      self.table_name = "stl_tickets"
      include ConcernsOnRails::Stateable

      cattr_accessor :race_id
      stateable_by :status, states: %i[draft published archived], default: :draft, lock: lock,
                            transitions: { publish: { from: :draft, to: :published } }

      # Simulates a concurrent request archiving one row between find_each's
      # SELECT and the batch reaching that record.
      after_find do
        next unless race_id && id == race_id

        self.class.race_id = nil
        self.class.unscoped.where(id: id).update_all(status: "archived")
      end
    end
  end

  let(:model) { ticket_model(lock: true) }

  it "skips a row another process moved after the batch loaded it, and keeps the rest" do
    raced = model.create!
    other = model.create!
    model.race_id = raced.id

    expect(model.transition_all(:publish)).to eq(1)
    expect(raced.reload.status).to eq("archived")
    expect(other.reload.status).to eq("published")
  end

  it "keeps raising InvalidTransition from a single-record <event>! whose row moved" do
    ticket = model.create!
    model.unscoped.where(id: ticket.id).update_all(status: "archived")

    expect { ticket.publish! }.to raise_error(ConcernsOnRails::Models::Stateable::InvalidTransition)
    expect(ticket.reload.status).to eq("archived")
  end

  it "still transitions every eligible row when nothing races" do
    3.times { model.create! }
    model.create!(status: "archived")

    expect(model.transition_all(:publish)).to eq(3)
    expect(model.where(status: "published").count).to eq(3)
  end

  it "still rolls the whole batch back when a hook raises" do
    failing = Class.new(model) do
      def after_publish
        raise ConcernsOnRails::Models::Stateable::InvalidTransition, "vetoed by a hook"
      end
    end
    2.times { failing.create! }

    expect { failing.transition_all(:publish) }.to raise_error(ConcernsOnRails::Models::Stateable::InvalidTransition, /vetoed/)
    expect(failing.where(status: "published").count).to eq(0)
  end
end
