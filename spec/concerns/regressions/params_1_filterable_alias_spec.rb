require "spec_helper"

# Audit 2026-11-13, slice PARAMS. Each example asserts the CORRECT behaviour;
# a failure is the bug.
describe "Filterable alias_attribute fields (PARAMS-1)" do
  describe "PARAMS-1 Filterable on an alias_attribute field skips every typed guard" do
    before do
      ActiveRecord::Schema.define(verbose: false) do
        create_table :params_aliased, force: true do |t|
          t.string :name
          t.integer :stock
          t.integer :state
          t.datetime :happened_at
        end
      end
    end

    after { ActiveRecord::Base.connection.drop_table(:params_aliased) }

    let(:model) do
      Class.new(TestModel) do
        self.table_name = "params_aliased"
        if ActiveRecord.version >= Gem::Version.new("7.0")
          enum :state, { draft: 0, live: 1 }
        else
          enum state: { draft: 0, live: 1 }
        end
        alias_attribute :qty, :stock
        alias_attribute :phase, :state
        alias_attribute :at, :happened_at
      end
    end

    let(:controller_class) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable

        filter_by :qty, :stock, :phase, :state, :at, :happened_at, operators: true
      end
    end

    before do
      model.create!(name: "five", stock: 5, state: :draft, happened_at: Time.utc(2026, 1, 1))
      model.create!(name: "ten", stock: 10, state: :live, happened_at: Time.utc(2026, 2, 1))
      model.create!(name: "blank", stock: 1, state: nil, happened_at: Time.utc(2025, 2, 1))
    end

    def names(params)
      rel = controller_class.new(params: params).filtered(model.all)
      rel.pluck(:name).sort
    end

    it "PARAMS-1 reads a numeric operand exactly through the alias, as through the column" do
      expect(names(stock_gt: "1e1")).to eq([]) # control: the real column is exact
      expect(names(qty_gt: "1e1")).to eq([]) # bug: `stock > 1` => ["five", "ten"]
      expect(names(qty: "5.5")).to eq([]) # bug: `stock = 5` => ["five"]
      expect(names(qty_lt: "5.5")).to eq(%w[blank five]) # bug: `stock < 5` => ["blank"]
      expect(names(qty_lt: "99999999999999999999")).to eq(%w[blank five ten]) # bug: 1=0 => []
    end

    it "PARAMS-1 drops an unknown enum label through the alias instead of matching IS NULL" do
      expect(names(state: "drfat")).to eq([]) # control
      expect(names(phase: "drfat")).to eq([]) # bug: `state IS NULL` => ["blank"]
    end

    it "PARAMS-1 refuses a non-date operand on an aliased datetime column" do
      expect(names(happened_at_gte: 12_345)).to eq([]) # control
      expect(names(at_gte: 12_345)).to eq([]) # bug: binds 12345, SQLite returns every row
    end
  end
end
