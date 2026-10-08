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

  describe "re-declaring default:" do
    before do
      ActiveRecord::Schema.define do
        create_table :redefaulted_tickets, force: true do |t|
          t.string :type
          t.string :status
          t.string :phase, default: "open"
        end
      end
    end

    let(:parent) do
      Class.new(TestModel) do
        self.table_name = "redefaulted_tickets"
        include ConcernsOnRails::Stateable

        stateable_by :status, states: %i[draft open], default: :draft
      end
    end

    it "drops the parent's default in a subclass whose declaration gives none" do
      stub_const("RedefaultedTicket", parent)
      stub_const("RedefaultedIncident", Class.new(parent) { stateable_by :status, states: %i[open closed] })

      expect(RedefaultedIncident.stateable_default).to be_nil
      expect(RedefaultedIncident.new.status).to be_nil # "draft" is not even one of its states
      expect(RedefaultedTicket.new.status).to eq("draft") # the parent keeps its own
    end

    it "keeps an inherited default that is still one of the subclass's states" do
      stub_const("RedefaultedTicket", parent)
      stub_const("RedefaultedBug", Class.new(parent) { stateable_by :status, states: %i[draft open triaged] })

      expect(RedefaultedBug.stateable_default).to eq(:draft)
      expect(RedefaultedBug.new.status).to eq("draft")
    end

    it "resets it with an explicit default: nil even when the state is still declared" do
      stub_const("RedefaultedTicket", parent)
      stub_const("RedefaultedTask", Class.new(parent) { stateable_by :status, states: %i[draft open], default: nil })

      expect(RedefaultedTask.stateable_default).to be_nil
      expect(RedefaultedTask.new.status).to be_nil
      expect(RedefaultedTicket.new.status).to eq("draft")
    end

    it "keeps the field's own attribute type through the default and its reset" do
      downcasing = Class.new(ActiveModel::Type::String) { def cast(value) = super&.downcase }.new
      klass = Class.new(TestModel) do
        self.table_name = "redefaulted_tickets"
        attribute :status, downcasing
        include ConcernsOnRails::Stateable

        stateable_by :status, states: %i[draft open], default: :draft
      end
      expect(klass.new(status: "OPEN").status).to eq("open") # not a forced plain :string

      klass.stateable_by :status, states: %i[open closed]
      expect(klass.new(status: "CLOSED").status).to eq("closed")
      expect(klass.new.status).to be_nil
    end

    it "drops it on a same-class re-declaration, falling back to the column's own default" do
      parent.stateable_by :phase, states: %i[draft open], default: :draft
      expect(parent.new.phase).to eq("draft")

      parent.stateable_by :phase, states: %i[open closed]
      expect(parent.new.phase).to eq("open") # the DB default, not the stale "draft"
    end

    # The captured type used to be stored once in the inherited class
    # attribute, so the subclass got the parent's plain String put back.
    it "keeps an STI subclass's own attribute type, declared before its stateable_by" do
      downcasing = Class.new(ActiveModel::Type::String) { def cast(value) = super&.downcase }.new
      stub_const("RedefaultedTicket", parent)
      stub_const("RedefaultedCase", Class.new(parent) do
        attribute :status, downcasing
        stateable_by :status, states: %i[draft open]
      end)

      expect(RedefaultedCase.new(status: "OPEN").status).to eq("open")
      expect(RedefaultedCase.new.status).to eq("draft") # the inherited default is kept
      expect(RedefaultedTicket.new(status: "OPEN").status).to eq("OPEN") # the parent's own type
    end
  end

  # A re-declaration replaces the previous one's generated names: those it no
  # longer generates are retired (removed where this class defined them,
  # hidden with undef_method where a parent did) and leave the owned list.
  describe "re-declaring retires the previous declaration's methods" do
    before do
      ActiveRecord::Schema.define do
        create_table :retired_tickets, force: true do |t|
          t.string :type
          t.string :status
          t.boolean :flagged
          t.boolean :active
          t.datetime :archived_at
        end
      end
    end

    let(:parent) do
      Class.new(TestModel) do
        self.table_name = "retired_tickets"
        include ConcernsOnRails::Stateable

        stateable_by :status, states: %i[draft published archived], default: :draft,
                              transitions: { archive: { to: :archived } }
      end
    end

    it "hides the parent's stale event, setter and scope in a subclass (the parent keeps them)" do
      stub_const("RetiredTicket", parent)
      stub_const("RetiredIncident", Class.new(parent) { stateable_by :status, states: %i[open closed], default: :open })

      incident = RetiredIncident.create!
      expect { incident.archive! }.to raise_error(NoMethodError)
      expect(incident.reload.status).to eq("open") # the stale event wrote a state it never declared
      expect(incident).not_to respond_to(:archive!)
      expect(incident).not_to respond_to(:draft!)
      expect(incident).not_to respond_to(:may_archive?)
      expect(RetiredIncident).not_to respond_to(:draft)
      expect(RetiredIncident.stateable_owned_methods[:scope]).to eq(%i[open closed])

      ticket = RetiredTicket.create!
      ticket.archive!
      expect(ticket.reload.status).to eq("archived")
      expect(RetiredTicket.draft.to_sql).to include(TestDatabase.quoted_column(:status))
    end

    it "removes them on a same-class re-declaration, and lets the class declare them again" do
      parent.stateable_by :status, states: %i[open closed], default: :open
      expect(parent.new).not_to respond_to(:archive!)
      expect(parent).not_to respond_to(:archived)

      parent.stateable_by :status, states: %i[open archived], transitions: { archive: { to: :archived } }
      record = parent.create!(status: "open")
      record.archive!
      expect(record.reload.status).to eq("archived")
    end

    it "lets a column's query method show through again once a state stops shadowing it" do
      parent.stateable_by :status, states: %i[open flagged]
      expect(parent.new(status: "flagged", flagged: false).flagged?).to be(true) # the state predicate

      parent.stateable_by :status, states: %i[open closed]
      expect(parent.new(status: "flagged", flagged: false).flagged?).to be(false) # the column again
    end

    it "no longer refuses a sibling for a name only a previous declaration generated" do
      parent.stateable_by :status, states: %i[pending active]
      parent.stateable_by :status, states: %i[pending live]

      expect { parent.include(ConcernsOnRails::Activatable) }.not_to raise_error
    end

    # Only a method Stateable itself defined is retired; one the class
    # wrote itself is its own, whatever it is named.
    context "when the class defined a stale name itself" do
      it "keeps a subclass's own method written above its re-declaration" do
        stub_const("RetiredTicket", parent)
        stub_const("RetiredReport", Class.new(parent) do
          def archived? = archived_at.present?
          stateable_by :status, states: %i[draft published]
        end)

        expect(RetiredReport.new(archived_at: Time.current).archived?).to be(true)
        expect(RetiredReport.new).not_to respond_to(:archive!) # the generated ones still go
      end

      it "keeps a subclass's own class method written above its re-declaration" do
        stub_const("RetiredTicket", parent)
        stub_const("RetiredReport", Class.new(parent) do
          def self.archived = where.not(archived_at: nil)
          stateable_by :status, states: %i[draft closed]
        end)

        expect(RetiredReport.archived.to_sql).to include(TestDatabase.quoted_column(:archived_at))
        expect(RetiredReport).not_to respond_to(:published) # the generated stale scope still goes
      end

      it "keeps a method the same class wrote after its first declaration" do
        parent.class_eval { def archived? = archived_at.present? }
        parent.stateable_by :status, states: %i[draft published]

        expect(parent.new(archived_at: Time.current).archived?).to be(true)
        expect(parent.stateable_owned_methods[:instance]).not_to include(:archived?)
      end
    end

    # Hidden in a module of the subclass's own, never with undef_method on
    # it, which would also block a module the subclass includes later and a
    # column's lazily generated query method.
    context "when the stale names are inherited" do
      it "does not block a sibling concern the subclass includes afterwards" do
        parent.stateable_by :status, states: %i[pending active]
        stub_const("RetiredTicket", parent)
        stub_const("RetiredMember", Class.new(parent) do
          stateable_by :status, states: %i[pending live]
          include ConcernsOnRails::Activatable

          activatable_by :active
        end)

        expect(RetiredMember.new(active: true).active?).to be(true) # Activatable's, not hidden
        expect(RetiredMember.active.to_sql).to include(TestDatabase.quoted_column(:active))
        expect(RetiredTicket.new(status: "active").active?).to be(true) # the parent's state predicate
      end

      it "hands a column's query method back instead of the parent's state predicate" do
        parent.stateable_by :status, states: %i[open flagged]
        stub_const("RetiredTicket", parent)
        stub_const("RetiredIncident", Class.new(parent) { stateable_by :status, states: %i[open closed] })

        expect(RetiredIncident.new(status: "flagged", flagged: false).flagged?).to be(false)
        expect(RetiredTicket.new(status: "flagged", flagged: false).flagged?).to be(true)
      end

      it "lets the subclass declare a hidden name again" do
        stub_const("RetiredTicket", parent)
        stub_const("RetiredIncident", Class.new(parent) { stateable_by :status, states: %i[open closed] })
        expect { RetiredIncident.stateable_by :status, states: %i[open archived], transitions: { archive: { to: :archived } } }
          .not_to raise_error

        incident = RetiredIncident.create!(status: "open")
        incident.archive!
        expect(incident.reload.status).to eq("archived")
        expect(RetiredIncident.archived.to_sql).to include(TestDatabase.quoted_column(:status))
      end
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

    describe "generated-method collisions" do
      it "refuses an event whose <event>! would override ActiveRecord's lock!" do
        expect do
          define_model(:lock_events) do
            stateable_by :status, states: %i[open locked], default: :open,
                                  transitions: { lock: { from: :open, to: :locked } }
          end
        end.to raise_error(ArgumentError, /'lock!'.*prefix: or suffix:/)
      end

      it "refuses it under lock: true too" do
        expect do
          define_model(:lock_true_events) do
            stateable_by :status, states: %i[open locked], lock: true,
                                  transitions: { lock: { from: :open, to: :locked } }
          end
        end.to raise_error(ArgumentError, /'lock!'/)
      end

      it "accepts the same event once prefix:/suffix: moves it off the AR name" do
        klass = define_model(:affixed_lock_events) do
          stateable_by :status, states: %i[open locked], default: :open, lock: true, suffix: :thread,
                                transitions: { lock: { from: :open, to: :locked } }
        end
        record = klass.create!
        record.lock_thread!
        expect(record.reload.status).to eq("locked")
        expect { record.with_lock { nil } }.not_to raise_error
      end

      it "refuses a state whose predicate would override an ActiveRecord method" do
        expect { define_model(:valid_states) { stateable_by :status, states: %i[valid invalid] } }
          .to raise_error(ArgumentError, /'valid\?'/)
      end

      it "refuses a method another concern already defined (SoftDeletable#restore!)" do
        ActiveRecord::Schema.define do
          create_table(:restorables, force: true) do |t|
            t.string :status
            t.datetime :deleted_at
          end
        end
        expect do
          Class.new(TestModel) do
            self.table_name = "restorables"
            include ConcernsOnRails::SoftDeletable
            include ConcernsOnRails::Stateable

            stateable_by :status, states: %i[trashed live], transitions: { restore: { to: :live } }
          end
        end.to raise_error(ArgumentError, /'restore!'/)
      end

      it "refuses a scope another concern already defined (Activatable.active)" do
        ActiveRecord::Schema.define do
          create_table(:activatable_states, force: true) do |t|
            t.string :status
            t.boolean :active
          end
        end
        expect do
          Class.new(TestModel) do
            self.table_name = "activatable_states"
            include ConcernsOnRails::Activatable
            include ConcernsOnRails::Stateable

            stateable_by :status, states: %i[pending active]
          end
        end.to raise_error(ArgumentError, /'active\??'/)
      end

      it "refuses a scope name the class already answers (a pre-existing class method)" do
        expect do
          define_model(:class_method_states) do
            def self.archived = :mine

            stateable_by :status, states: %i[live archived]
          end
        end.to raise_error(ArgumentError, /generated scope 'archived'/)
      end

      # SoftDeletable (like Publishable and Schedulable) defines its
      # default-named scopes at INCLUDE time and renames them only in its own
      # macro, which may come after stateable_by: the guard lets a state take
      # such a name, and the shared scope refuses to run until the rename.
      context "when a state shares a name with an include-time default scope" do
        before do
          ActiveRecord::Schema.define do
            create_table(:trashed_members, force: true) do |t|
              t.string :type
              t.string :status
              t.datetime :deleted_at
            end
          end
        end

        def member_model(&block)
          Class.new(TestModel) do
            self.table_name = "trashed_members"
            include ConcernsOnRails::SoftDeletable
            include ConcernsOnRails::Stateable

            stateable_by :status, states: %i[pending active]
            class_eval(&block) if block
          end
        end

        it "accepts it when that concern's macro renames its scopes afterwards (as on 1.30)" do
          klass = nil
          expect { klass = member_model { soft_deletable_by prefix: :trash } }.not_to raise_error
          expect(klass.active.to_sql).to include(TestDatabase.quoted_column(:status))
          expect(klass.trash_active.to_sql).to include(TestDatabase.quoted_column(:deleted_at))
          expect(klass.active.where_values_hash).to include("status" => "active")
        end

        it "raises when the shared scope is called and the rename never came" do
          klass = member_model
          expect { klass.active }
            .to raise_error(ArgumentError, /scope 'active' is both a state scope and .*SoftDeletable.*prefix:/)
          expect { member_model { soft_deletable_by :deleted_at }.active }.to raise_error(ArgumentError) # no affix
        end

        it "hands the name back to that concern when a re-declaration drops the state" do
          klass = member_model
          klass.stateable_by :status, states: %i[pending live]
          expect(klass.active.to_sql).to include(TestDatabase.quoted_column(:deleted_at))
        end

        it "leaves no stray unaffixed scope when the concern renames its own after the hand-back" do
          klass = member_model do
            stateable_by :status, states: %i[pending live]
            soft_deletable_by prefix: :trash
          end
          expect(klass).to respond_to(:trash_active)
          expect(klass).not_to respond_to(:active)
        end

        # SoftDeletable's retire! refuses to affix on a subclass, so the
        # rename the call-time check would ask for can never come there.
        it "refuses at class load a subclass state taking the PARENT's include-time scope" do
          stub_const("TrashedMember", Class.new(TestModel) do
            self.table_name = "trashed_members"
            include ConcernsOnRails::SoftDeletable
            include ConcernsOnRails::Stateable
          end)
          expect { Class.new(TrashedMember) { stateable_by :status, states: %i[pending active] } }
            .to raise_error(ArgumentError, /generated scope 'active'/)
        end

        # The concern must be INCLUDED before stateable_by; only its affixing
        # macro may come after. Included later, it would replace Stateable's
        # scope at include time, so the reverse-order check refuses it.
        it "refuses the concern included after stateable_by, even when its macro affixes" do
          expect do
            Class.new(TestModel) do
              self.table_name = "trashed_members"
              include ConcernsOnRails::Stateable

              stateable_by :status, states: %i[pending active]
              include ConcernsOnRails::SoftDeletable

              soft_deletable_by prefix: :trash
            end
          end.to raise_error(ArgumentError, /SoftDeletable: scope 'active' collides/)
        end

        it "still refuses a scope the other concern's macro defined itself (not an include-time default)" do
          expect do
            member_model do
              soft_deletable_by prefix: :trash
              stateable_by :status, states: %i[pending trash_active]
            end
          end.to raise_error(ArgumentError, /generated scope 'trash_active'/)
        end
      end

      context "when the other concern comes AFTER stateable_by" do
        before do
          ActiveRecord::Schema.define do
            create_table(:reverse_orders, force: true) do |t|
              t.string :status
              t.boolean :active
              t.datetime :expires_at
              t.datetime :published_at
            end
          end
        end

        def reverse_model(&block)
          Class.new(TestModel) do
            self.table_name = "reverse_orders"
            include ConcernsOnRails::Stateable

            class_eval(&block)
          end
        end

        it "refuses including a concern whose methods Stateable's would shadow (Activatable#active?)" do
          expect do
            reverse_model do
              stateable_by :status, states: %i[pending active]
              include ConcernsOnRails::Activatable
            end
          end.to raise_error(ArgumentError, /Activatable: method 'active\?' collides with .*Stateable.*prefix: or suffix:/)
        end

        it "refuses a Publishable whose publish! a Stateable event already defined" do
          expect do
            reverse_model do
              stateable_by :status, states: %i[pending live], transitions: { publish: { to: :live } }
              include ConcernsOnRails::Publishable
            end
          end.to raise_error(ArgumentError, /Publishable: method 'publish!'/)
        end

        it "refuses a later scope that would replace Stateable's (Expirable.expiring_within)" do
          expect do
            reverse_model do
              stateable_by :status, states: %i[fresh expiring_within]
              include ConcernsOnRails::Expirable

              expirable_by
            end
          end.to raise_error(ArgumentError, /Expirable: scope 'expiring_within' collides/)
        end

        it "accepts the pair once stateable_by is affixed" do
          klass = reverse_model do
            stateable_by :status, states: %i[pending active], prefix: true
            include ConcernsOnRails::Activatable

            activatable_by :active
          end
          expect(klass.status_active.to_sql).to include(TestDatabase.quoted_column(:status))
          expect(klass.active.to_sql).not_to include(TestDatabase.quoted_column(:status))
        end
      end

      it "exempts column predicates in an STI parent's attribute module, whatever the load order" do
        ActiveRecord::Schema.define do
          create_table(:flagged_tickets, force: true) do |t|
            t.string :type
            t.string :status
            t.boolean :flagged
          end
        end
        parent = Class.new(TestModel) do
          self.table_name = "flagged_tickets"
          include ConcernsOnRails::Stateable

          stateable_by :status, states: %i[open closed]
        end
        stub_const("FlaggedTicket", parent)
        FlaggedTicket.new # defines flagged? in the PARENT's generated-attribute module

        expect { Class.new(FlaggedTicket) { stateable_by :status, states: %i[open closed flagged] } }
          .not_to raise_error
      end

      it "still lets the same class, and a subclass, re-declare its own methods" do
        klass = define_model(:redeclared_states) do
          stateable_by :status, states: %i[draft published], transitions: { publish: { to: :published } }
        end
        expect { klass.stateable_by :status, states: %i[draft published], transitions: { publish: { to: :published } } }
          .not_to raise_error
        expect { Class.new(klass) { stateable_by :status, states: %i[draft published archived] } }
          .not_to raise_error
      end
    end

    it "raises on unknown options (1.26)" do
      expect { define_model(:typoed) { stateable_by :status, states: %i[a b], lokc: true } }
        .to raise_error(ArgumentError, /unknown option\(s\): lokc/)
    end
  end

  describe "lock: true (1.26)" do
    let(:klass) do
      ActiveRecord::Schema.define do
        create_table(:locked_orders, force: true) do |t|
          t.string :status
          t.string :note
        end
      end
      Class.new(TestModel) do
        self.table_name = "locked_orders"
        include ConcernsOnRails::Stateable

        stateable_by :status, states: %i[draft review published archived], default: :draft, lock: true,
                              transitions: { submit: { from: :draft, to: :review },
                                             publish: { from: %i[draft review], to: :published },
                                             archive: { to: :archived } }
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
        .to raise_error(ConcernsOnRails::Models::Stateable::InvalidTransition, /from 'published'/)
      expect(stale.status).to eq("published") # the row's state, as the reload used to show
      expect(stale).not_to be_changed
    end

    # RA-06: the row lock used to be with_lock, whose reload refuses a record
    # with unsaved changes ("Locking a record with unpersisted changes is not
    # supported") — `ticket.note = "..."; ticket.resolve!` crashed.
    it "transitions a record with pending changes and saves them with the state (as lock: false does)" do
      record = klass.create!
      record.note = "fixed in 1.2"

      expect(record.publish!).to be(true)

      expect(klass.find(record.id).attributes.slice("status", "note"))
        .to eq("status" => "published", "note" => "fixed in 1.2")
      expect(record).not_to be_changed
    end

    it "keeps pending changes in memory (no reload) when the locked row fails the guard" do
      record = klass.create!
      klass.find(record.id).publish!
      record.note = "draft notes"

      expect { record.submit! }.to raise_error(ConcernsOnRails::Models::Stateable::InvalidTransition)

      expect(record.note).to eq("draft notes")
      expect(record.note_changed?).to be(true)
      expect(klass.find(record.id).attributes.slice("status", "note")).to eq("status" => "published", "note" => nil)
    end

    it "transitions from the row's state when that state also passes the guard (the reload's contract)" do
      record = klass.create!
      klass.find(record.id).submit! # draft -> review elsewhere

      expect(record.publish!).to be(true) # publish is allowed from draft AND review

      expect(klass.find(record.id).status).to eq("published")
    end

    it "an any-state event on a stale copy still fires, handing the hooks the row's state" do
      record = klass.create!
      klass.find(record.id).submit!
      seen = []
      klass.define_method(:before_transition) { |event, from, to| seen << [event, from, to] }

      expect(record.archive!).to be(true)

      expect(seen).to eq([[:archive, "review", "archived"]])
      expect(klass.find(record.id).status).to eq("archived")
    end

    it "reads only the state with a locking SELECT when the record has pending changes" do
      record = klass.create!
      record.note = "pending"
      reads = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        reads << payload[:sql] if payload[:name] != "SCHEMA" && payload[:sql].match?(/\ASELECT/i) && payload[:sql].include?("locked_orders")
      end
      begin
        record.publish!
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber)
      end

      expect(reads.size).to eq(1)
      expect(reads.first).to include(TestDatabase.quoted_column("status"))
      expect(reads.first).not_to include("*")
      expect(reads.first).to include("FOR UPDATE") unless TestDatabase.sqlite?
      expect(klass.find(record.id).note).to eq("pending")
    end

    it "raises RecordNotFound when the row has gone (clean record: the reload's own error)" do
      record = klass.create!
      klass.where(id: record.id).delete_all

      expect { record.publish! }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises RecordNotFound when the row has gone (record with pending changes)" do
      record = klass.create!
      record.note = "pending"
      klass.where(id: record.id).delete_all

      expect { record.publish! }.to raise_error(ActiveRecord::RecordNotFound)
      expect(record.note).to eq("pending")
    end

    it "an aborted transition of a record with pending changes leaves the adopted row state in memory" do
      record = klass.create!
      klass.find(record.id).submit!
      klass.define_method(:after_transition) { |*| raise ActiveRecord::Rollback }
      record.note = "pending"

      expect(record.publish!).to be(false)

      expect(record.status).to eq("review")
      expect(record.note).to eq("pending")
      expect(klass.find(record.id).status).to eq("review")
    end

    # PR #124 review (R124-02..05): a record WITHOUT pending changes keeps the
    # with_lock path it always had — reloaded under the lock, so every
    # attribute (lock_version included) is the committed row's. Only a record
    # with pending changes, which cannot be reloaded without losing them,
    # takes the column-only locked read.
    describe "a clean record is reloaded under the lock, as before" do
      # One table name per shape: SQLite pools prepared statements by SQL
      # text, and a statement prepared against the other shape would read
      # its column list.
      def create_tickets(lock_version:)
        @tickets_table = lock_version ? "versioned_lock_tickets" : "lock_tickets"
        ActiveRecord::Schema.define do
          create_table (lock_version ? :versioned_lock_tickets : :lock_tickets), force: true do |t|
            t.string :title
            t.string :status
            t.integer :lock_version, default: 0, null: false if lock_version
          end
        end
      end

      def ticket_model(&body)
        table = @tickets_table
        Class.new(TestModel) do
          self.table_name = table
          include ConcernsOnRails::Stateable

          stateable_by :status, states: %i[open resolved closed], default: :open, lock: true,
                                transitions: { resolve: { from: :open, to: :resolved },
                                               close: { from: %i[open resolved], to: :closed } }
          class_eval(&body) if body
        end
      end

      it "partial updates off: a stale copy's transition does not write its stale columns over a concurrent edit" do
        create_tickets(lock_version: false)
        klass = ticket_model
        klass.public_send(klass.respond_to?(:partial_updates=) ? :partial_updates= : :partial_writes=, false)
        ticket = klass.create!(title: "old")
        stale = klass.find(ticket.id)
        klass.find(ticket.id).update!(title: "new")

        stale.close!

        expect(klass.find(ticket.id).attributes.slice("title", "status")).to eq("title" => "new", "status" => "closed")
      end

      it "hooks and validations see the committed row" do
        create_tickets(lock_version: false)
        seen = []
        klass = ticket_model { define_method(:before_transition) { |*| seen << title } }
        ticket = klass.create!(title: "old")
        stale = klass.find(ticket.id)
        klass.find(ticket.id).update!(title: "new")

        stale.close!

        expect(seen).to eq(["new"])
      end

      it "lock_version model: a copy another process transitioned still fires an event the row's state allows" do
        create_tickets(lock_version: true)
        klass = ticket_model
        ticket = klass.create!(title: "t")
        stale = klass.find(ticket.id)
        klass.find(ticket.id).resolve!

        expect { stale.close! }.not_to raise_error
        expect(klass.find(ticket.id).status).to eq("closed")
      end

      it "lock_version model: transition_all is not rolled back by a concurrent edit of a batched row" do
        create_tickets(lock_version: true)
        klass = ticket_model do
          define_method(:before_transition) do |*|
            self.class.unscoped.where.not(id: id).where(title: "b").update_all(title: "b2") if title == "a"
          end
        end
        klass.create!(title: "a")
        klass.create!(title: "b")

        expect { klass.transition_all(:close) }.not_to raise_error
        expect(klass.pluck(:status)).to eq(%w[closed closed])
      end

      it "lock_version model: a record loaded with a partial select still transitions" do
        create_tickets(lock_version: true)
        klass = ticket_model
        ticket = klass.create!(title: "t")
        partial = klass.select(:id, :status).find(ticket.id)

        expect { partial.resolve! }.not_to raise_error
        expect(klass.find(ticket.id).status).to eq("resolved")
      end
    end

    context "with a lock_version column" do
      let(:versioned) do
        ActiveRecord::Schema.define do
          create_table(:versioned_orders, force: true) do |t|
            t.string :status
            t.string :note
            t.integer :lock_version, default: 0, null: false
          end
        end
        Class.new(TestModel) do
          self.table_name = "versioned_orders"
          include ConcernsOnRails::Stateable

          stateable_by :status, states: %i[draft published archived], default: :draft, lock: true,
                                transitions: { publish: { from: :draft, to: :published }, archive: { to: :archived } }
        end
      end

      it "saves pending changes with the transition and stays saveable" do
        record = versioned.create!
        record.note = "ready"

        expect(record.publish!).to be(true)

        expect(record.lock_version).to eq(versioned.where(id: record.id).pick(:lock_version))
        expect { record.update!(note: "shipped") }.not_to raise_error
      end

      # Its pending changes were made against a copy the row has moved on
      # from — exactly what optimistic locking exists to refuse.
      it "a stale copy WITH pending changes raises StaleObjectError" do
        record = versioned.create!
        versioned.find(record.id).update!(note: "edited elsewhere")
        record.note = "mine"

        expect { record.archive! }.to raise_error(ActiveRecord::StaleObjectError)
        expect(versioned.find(record.id).attributes.slice("status", "note"))
          .to eq("status" => "draft", "note" => "edited elsewhere")
        expect(record.note).to eq("mine")
      end
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

    # A `from:` naming the target makes re-entering it a declared
    # self-transition: may_submit? is true and record.submit! fires (and
    # re-stamps), so the batch filtering those rows out returned 0 for them.
    it "runs a self-transition that :from explicitly lists (2026-10-08 audit)" do
      stub_const("ResubmittableOrder", Class.new(TestModel) do
        self.table_name = "batch_orders"
        include ConcernsOnRails::Stateable

        stateable_by :status, states: %i[draft submitted],
                              transitions: { submit: { from: %i[draft submitted], to: :submitted } }

        cattr_accessor :events
        self.events = []

        def after_transition(event, from, to)
          self.class.events << [event, from, to]
        end
      end)
      ResubmittableOrder.create!(status: "draft")
      ResubmittableOrder.create!(status: "submitted")

      expect(ResubmittableOrder.transition_all(:submit)).to eq(2)
      expect(ResubmittableOrder.events)
        .to contain_exactly([:submit, "draft", "submitted"], [:submit, "submitted", "submitted"])
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
