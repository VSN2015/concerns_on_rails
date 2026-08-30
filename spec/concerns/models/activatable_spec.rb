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
end
