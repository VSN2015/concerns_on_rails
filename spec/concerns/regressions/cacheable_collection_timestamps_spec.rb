require "spec_helper"
require "support/integration_harness"

# Audit 2026-10-09, HTTP-1. ActiveSupport 7.0 added Enumerable#maximum(key)
# (map(&key).max), so every Array answered respond_to?(:maximum) and took the
# branch meant for an ActiveRecord::Relation: members without #updated_at
# raised NoMethodError and a nil updated_at raised "comparison of Time with
# nil failed" -- a 500 on every request to the action, Rails 7.0 through 8.1.
describe "Cacheable stale_resource? on a collection" do
  let(:plain_item) { Struct.new(:id, :name) }
  let(:stamped_item) { Struct.new(:id, :updated_at) }

  def collection_controller(collection)
    IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Cacheable

      define_method(:index) do
        render(json: { ok: true }) if stale_resource?(collection)
      end
    end
  end

  def dispatch(collection)
    IntegrationHarness.dispatch(collection_controller(collection), :index)
  end

  it "renders an Array whose members have no updated_at (ETag only, no Last-Modified)" do
    result = nil
    expect { result = dispatch([plain_item.new(1, "a"), plain_item.new(2, "b")]) }.not_to raise_error

    expect(result.status).to eq(200)
    expect(result.header("ETag")).to start_with('W/"')
    expect(result.header("Last-Modified")).to be_nil
  end

  it "uses the newest non-nil timestamp of an Array with a nil updated_at member" do
    newest = Time.utc(2026, 3, 1, 12, 0, 0)
    items = [stamped_item.new(1, Time.utc(2026, 1, 1)), stamped_item.new(2, nil), stamped_item.new(3, newest)]

    result = nil
    expect { result = dispatch(items) }.not_to raise_error

    expect(result.status).to eq(200)
    expect(result.header("Last-Modified")).to eq(newest.httpdate)
  end

  it "renders a Hash resource (no member timestamps) without raising" do
    result = nil
    expect { result = dispatch({ "a" => 1, "b" => 2 }) }.not_to raise_error

    expect(result.status).to eq(200)
    expect(result.header("Last-Modified")).to be_nil
  end

  context "with ActiveRecord collections" do
    before do
      ActiveRecord::Schema.define do
        create_table :cacheable_collection_items, force: true do |t|
          t.string :name
          t.timestamps
        end
      end
    end

    after do
      ActiveRecord::Base.connection.drop_table(:cacheable_collection_items, if_exists: true)
    end

    let(:model) do
      Class.new(TestModel) { self.table_name = "cacheable_collection_items" }
    end

    let(:newest) { Time.utc(2026, 5, 4, 3, 2, 1) }

    before do
      model.create!(name: "old", updated_at: Time.utc(2026, 1, 1))
      model.create!(name: "new", updated_at: newest)
    end

    it "still folds a relation through SQL MAXIMUM(updated_at)" do
      relation = model.all
      expect(relation).to receive(:maximum).with(:updated_at).and_call_original

      result = dispatch(relation)

      expect(result.status).to eq(200)
      expect(result.header("Last-Modified")).to eq(newest.httpdate)
    end

    it "gives a loaded Array of records the same Last-Modified as the relation" do
      result = dispatch(model.all.to_a)

      expect(result.status).to eq(200)
      expect(result.header("Last-Modified")).to eq(newest.httpdate)
    end
  end
end
