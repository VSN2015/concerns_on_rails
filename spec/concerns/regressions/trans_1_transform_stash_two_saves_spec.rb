require "spec_helper"

# TRANS-1: the after_save stash was OVERWRITTEN, so a record saved twice in a
# transaction that rolled back got only the LAST save's per-save records back,
# and a retry ran a non-idempotent Proc on its own output ("x!" -> "x!!").
describe "TransformBackstop stash across two saves in one transaction (TRANS-1)" do
  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :trans_stash_posts, force: true do |t|
        t.string :title
        t.string :code
      end
    end
  end
  after { ActiveRecord::Base.connection.drop_table(:trans_stash_posts, if_exists: true) }

  def model(&body)
    klass = Class.new(TestModel) { self.table_name = "trans_stash_posts" }
    klass.class_eval(&body)
    klass
  end

  def save_twice_then_rollback(record)
    record.class.transaction do
      record.save!
      record.update!(title: "t")
      raise ActiveRecord::Rollback
    end
  end

  it "Sanitizable on: :write runs its Proc once on retry" do
    record = model do
      include ConcernsOnRails::Models::Sanitizable

      sanitizable :code, with: ->(v) { "#{v}!" }, on: :write
    end.new(code: "x")
    save_twice_then_rollback(record)
    record.save!
    expect(record.reload.code).to eq("x!")
  end

  it "Normalizable runs its Proc once on retry" do
    record = model do
      include ConcernsOnRails::Models::Normalizable

      normalizable :code, with: ->(v) { "#{v}!" }
    end.new(code: "x")
    save_twice_then_rollback(record)
    record.save!
    expect(record.reload.code).to eq("x!")
  end

  it "still drops the stash when the transaction commits" do
    record = model do
      include ConcernsOnRails::Models::Normalizable

      normalizable :code, with: ->(v) { "#{v}!" }
    end.new(code: "x")
    record.class.transaction do
      record.save!
      record.update!(title: "t")
    end
    expect(record.instance_variable_defined?(:@concerns_on_rails_transform_stash)).to be(false)
    record.update!(code: "y")
    expect(record.reload.code).to eq("y!")
  end
end
