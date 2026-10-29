require "spec_helper"

# Regression (audit 2026-10-29, STATE-8): transition_all let ActiveRecord::RecordInvalid escape
# when a record failed validation, while every other *_all verb raises RecordNotSaved (the batch
# contract) — a caller's `rescue ActiveRecord::RecordNotSaved` missed it. The rollback itself
# already happened.
RSpec.describe "Stateable transition_all with a record that fails validation" do
  before do
    ActiveRecord::Schema.define do
      create_table :tai_tickets, force: true do |t|
        t.string :title
        t.string :status
      end
    end
  end

  after { ActiveRecord::Base.connection.drop_table(:tai_tickets, if_exists: true) }

  def model(lock: false)
    Class.new(TestModel) do
      self.table_name = "tai_tickets"
      include ConcernsOnRails::Models::Stateable

      stateable_by :status, states: %i[draft done], default: :draft, lock: lock,
                            transitions: { finish: { from: :draft, to: :done } }
      validates :title, presence: true, if: -> { status == "done" }
    end
  end

  [false, true].each do |lock|
    context "with lock: #{lock}" do
      it "raises RecordNotSaved carrying the record, and rolls the whole batch back" do
        klass = model(lock: lock)
        klass.create!(title: "x")
        bad = klass.create!(title: nil)

        expect { klass.transition_all(:finish) }.to raise_error(ActiveRecord::RecordNotSaved) { |error|
          expect(error.record.id).to eq(bad.id)
          expect(error.record.errors[:title]).to be_present
        }
        expect(klass.pluck(:status)).to all(eq("draft"))
      end

      it "still raises RecordInvalid from the single <event>!" do
        klass = model(lock: lock)
        bad = klass.create!(title: nil)

        expect { bad.finish! }.to raise_error(ActiveRecord::RecordInvalid)
        expect(bad.reload.status).to eq("draft")
      end
    end
  end

  it "lets another record's failed save inside a hook propagate as its own RecordInvalid" do
    klass = model
    ticket = klass.create!(title: "x")
    other = klass.create!(title: nil)
    klass.class_eval do
      attr_accessor :sibling

      def after_finish
        sibling&.update!(status: "done") # fails: the sibling has no title
      end
    end
    allow_any_instance_of(klass).to receive(:sibling) { |record| record.id == ticket.id ? other : nil }

    expect { klass.where(id: ticket.id).transition_all(:finish) }.to raise_error(ActiveRecord::RecordInvalid) { |error|
      expect(error.record.id).to eq(other.id)
    }
  end

  it "counts every valid record when none fails" do
    klass = model
    2.times { |i| klass.create!(title: "t#{i}") }

    expect(klass.transition_all(:finish)).to eq(2)
  end
end
