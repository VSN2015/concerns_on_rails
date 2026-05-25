require "spec_helper"

describe ConcernsOnRails::Stateable do
  before do
    ActiveRecord::Schema.define do
      create_table :tickets, force: true do |t|
        t.string :title
        t.string :status
      end
    end

    class Ticket < TestModel
      include ConcernsOnRails::Stateable

      stateable_by :status,
                   states: %i[draft pending published archived],
                   default: :draft,
                   transitions: {
                     publish: { from: %i[draft pending], to: :published },
                     archive: { to: :archived } # no :from => allowed from any state
                   }
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  describe "default" do
    it "applies the default state to new records" do
      expect(Ticket.new.status).to eq("draft")
    end

    it "persists the default on create" do
      expect(Ticket.create!(title: "t").status).to eq("draft")
    end

    it "does not override an explicitly provided state" do
      expect(Ticket.new(status: "published").status).to eq("published")
    end
  end

  describe "predicates" do
    it "reflects the current state" do
      ticket = Ticket.new(status: "pending")
      expect(ticket.pending?).to be true
      expect(ticket.draft?).to be false
      expect(ticket.published?).to be false
    end
  end

  describe "scopes" do
    it "filters by state" do
      draft = Ticket.create!(title: "d", status: "draft")
      published = Ticket.create!(title: "p", status: "published")

      expect(Ticket.draft).to eq([draft])
      expect(Ticket.published).to eq([published])
    end
  end

  describe "direct setters (unguarded)" do
    it "moves to the state regardless of current state" do
      ticket = Ticket.create!(title: "t", status: "archived")
      ticket.published!
      expect(ticket.reload.status).to eq("published")
    end
  end

  describe "guarded transitions" do
    it "performs an allowed transition" do
      ticket = Ticket.create!(title: "t", status: "draft")
      ticket.publish!
      expect(ticket.reload.status).to eq("published")
    end

    it "raises InvalidTransition from a disallowed state" do
      ticket = Ticket.create!(title: "t", status: "published")
      expect { ticket.publish! }.to raise_error(ConcernsOnRails::Stateable::InvalidTransition)
      expect(ticket.reload.status).to eq("published")
    end

    it "allows a transition with no :from from any state" do
      ticket = Ticket.create!(title: "t", status: "published")
      ticket.archive!
      expect(ticket.reload.status).to eq("archived")
    end

    it "exposes may_<event>? guards" do
      expect(Ticket.new(status: "draft").may_publish?).to be true
      expect(Ticket.new(status: "published").may_publish?).to be false
      expect(Ticket.new(status: "published").may_archive?).to be true
    end
  end

  describe "#transition_to!" do
    it "moves to any declared state" do
      ticket = Ticket.create!(title: "t")
      ticket.transition_to!(:archived)
      expect(ticket.reload.status).to eq("archived")
    end

    it "raises for an unknown state" do
      ticket = Ticket.create!(title: "t")
      expect { ticket.transition_to!(:nope) }.to raise_error(ConcernsOnRails::Stateable::InvalidTransition)
    end
  end

  describe "prefix / suffix" do
    before do
      ActiveRecord::Schema.define do
        create_table :shipments, force: true do |t|
          t.string :state
        end
      end

      class Shipment < TestModel
        include ConcernsOnRails::Stateable

        stateable_by :state, states: %i[open closed], default: :open, prefix: true
      end
    end

    it "prefixes generated method and scope names with the field name" do
      shipment = Shipment.create!
      expect(shipment.state_open?).to be true
      expect(Shipment.state_open).to eq([shipment])
      shipment.state_closed!
      expect(shipment.reload.state).to eq("closed")
    end
  end

  describe "validation" do
    def define_model(table, &block)
      ActiveRecord::Schema.define do
        create_table(table, force: true) { |t| t.string :status }
      end
      Class.new(TestModel) do
        self.table_name = table.to_s
        include ConcernsOnRails::Stateable

        instance_eval(&block)
      end
    end

    it "raises when the column does not exist" do
      ActiveRecord::Schema.define { create_table(:no_cols, force: true) { |t| t.string :name } }
      expect do
        Class.new(TestModel) do
          self.table_name = "no_cols"
          include ConcernsOnRails::Stateable

          stateable_by :status, states: %i[a b]
        end
      end.to raise_error(ArgumentError, /does not exist/)
    end

    it "raises when states are empty" do
      expect { define_model(:empties) { stateable_by :status, states: [] } }
        .to raise_error(ArgumentError, /states: cannot be empty/)
    end

    it "raises when the default is not a declared state" do
      expect { define_model(:bad_defaults) { stateable_by :status, states: %i[a b], default: :c } }
        .to raise_error(ArgumentError, /default 'c' is not a declared state/)
    end

    it "raises when a transition omits :to" do
      expect { define_model(:no_tos) { stateable_by :status, states: %i[a b], transitions: { go: { from: :a } } } }
        .to raise_error(ArgumentError, /must declare :to/)
    end

    it "raises when a transition references an unknown state" do
      expect { define_model(:unknowns) { stateable_by :status, states: %i[a b], transitions: { go: { to: :z } } } }
        .to raise_error(ArgumentError, /references unknown states/)
    end

    it "raises when a transition name clashes with a state setter" do
      expect do
        define_model(:clashers) do
          stateable_by :status, states: %i[draft published], transitions: { published: { to: :published } }
        end
      end.to raise_error(ArgumentError, /clashes with the same-named state setter/)
    end
  end
end
