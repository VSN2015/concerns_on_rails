require "spec_helper"

describe ConcernsOnRails::Hashable do
  before do
    ActiveRecord::Schema.define do
      create_table :orders, force: true do |t|
        t.string :name
        t.string :token
      end
    end

    class Order < TestModel
      include ConcernsOnRails::Hashable

      hashable_by :token
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end

    %i[Order UuidOrder IntOrder CustomOrder PresetOrder NoColumnOrder BadTypeOrder BadCustomOrder].each do |const|
      Object.send(:remove_const, const) if Object.const_defined?(const)
    end
  end

  describe "default :hex" do
    it "auto-generates a hex token of length*2 on create" do
      order = Order.create!(name: "Widget")
      expect(order.token).to match(/\A[0-9a-f]{32}\z/)
    end

    it "generates distinct values for different records" do
      a = Order.create!(name: "A")
      b = Order.create!(name: "B")
      expect(a.token).not_to eq(b.token)
    end

    it "does not overwrite a value supplied by the caller" do
      order = Order.create!(name: "Manual", token: "preset-value")
      expect(order.token).to eq("preset-value")
    end

    it "defines a regenerate_<field>! method that replaces and persists the value" do
      order = Order.create!(name: "Roll")
      original = order.token
      order.regenerate_token!
      expect(order.reload.token).not_to eq(original)
      expect(order.token).to match(/\A[0-9a-f]{32}\z/)
    end
  end

  describe "type: :uuid" do
    it "generates an RFC 4122 UUID string" do
      ActiveRecord::Schema.define do
        create_table :uuid_orders, force: true do |t|
          t.string :external_id
        end
      end

      class UuidOrder < TestModel
        include ConcernsOnRails::Hashable

        hashable_by :external_id, type: :uuid
      end

      order = UuidOrder.create!
      expect(order.external_id).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
    end
  end

  describe "type: :integer" do
    it "generates an integer with the configured digit length" do
      ActiveRecord::Schema.define do
        create_table :int_orders, force: true do |t|
          t.integer :code
        end
      end

      class IntOrder < TestModel
        include ConcernsOnRails::Hashable

        hashable_by :code, type: :integer, length: 6
      end

      100.times do
        order = IntOrder.create!
        expect(order.code).to be_a(Integer)
        expect(order.code).to be_between(0, 999_999)
      end
    end
  end

  describe "type: :custom" do
    it "samples only from the given alphabet and respects length" do
      ActiveRecord::Schema.define do
        create_table :custom_orders, force: true do |t|
          t.string :code
        end
      end

      alphabet = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

      class CustomOrder < TestModel
        include ConcernsOnRails::Hashable

        hashable_by :code, type: :custom, length: 8, alphabet: "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
      end

      order = CustomOrder.create!
      expect(order.code.length).to eq(8)
      expect(order.code.chars.all? { |c| alphabet.include?(c) }).to be true
    end
  end

  describe "validation" do
    it "raises if the field does not exist on the table" do
      ActiveRecord::Schema.define do
        create_table :no_column_orders, force: true do |t|
          t.string :name
        end
      end

      expect do
        class NoColumnOrder < TestModel
          include ConcernsOnRails::Hashable

          hashable_by :missing_field
        end
      end.to raise_error(ArgumentError, /does not exist in the database/)
    end

    it "raises on an unknown type" do
      ActiveRecord::Schema.define do
        create_table :bad_type_orders, force: true do |t|
          t.string :token
        end
      end

      expect do
        class BadTypeOrder < TestModel
          include ConcernsOnRails::Hashable

          hashable_by :token, type: :base64
        end
      end.to raise_error(ArgumentError, /unknown type/)
    end

    it "raises when :custom is used without an alphabet" do
      ActiveRecord::Schema.define do
        create_table :bad_custom_orders, force: true do |t|
          t.string :code
        end
      end

      expect do
        class BadCustomOrder < TestModel
          include ConcernsOnRails::Hashable

          hashable_by :code, type: :custom, length: 8
        end
      end.to raise_error(ArgumentError, /requires a non-empty alphabet/)
    end

    it "raises when length is not positive" do
      ActiveRecord::Schema.define do
        create_table :bad_length_orders, force: true do |t|
          t.string :token
        end
      end

      expect do
        Class.new(TestModel) do
          self.table_name = "bad_length_orders"
          include ConcernsOnRails::Hashable

          hashable_by :token, length: 0
        end
      end.to raise_error(ArgumentError, /length must be a positive integer/)
    end
  end
end
