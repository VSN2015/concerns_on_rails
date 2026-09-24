require "spec_helper"

describe ConcernsOnRails::Activatable do
  before do
    ActiveRecord::Schema.define do
      create_table :subscriptions, force: true do |t|
        t.string :name
        t.boolean :active
      end
    end

    class Subscription < TestModel
      include ConcernsOnRails::Activatable

      activatable_by
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  describe "predicates" do
    it "is inactive when the column is nil" do
      record = Subscription.create!(name: "n")
      expect(record.active?).to be false
      expect(record.inactive?).to be true
    end

    it "is inactive when the column is false" do
      record = Subscription.create!(name: "n", active: false)
      expect(record.active?).to be false
      expect(record.inactive?).to be true
    end

    it "is active when the column is true" do
      record = Subscription.create!(name: "n", active: true)
      expect(record.active?).to be true
      expect(record.inactive?).to be false
    end
  end

  describe "scopes" do
    it ".active returns only records with the column set to true" do
      on = Subscription.create!(name: "on", active: true)
      Subscription.create!(name: "off", active: false)
      Subscription.create!(name: "null")
      expect(Subscription.active.map(&:name)).to eq([on.name])
    end

    it ".inactive treats false and NULL as inactive" do
      Subscription.create!(name: "on", active: true)
      off = Subscription.create!(name: "off", active: false)
      nullish = Subscription.create!(name: "null")
      expect(Subscription.inactive.map(&:name)).to match_array([off.name, nullish.name])
    end
  end

  describe "mutators" do
    it "#activate! flips to true" do
      record = Subscription.create!(name: "n", active: false)
      record.activate!
      expect(record.reload.active).to be true
    end

    it "#deactivate! flips to false" do
      record = Subscription.create!(name: "n", active: true)
      record.deactivate!
      expect(record.reload.active).to be false
    end

    it "#toggle_active! flips true → false" do
      record = Subscription.create!(name: "n", active: true)
      record.toggle_active!
      expect(record.reload.active).to be false
    end

    it "#toggle_active! flips false → true" do
      record = Subscription.create!(name: "n", active: false)
      record.toggle_active!
      expect(record.reload.active).to be true
    end

    it "#toggle_active! flips NULL → true (treated as inactive)" do
      record = Subscription.create!(name: "n")
      record.toggle_active!
      expect(record.reload.active).to be true
    end
  end

  describe "custom field configuration" do
    it "supports a custom column name" do
      ActiveRecord::Schema.define do
        create_table :widgets, force: true do |t|
          t.string :name
          t.boolean :enabled
        end
      end

      class Widget < TestModel
        include ConcernsOnRails::Activatable

        activatable_by :enabled
      end

      on = Widget.create!(name: "on", enabled: true)
      Widget.create!(name: "off", enabled: false)
      expect(Widget.active.map(&:name)).to eq([on.name])
      expect(Widget.new(enabled: true).active?).to be true
    end
  end

  describe "validation" do
    it "raises ArgumentError when the configured column does not exist" do
      ActiveRecord::Schema.define do
        create_table :bad_subscriptions, force: true do |t|
          t.string :name
        end
      end

      expect do
        class BadSubscription < TestModel
          include ConcernsOnRails::Activatable

          activatable_by :missing
        end
      end.to raise_error(ArgumentError, /does not exist/)
    end
  end

  describe "prefix / suffix scope names" do
    it "affixes the scope names so they don't collide with sibling concerns" do
      ActiveRecord::Schema.define do
        create_table :memberships, force: true do |t|
          t.boolean :active
        end
      end

      klass = Class.new(TestModel) do
        self.table_name = "memberships"
        include ConcernsOnRails::Activatable

        activatable_by :active, prefix: :membership
      end

      on = klass.create!(active: true)
      klass.create!(active: false)
      expect(klass.membership_active.to_a).to eq([on])
      expect(klass.respond_to?(:active)).to be(false)
    end

    # The affix used to cover only the scopes, so with Expirable included too
    # one concern's `active?` silently replaced the other's.
    it "defines affixed predicates alongside the plain ones" do
      ActiveRecord::Schema.define do
        create_table :memberships, force: true do |t|
          t.boolean :active
        end
      end

      klass = Class.new(TestModel) do
        self.table_name = "memberships"
        include ConcernsOnRails::Activatable

        activatable_by :active, suffix: :flag
      end

      on = klass.create!(active: true)
      off = klass.create!(active: nil)
      expect([on.active_flag?, on.inactive_flag?]).to eq([true, false])
      expect([off.active_flag?, off.inactive_flag?]).to eq([false, true])
      expect(on.active?).to be(true)
      expect(Subscription.new).not_to respond_to(:active_flag?)
    end
  end

  # With Expirable included AFTER Activatable, `active?` is Expirable's
  # ("not expired" — true for a nil expiry). toggle_active! read it, so it
  # deactivated an inactive record instead of activating it.
  describe "toggle_active! alongside Expirable" do
    before do
      ActiveRecord::Schema.define do
        create_table :memberships, force: true do |t|
          t.boolean :active
          t.datetime :expires_at
        end
      end

      stub_const("ExpiringMembership", Class.new(TestModel) do
        self.table_name = "memberships"
        include ConcernsOnRails::Activatable
        include ConcernsOnRails::Expirable

        activatable_by :active, prefix: :flag
        expirable_by :expires_at, prefix: :term
      end)
    end

    it "flips its own flag, whatever the plain active? says" do
      record = ExpiringMembership.create!(active: false, expires_at: nil)
      expect(record.active?).to be(true) # Expirable's answer: never expires

      record.toggle_active!
      expect(record.reload.active).to be(true)

      record.toggle_active!
      expect(record.reload.active).to be(false)
    end

    it "keeps both concerns' questions reachable through the affixed predicates" do
      record = ExpiringMembership.create!(active: false, expires_at: 1.day.ago)

      expect([record.flag_active?, record.flag_inactive?]).to eq([false, true])
      expect([record.term_active?, record.term_expired?]).to eq([false, true])
    end
  end

  # An after hook vetoing with ActiveRecord::Rollback used to be swallowed by a
  # bare `transaction` that joined the caller's (or the batch's): the flip
  # committed, the verb returned true, and activate_all counted the row.
  describe "ActiveRecord::Rollback from a lifecycle hook" do
    let(:vetoing) do
      Class.new(TestModel) do
        self.table_name = "subscriptions"
        include ConcernsOnRails::Activatable

        activatable_by

        cattr_accessor :veto

        def after_activate
          raise ActiveRecord::Rollback if self.class.veto == :activate
        end

        def after_deactivate
          raise ActiveRecord::Rollback if self.class.veto == :deactivate
        end
      end
    end

    it "activate! returns false and leaves the row (and memory) inactive" do
      vetoing.veto = :activate
      record = vetoing.create!(name: "n", active: false)

      expect(record.activate!).to be(false)
      expect(record.active).to be(false)
      expect(record.reload.active).to be(false)
    end

    it "deactivate! and toggle_active! return false and leave the row active" do
      vetoing.veto = :deactivate
      record = vetoing.create!(name: "n", active: true)

      expect(record.deactivate!).to be(false)
      expect(record.toggle_active!).to be(false)
      expect(record.reload.active).to be(true)
    end

    it "rolls back inside a caller transaction, keeping the caller's own writes" do
      vetoing.veto = :activate
      record = vetoing.create!(name: "n", active: false)
      other = vetoing.create!(name: "other")

      ActiveRecord::Base.transaction do
        other.update!(name: "renamed")
        record.activate!
      end

      expect(other.reload.name).to eq("renamed")
      expect(record.reload.active).to be(false)
    end

    it "activate_all and deactivate_all raise RecordNotSaved and commit nothing" do
      vetoing.veto = :activate
      vetoing.create!(name: "a", active: false)
      expect { vetoing.activate_all }.to raise_error(ActiveRecord::RecordNotSaved, /failed to activate/)
      expect(vetoing.where(active: true).count).to eq(0)

      vetoing.veto = :deactivate
      vetoing.update_all(active: true)
      expect { vetoing.deactivate_all }.to raise_error(ActiveRecord::RecordNotSaved, /failed to deactivate/)
      expect(vetoing.where(active: true).count).to eq(1)
    end
  end

  # `update` returning false (validation) used to leave the before hook's
  # own writes committed.
  it "rolls the before hook's side effects back when the write fails validation" do
    klass = Class.new(TestModel) do
      self.table_name = "subscriptions"
      include ConcernsOnRails::Activatable

      activatable_by
      validates :name, presence: true

      def before_activate
        self.class.where(id: id).update_all(name: "touched-by-hook")
      end
    end
    record = klass.create!(name: "ok", active: false)
    record.name = nil

    expect(record.activate!).to be(false)
    expect(record.reload.name).to eq("ok")
    expect(record.active).to be(false)
  end

  describe "batch operations" do
    before do
      ActiveRecord::Schema.define do
        create_table :batch_flags, force: true do |t|
          t.boolean :active
          t.string :title
        end
      end

      stub_const("BatchFlag", Class.new(TestModel) do
        self.table_name = "batch_flags"
        include ConcernsOnRails::Activatable

        activatable_by
      end)
    end

    it "activates every inactive record and returns the count" do
      BatchFlag.create!(active: false)
      BatchFlag.create!(active: nil)
      BatchFlag.create!(active: true)

      expect(BatchFlag.activate_all).to eq(2)
      expect(BatchFlag.active.count).to eq(3)
    end

    it "deactivates every active record" do
      BatchFlag.create!(active: true)
      BatchFlag.create!(active: false)

      expect(BatchFlag.deactivate_all).to eq(1)
      expect(BatchFlag.inactive.count).to eq(2)
    end

    it "is idempotent" do
      BatchFlag.create!(active: false)
      BatchFlag.activate_all

      expect(BatchFlag.activate_all).to eq(0)
    end

    it "respects the relation" do
      keep = BatchFlag.create!(active: false)
      BatchFlag.create!(active: false)

      expect(BatchFlag.where.not(id: keep.id).activate_all).to eq(1)
      expect(keep.reload.active).to be false
    end

    it "cannot take the fast path when the model has validations — an invalid record rolls the whole batch back" do
      stub_const("ValidatedFlag", Class.new(TestModel) do
        self.table_name = "batch_flags"
        include ConcernsOnRails::Activatable

        activatable_by

        validates :title, presence: true
      end)
      valid = ValidatedFlag.create!(title: "ok", active: false)
      invalid = ValidatedFlag.create!(title: "temporary", active: false)
      invalid.update_column(:title, nil)

      expect { ValidatedFlag.activate_all }.to raise_error(ActiveRecord::RecordNotSaved)
      expect(valid.reload.active).to be false
      expect(invalid.reload.active).to be false
    end

    # Regression: `validate :method` leaves `validators` EMPTY (only `validates`
    # / `validates_with` populate it), so the old `validators.empty?` gate took
    # the fast path and activated invalid rows.
    it "cannot take the fast path when the model has a custom validate method" do
      stub_const("CallbackValidatedFlag", Class.new(TestModel) do
        self.table_name = "batch_flags"
        include ConcernsOnRails::Activatable

        activatable_by
        validate :title_must_be_present

        def title_must_be_present
          errors.add(:title, "can't be blank") if title.blank?
        end
      end)
      valid = CallbackValidatedFlag.create!(title: "ok", active: false)
      invalid = CallbackValidatedFlag.create!(title: "temporary", active: false)
      invalid.update_column(:title, nil)

      expect(CallbackValidatedFlag.validators).to be_empty
      expect { CallbackValidatedFlag.activate_all }.to raise_error(ActiveRecord::RecordNotSaved)
      expect(valid.reload.active).to be false
      expect(invalid.reload.active).to be false
    end
  end

  describe "lifecycle hooks and timestamps:" do
    before do
      ActiveRecord::Schema.define do
        create_table :stamped_subscriptions, force: true do |t|
          t.string :name
          t.boolean :active
          t.datetime :activated_at
          t.datetime :deactivated_at
          t.datetime :enabled_at
          t.datetime :updated_at
        end
      end
    end

    def stamped_class(&declaration)
      Class.new(TestModel) do
        self.table_name = "stamped_subscriptions"
        include ConcernsOnRails::Activatable

        class_eval(&declaration)
      end
    end

    it "runs before_/after_ hooks around activate! and deactivate!" do
      klass = stamped_class do
        activatable_by
        attr_reader :log

        def before_activate = (@log ||= []) << :before_activate
        def after_activate = (@log ||= []) << :after_activate
        def before_deactivate = (@log ||= []) << :before_deactivate
        def after_deactivate = (@log ||= []) << :after_deactivate
      end
      record = klass.create!(active: false)
      expect(record.activate!).to be(true)
      expect(record.log).to eq(%i[before_activate after_activate])
      expect(record.deactivate!).to be(true)
      expect(record.log).to eq(%i[before_activate after_activate before_deactivate after_deactivate])
    end

    it "shares one transaction with the write: a raising after hook rolls it back, a failed update skips the after hook" do
      boom = stamped_class do
        activatable_by
        def after_activate = raise("boom")
      end
      record = boom.create!(active: false)
      expect { record.activate! }.to raise_error("boom")
      expect(record.reload.active).to be(false)

      invalid = stamped_class do
        activatable_by
        validates :name, presence: true
        attr_reader :after_ran

        def after_deactivate = @after_ran = true
      end
      record = invalid.new(active: true)
      record.save(validate: false)
      expect(record.deactivate!).to be(false)
      expect(record.after_ran).to be_nil
      expect(record.reload.active).to be(true)
    end

    it "timestamps: true stamps activated_at / deactivated_at on each transition (toggle included)" do
      klass = stamped_class { activatable_by timestamps: true }
      record = klass.create!(name: "x", active: false)
      expect(record.activated_at).to be_nil

      record.activate!
      expect(record.activated_at).to be_within(2.seconds).of(Time.current)
      expect(record.deactivated_at).to be_nil
      first_activation = record.activated_at

      record.deactivate!
      expect(record.deactivated_at).to be_within(2.seconds).of(Time.current)
      expect(record.activated_at).to eq(first_activation) # history of the last activation is kept

      record.update_columns(activated_at: 1.day.ago)
      record.toggle_active!
      expect(record.active?).to be(true)
      expect(record.reload.activated_at).to be_within(2.seconds).of(Time.current)
    end

    it "timestamps: accepts a Hash to rename or drop a side, and validates it" do
      klass = stamped_class { activatable_by timestamps: { activated_at: :enabled_at, deactivated_at: nil } }
      record = klass.create!(active: false)
      record.activate!
      expect(record.enabled_at).to be_within(2.seconds).of(Time.current)
      expect(record.activated_at).to be_nil
      expect(record.deactivate!).to be(true)
      expect(record.deactivated_at).to be_nil

      expect { stamped_class { activatable_by timestamps: { activated_at: :nope } } }
        .to raise_error(ArgumentError, /'nope' does not exist/)
      expect { stamped_class { activatable_by timestamps: :yes } }
        .to raise_error(ArgumentError, /timestamps: must be true, false or a Hash/)
      expect { stamped_class { activatable_by timestamps: { bogus: :enabled_at } } }
        .to raise_error(ArgumentError, /unknown timestamps: key\(s\): bogus/)
      # A truthy non-column value used to raise NoMethodError on to_sym.
      expect { stamped_class { activatable_by timestamps: { activated_at: true } } }
        .to raise_error(ArgumentError, /timestamps: activated_at must be a column name/)
    end

    it "batch verbs stamp on the single-UPDATE fast path and run the hooks on the per-record path" do
      fast = stamped_class { activatable_by timestamps: true }
      fast.create!(active: false)
      fast.create!(active: nil)
      expect(fast.activate_all).to eq(2)
      expect(fast.pluck(:activated_at).compact.size).to eq(2)
      expect(fast.deactivate_all).to eq(2)
      expect(fast.pluck(:deactivated_at).compact.size).to eq(2)

      hooked = stamped_class do
        activatable_by timestamps: true
        def self.log = (@log ||= [])
        def after_activate = self.class.log << id
      end
      hooked.delete_all
      hooked.create!(active: false)
      hooked.create!(active: false)
      expect(hooked.activate_all).to eq(2)
      expect(hooked.log.size).to eq(2)
      expect(hooked.pluck(:activated_at).compact.size).to eq(2)
    end

    # The hooks used to be dispatched with public_send: a private override
    # raised NoMethodError, and the batch verb (which still reads a private
    # override as overridden, so it leaves the fast path) rolled the batch back.
    it "calls private hook overrides on the per-record and on the batch path" do
      klass = stamped_class do
        activatable_by
        def self.log = (@log ||= [])

        private

        def before_activate = self.class.log << [:before_activate, id]
        def after_deactivate = self.class.log << [:after_deactivate, id]
      end
      expect(klass.private_method_defined?(:before_activate)).to be(true)
      expect(klass.private_method_defined?(:after_deactivate)).to be(true)

      record = klass.create!(active: false)
      expect(record.activate!).to be(true)
      expect(record.reload.active).to be(true)
      expect(record.deactivate!).to be(true)
      expect(klass.log).to eq([[:before_activate, record.id], [:after_deactivate, record.id]])

      other = klass.create!(active: false)
      expect(klass.activate_all).to eq(2)
      expect(klass.pluck(:active).uniq).to eq([true])
      expect(klass.log.last(2)).to contain_exactly([:before_activate, record.id], [:before_activate, other.id])
      expect(klass.deactivate_all).to eq(2)
      expect(klass.log.last(2)).to contain_exactly([:after_deactivate, record.id], [:after_deactivate, other.id])
    end
  end
end
