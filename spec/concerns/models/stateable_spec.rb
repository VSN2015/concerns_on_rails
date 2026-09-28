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

  describe "transition callbacks" do
    it "fires before/after_transition around a guarded transition" do
      ActiveRecord::Schema.define do
        create_table :orders, force: true do |t|
          t.string :status
        end
      end

      klass = Class.new(TestModel) do
        self.table_name = "orders"
        include ConcernsOnRails::Stateable

        stateable_by :status, states: %i[pending shipped], default: :pending,
                              transitions: { ship: { from: :pending, to: :shipped } }

        attr_reader :log

        def before_transition(event, from, to)
          (@log ||= []) << [:before, event, from, to]
        end

        def after_transition(event, from, to)
          (@log ||= []) << [:after, event, from, to]
        end
      end

      order = klass.create!
      order.ship!
      expect(order.log).to eq(
        [[:before, :ship, "pending", "shipped"], [:after, :ship, "pending", "shipped"]]
      )
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

    it "raises on unknown options (1.26)" do
      expect { define_model(:typoed) { stateable_by :status, states: %i[a b], lokc: true } }
        .to raise_error(ArgumentError, /unknown option\(s\): lokc/)
    end
  end

  describe "lock: true (1.26)" do
    let(:klass) do
      ActiveRecord::Schema.define do
        create_table(:locked_orders, force: true) { |t| t.string :status }
      end
      Class.new(TestModel) do
        self.table_name = "locked_orders"
        include ConcernsOnRails::Stateable

        stateable_by :status, states: %i[draft published], default: :draft, lock: true,
                              transitions: { publish: { from: :draft, to: :published } }
      end
    end

    it "still performs a valid transition" do
      record = klass.create!
      expect(record.publish!).to be(true)
      expect(record.reload.status).to eq("published")
    end

    it "re-checks the guard against the fresh row, so a stale copy cannot double-fire" do
      record = klass.create!
      stale = klass.find(record.id)
      record.publish!

      # Without the lock, the stale in-memory 'draft' passes the guard and the
      # event fires twice (hooks and all) — the check-then-write race.
      expect { stale.publish! }
        .to raise_error(ConcernsOnRails::Models::Stateable::InvalidTransition)
    end
  end

  describe "#transition_all" do
    before do
      ActiveRecord::Schema.define do
        create_table :batch_orders, force: true do |t|
          t.string :status
        end
      end

      stub_const("BatchOrder", Class.new(TestModel) do
        self.table_name = "batch_orders"
        include ConcernsOnRails::Stateable

        stateable_by :status,
                     states: %i[draft submitted approved],
                     default: :draft,
                     transitions: {
                       submit: { from: :draft, to: :submitted },
                       approve: { from: :submitted, to: :approved }
                     }
      end)
    end

    it "transitions every eligible record and returns the count" do
      BatchOrder.create!(status: "draft")
      BatchOrder.create!(status: "draft")
      other = BatchOrder.create!(status: "submitted")

      expect(BatchOrder.transition_all(:submit)).to eq(2)
      expect(BatchOrder.where(status: "submitted").count).to eq(3)
      expect(other.reload.status).to eq("submitted")
    end

    it "skips records the guard rejects rather than raising" do
      BatchOrder.create!(status: "draft")
      BatchOrder.create!(status: "approved")

      expect(BatchOrder.transition_all(:submit)).to eq(1)
    end

    it "is idempotent" do
      BatchOrder.create!(status: "draft")
      BatchOrder.transition_all(:submit)

      expect(BatchOrder.transition_all(:submit)).to eq(0)
    end

    it "respects the relation" do
      keep = BatchOrder.create!(status: "draft")
      BatchOrder.create!(status: "draft")

      expect(BatchOrder.where.not(id: keep.id).transition_all(:submit)).to eq(1)
      expect(keep.reload.status).to eq("draft")
    end

    it "fires the transition hooks once per record" do
      stub_const("HookedOrder", Class.new(TestModel) do
        self.table_name = "batch_orders"
        include ConcernsOnRails::Stateable

        stateable_by :status, states: %i[draft submitted],
                              transitions: { submit: { from: :draft, to: :submitted } }

        cattr_accessor :events
        self.events = []

        def after_transition(event, from, to)
          self.class.events << [event, from, to]
        end
      end)
      HookedOrder.create!(status: "draft")

      expect(HookedOrder.transition_all(:submit)).to eq(1)
      expect(HookedOrder.events).to eq([[:submit, "draft", "submitted"]])
    end

    it "raises on an unknown event" do
      expect { BatchOrder.transition_all(:nope) }
        .to raise_error(ArgumentError, /unknown transition 'nope'/)
    end

    it "honours affixed event names" do
      stub_const("AffixedOrder", Class.new(TestModel) do
        self.table_name = "batch_orders"
        include ConcernsOnRails::Stateable

        stateable_by :status, states: %i[draft submitted], prefix: :order,
                              transitions: { submit: { from: :draft, to: :submitted } }
      end)
      AffixedOrder.create!(status: "draft")

      expect(AffixedOrder.transition_all(:submit)).to eq(1)
      expect(AffixedOrder.where(status: "submitted").count).to eq(1)
    end

    it "is idempotent when :from is omitted (any state -> target)" do
      stub_const("ArchivableOrder", Class.new(TestModel) do
        self.table_name = "batch_orders"
        include ConcernsOnRails::Stateable

        stateable_by :status, states: %i[draft submitted approved archived],
                              transitions: { archive: { to: :archived } }
      end)
      ArchivableOrder.create!(status: "draft")
      ArchivableOrder.create!(status: "submitted")

      expect(ArchivableOrder.transition_all(:archive)).to eq(2)
      expect(ArchivableOrder.transition_all(:archive)).to eq(0)
    end

    # `where.not(status: "archived")` compiles to NOT (status = 'archived'),
    # which is NULL — never TRUE — for a NULL state, so those rows were
    # silently skipped and left out of the count, even though may_archive? is
    # true for them and record.archive! on the same row works.
    context "with NULL-state rows and a transition declared without :from" do
      before do
        stub_const("NullableOrder", Class.new(TestModel) do
          self.table_name = "batch_orders"
          include ConcernsOnRails::Stateable

          stateable_by :status, states: %i[draft archived],
                                transitions: { archive: { to: :archived } }
        end)
        NullableOrder.create!(status: "draft")
        NullableOrder.insert_all([{ status: nil }]) # legacy / imported row
      end

      it "includes them in the batch" do
        expect(NullableOrder.transition_all(:archive)).to eq(2)
        expect(NullableOrder.where(status: "archived").count).to eq(2)
      end

      it "agrees with the per-record path, which already accepted them" do
        null_row = NullableOrder.find_by(status: nil)

        expect(null_row.may_archive?).to be(true)
      end

      it "is still idempotent afterwards" do
        NullableOrder.transition_all(:archive)

        expect(NullableOrder.transition_all(:archive)).to eq(0)
      end
    end
  end

  describe "ActiveRecord::Rollback from after_transition" do
    before do
      class RollbackTicket < TestModel
        include ConcernsOnRails::Stateable

        self.table_name = "tickets"

        stateable_by :status, states: %i[draft archived], default: :draft,
                              transitions: { archive: { to: :archived } }

        def after_transition(*)
          raise ActiveRecord::Rollback
        end
      end
    end

    after { Object.send(:remove_const, :RollbackTicket) if defined?(RollbackTicket) }

    it "rolls the state change back when called standalone" do
      t = RollbackTicket.create!(title: "t")

      t.archive!

      expect(t.reload.status).to eq("draft")
    end

    # A bare `transaction` JOINS the caller's, and Rails then swallows
    # ActiveRecord::Rollback without rolling anything back — the state change
    # committed, exactly opposite to the documented contract.
    it "rolls the state change back inside an enclosing transaction" do
      t = RollbackTicket.create!(title: "t")

      ActiveRecord::Base.transaction { t.archive! }

      expect(t.reload.status).to eq("draft")
    end

    # Lockable's half of this same fix uses a `completed` flag for exactly this
    # reason ("the caller must see false — not a fake success"). Stateable took
    # its return value from update!, which runs BEFORE after_transition, so an
    # aborted transition still reported success: `raise unless ticket.archive!`
    # never fired and the caller carried on as though the state had changed.
    it "returns false when the hook aborts the transition" do
      t = RollbackTicket.create!(title: "t")

      expect(t.archive!).to be(false)
      expect(t.reload.status).to eq("draft")
    end

    # BatchOps tallies the block's return value, so the fake success also
    # inflated the count — transition_all reported rows whose transition it had
    # just rolled back. A falsey return is the documented "failed record"
    # signal, so the batch now aborts loudly instead of lying about the count.
    it "does not report a rolled-back record as transitioned by transition_all" do
      RollbackTicket.create!(title: "t")

      expect { RollbackTicket.transition_all(:archive) }
        .to raise_error(ActiveRecord::RecordNotSaved, /failed to transition record/)
      expect(RollbackTicket.pluck(:status)).to eq(["draft"])
    end

    # Memory used to keep the vetoed state while the row kept the old one, so
    # a retry's guard read the NEW state and raised InvalidTransition.
    it "puts the in-memory state back so a retry after the veto works" do
      stub_const("VetoOnceTicket", Class.new(TestModel) do
        self.table_name = "tickets"
        include ConcernsOnRails::Stateable

        stateable_by :status, states: %i[draft published], default: :draft,
                              transitions: { publish: { from: :draft, to: :published } }

        cattr_accessor :veto

        def after_transition(*)
          raise ActiveRecord::Rollback if self.class.veto
        end
      end)
      VetoOnceTicket.veto = true
      t = VetoOnceTicket.create!(title: "t")

      expect(t.publish!).to be(false)
      expect(t.status).to eq("draft")
      expect(t.changed?).to be(false)

      VetoOnceTicket.veto = false
      expect(t.publish!).to be(true)
      expect(t.reload.status).to eq("published")
    end

    it "leaves the caller's own writes in the enclosing transaction intact" do
      t = RollbackTicket.create!(title: "t")
      other = RollbackTicket.create!(title: "other")

      ActiveRecord::Base.transaction do
        other.update!(title: "renamed")
        t.archive!
      end

      expect(other.reload.title).to eq("renamed")
      expect(t.reload.status).to eq("draft")
    end
  end
  # A vetoed transition restored only the state column: the entry
  # Auditable's before_save had appended to the trail stayed in memory, and
  # the next unrelated save wrote a "draft -> published" change that never
  # happened.
  describe "a vetoed transition on an Auditable model" do
    before do
      ActiveRecord::Schema.define do
        create_table :audited_tickets, force: true do |t|
          t.string :title
          t.string :status
          t.text :audit_log
        end
      end
    end

    let(:klass) do
      Class.new(TestModel) do
        self.table_name = "audited_tickets"
        include ConcernsOnRails::Stateable
        include ConcernsOnRails::Auditable

        stateable_by :status, states: %i[draft published], default: :draft,
                              transitions: { publish: { from: :draft, to: :published } }
        auditable_by :status

        attr_accessor :veto

        def after_transition(*)
          raise ActiveRecord::Rollback if veto
        end
      end
    end

    it "leaves no phantom entry for a later save to persist" do
      ticket = klass.find(klass.create!(title: "a").id)
      ticket.veto = true
      expect(ticket.publish!).to be(false)
      ticket.update!(title: "b") # an untracked field

      published = klass.find(ticket.id).audit_trail.select { |entry| entry["to"] == "published" }
      expect(published).to be_empty
      expect(ticket.audit_trail.map { |entry| entry["to"] }).to eq(%w[draft])
    end
  end

  describe "timestamps: (<state>_at stamping)" do
    before do
      ActiveRecord::Schema.define do
        create_table :stamped_posts, force: true do |t|
          t.string :status
          t.datetime :draft_at
          t.datetime :review_at
          t.datetime :published_at
          t.datetime :archived_at
        end
        create_table :partially_stamped_posts, force: true do |t|
          t.string :status
          t.datetime :published_at
        end
      end
    end

    let(:stamped) do
      Class.new(TestModel) do
        self.table_name = "stamped_posts"
        include ConcernsOnRails::Stateable

        stateable_by :status, states: %i[draft review published archived], default: :draft, timestamps: true,
                              transitions: { submit: { from: :draft, to: :review },
                                             publish: { from: %i[draft review], to: :published },
                                             archive: { to: :archived } }
      end
    end

    it "puts a vetoed transition's <state>_at stamp back in memory too" do
      vetoing = Class.new(stamped) do
        def after_transition(*)
          raise ActiveRecord::Rollback
        end
      end
      post = vetoing.create!

      expect(post.publish!).to be(false)
      expect([post.status, post.published_at]).to eq(["draft", nil])
      expect(post.reload.published_at).to be_nil
    end

    it "stamps <state>_at in the same write as a guarded transition" do
      post = stamped.create!
      travel_to(Time.utc(2026, 3, 1, 12)) { post.publish! }
      post.reload
      expect(post.published_at).to eq(Time.utc(2026, 3, 1, 12))
      expect(post.review_at).to be_nil
    end

    it "stamps for direct setters and transition_to! too" do
      post = stamped.create!
      travel_to(Time.utc(2026, 3, 2, 9)) { post.archived! }
      expect(post.reload.archived_at).to eq(Time.utc(2026, 3, 2, 9))
      travel_to(Time.utc(2026, 3, 3, 9)) { post.transition_to!(:review) }
      expect(post.reload.review_at).to eq(Time.utc(2026, 3, 3, 9))
    end

    it "does not stamp the default state on create — only explicit state writes stamp" do
      expect(stamped.create!.draft_at).to be_nil
    end

    it "re-stamps on re-entry and leaves the other stamps alone" do
      post = stamped.create!
      travel_to(Time.utc(2026, 3, 1, 12)) { post.publish! }
      travel_to(Time.utc(2026, 3, 5, 12)) { post.archive! }
      travel_to(Time.utc(2026, 3, 9, 12)) { post.transition_to!(:published) }
      post.reload
      expect(post.published_at).to eq(Time.utc(2026, 3, 9, 12))
      expect(post.archived_at).to eq(Time.utc(2026, 3, 5, 12))
    end

    it "stamps through transition_all" do
      eligible = stamped.create!
      skipped = stamped.create!(status: "archived")
      travel_to(Time.utc(2026, 4, 1)) { expect(stamped.transition_all(:publish)).to eq(1) }
      expect(eligible.reload.published_at).to eq(Time.utc(2026, 4, 1))
      expect(skipped.reload.published_at).to be_nil
    end

    it "timestamps: with a list stamps only those states" do
      partial = Class.new(TestModel) do
        self.table_name = "partially_stamped_posts"
        include ConcernsOnRails::Stateable

        stateable_by :status, states: %i[draft published archived], default: :draft, timestamps: %i[published],
                              transitions: { publish: { from: :draft, to: :published }, archive: { to: :archived } }
      end
      post = partial.create!
      travel_to(Time.utc(2026, 3, 1)) { post.publish! }
      expect(post.reload.published_at).to eq(Time.utc(2026, 3, 1))
      expect { post.archive! }.not_to raise_error # no archived_at column and not listed
      expect(post.reload.archived?).to be(true)
      expect(partial.stateable_timestamps).to eq(%i[published])
    end

    it "exposes the stamped states (every state with timestamps: true)" do
      expect(stamped.stateable_timestamps).to eq(%i[draft review published archived])
      expect(Ticket.stateable_timestamps).to eq([])
    end

    it "does not hand out the states array itself" do
      expect(stamped.stateable_timestamps).to eq(stamped.stateable_states)
      expect(stamped.stateable_timestamps).not_to equal(stamped.stateable_states)
      stamped.stateable_timestamps << :nope
      expect(stamped.stateable_states).to eq(%i[draft review published archived])
    end

    it "requires the <state>_at columns with a typed migration hint" do
      expect do
        Class.new(TestModel) do
          self.table_name = "partially_stamped_posts"
          include ConcernsOnRails::Stateable

          stateable_by :status, states: %i[draft published], timestamps: true
        end
      end.to raise_error(ArgumentError, /draft_at.*does not exist.*draft_at:datetime/)
    end

    it "rejects timestamps: naming an undeclared state, or a value that is neither true nor an Array" do
      expect do
        Class.new(TestModel) do
          self.table_name = "partially_stamped_posts"
          include ConcernsOnRails::Stateable

          stateable_by :status, states: %i[draft published], timestamps: %i[published nope]
        end
      end.to raise_error(ArgumentError, /timestamps: references unknown states: nope/)

      expect do
        Class.new(TestModel) do
          self.table_name = "partially_stamped_posts"
          include ConcernsOnRails::Stateable

          stateable_by :status, states: %i[draft published], timestamps: "yes"
        end
      end.to raise_error(ArgumentError, /timestamps: must be true or an Array of states/)
    end

    it "refuses to stamp a column Rails owns — created_at would be rewritten on every entry" do
      expect do
        Class.new(TestModel) do
          self.table_name = "stamped_posts"
          include ConcernsOnRails::Stateable

          stateable_by :status, states: %i[created published], timestamps: true
        end
      end.to raise_error(ArgumentError, /would stamp created_at, which Rails owns/)
    end
  end

  describe "per-event hooks (before_<event> / after_<event>)" do
    let(:klass) do
      Class.new(TestModel) do
        self.table_name = "tickets"
        include ConcernsOnRails::Stateable

        stateable_by :status, states: %i[draft published archived], default: :draft,
                              transitions: { publish: { from: :draft, to: :published }, archive: { to: :archived } }

        attr_reader :log

        def before_transition(event, from, to)
          (@log ||= []) << [:before_transition, event, from, to]
        end

        def after_transition(event, from, to)
          (@log ||= []) << [:after_transition, event, from, to]
        end

        def before_publish
          (@log ||= []) << :before_publish
        end

        def after_publish
          (@log ||= []) << :after_publish
        end
      end
    end

    it "fires generic → specific before the write and specific → generic after, only for the matching event" do
      ticket = klass.create!
      ticket.publish!
      expect(ticket.log).to eq(
        [[:before_transition, :publish, "draft", "published"], :before_publish,
         :after_publish, [:after_transition, :publish, "draft", "published"]]
      )

      ticket.instance_variable_set(:@log, nil)
      ticket.archive!
      expect(ticket.log).to eq(
        [[:before_transition, :archive, "published", "archived"], [:after_transition, :archive, "published", "archived"]]
      )
    end

    it "calls a private hook — overriding one privately is a Rails idiom, and public_send would raise" do
      private_hooks = Class.new(klass) do
        private

        def after_publish
          (@log ||= []) << :private_after_publish
        end
      end
      ticket = private_hooks.create!
      ticket.publish!
      expect(ticket.log).to include(:private_after_publish)
      expect(ticket.reload.published?).to be(true)
    end

    it "shares the transaction — a raising after_<event> rolls the state change back" do
      failing = Class.new(klass) do
        def after_publish
          raise "boom"
        end
      end
      ticket = failing.create!
      expect { ticket.publish! }.to raise_error("boom")
      expect(ticket.reload.draft?).to be(true)
    end

    it "uses the affixed event name for the hook (prefix: true → before_status_publish)" do
      affixed = Class.new(TestModel) do
        self.table_name = "tickets"
        include ConcernsOnRails::Stateable

        stateable_by :status, states: %i[draft published], default: :draft, prefix: true,
                              transitions: { publish: { from: :draft, to: :published } }

        attr_reader :log

        def before_status_publish
          (@log ||= []) << :before_status_publish
        end

        def before_publish
          (@log ||= []) << :wrong_hook
        end
      end
      ticket = affixed.create!
      ticket.status_publish!
      expect(ticket.log).to eq([:before_status_publish])
    end

    it "does not fire for direct setters or transition_to!" do
      ticket = klass.create!
      ticket.published!
      ticket.transition_to!(:archived)
      expect(ticket.log).to be_nil
    end

    it "fires once per record through transition_all" do
      klass.create!
      klass.create!
      calls = 0
      counting = Class.new(klass) do
        define_method(:after_publish) { calls += 1 }
      end
      expect(counting.transition_all(:publish)).to eq(2)
      expect(calls).to eq(2)
    end
  end
end
