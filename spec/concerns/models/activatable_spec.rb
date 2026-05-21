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
end
