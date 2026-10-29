require "spec_helper"

# STATE-11 (audit 2026-10-29, v1.33.0): a hooked verb on a NEW record, run
# inside a caller's transaction, whose after-hook vetoes rolls HookedWrite's
# savepoint back. Rails does not restore `@new_record` on a savepoint
# rollback, and HookedWrite snapshotted identity only for records that were
# persisted BEFORE the write — so the record came back `persisted?` with no id,
# and the next `save` ran `UPDATE ... WHERE id IS NULL`, reported success and
# wrote no row (StaleObjectError under lock_version).
describe "HookedWrite on a new record whose after-hook vetoes" do
  before do
    ActiveRecord::Schema.define do
      create_table :hw_plain, force: true do |t|
        t.string :title
        t.datetime :published_at
        t.boolean :active
        t.datetime :deleted_at
        t.string :status
      end
      create_table :hw_locked, force: true do |t|
        t.string :title
        t.datetime :published_at
        t.integer :lock_version, default: 0, null: false
      end
    end
  end

  after(:each) do
    %i[hw_plain hw_locked].each { |t| ActiveRecord::Base.connection.drop_table(t, if_exists: true) }
  end

  def publishable(table)
    Class.new(TestModel) do
      self.table_name = table.to_s
      include ConcernsOnRails::Publishable

      attr_accessor :veto

      def after_publish
        raise ActiveRecord::Rollback if veto
      end
    end
  end

  %i[hw_plain hw_locked].each do |table|
    context "publish! on #{table}" do
      let(:model) { publishable(table) }

      it "keeps the record new inside a caller transaction, and a later save! INSERTs exactly one row" do
        post = model.new(title: "a", veto: true)
        model.transaction do
          expect(post.publish!).to be(false)
          expect(post).to be_new_record
          expect(post).not_to be_persisted
          expect(post.id).to be_nil
          expect(post.save!).to be(true)
        end
        expect(model.count).to eq(1)
        expect(post).to be_persisted
        expect(post.id).not_to be_nil
      end

      it "lets the verb be retried inside the same transaction (one row, no StaleObjectError)" do
        post = model.new(title: "a", veto: true)
        model.transaction do
          expect(post.publish!).to be(false)
          post.veto = false
          expect(post.publish!).to be(true)
        end
        expect(model.count).to eq(1)
        expect(model.first.published_at).not_to be_nil
        expect(post).to be_persisted
      end

      it "is unchanged outside a transaction" do
        post = model.new(title: "a", veto: true)
        expect(post.publish!).to be(false)
        expect(post).to be_new_record
        expect(post.id).to be_nil
        post.veto = false
        expect(post.publish!).to be(true)
        expect(model.count).to eq(1)
      end

      it "leaves a record that was persisted before the write persisted, with its id" do
        post = model.create!(title: "a")
        post.veto = true
        model.transaction do
          expect(post.publish!).to be(false)
          expect(post).to be_persisted
          expect(post.id).not_to be_nil
          expect(post.previously_new_record?).to be(true) if post.respond_to?(:previously_new_record?)
        end
        expect(model.count).to eq(1)
        expect(model.first.published_at).to be_nil
      end
    end
  end

  it "keeps a user-assigned id on the new record" do
    model = publishable(:hw_plain)
    post = model.new(id: 4242, title: "a", veto: true)
    model.transaction do
      expect(post.publish!).to be(false)
      expect(post).to be_new_record
      expect(post.id).to eq(4242)
    end
    post.veto = false
    expect(post.publish!).to be(true)
    expect(model.find(4242).title).to eq("a")
  end

  it "covers a record created EARLIER in the caller's transaction (a veto must not turn it new again)" do
    model = publishable(:hw_plain)
    model.transaction do
      post = model.create!(title: "a")
      post.veto = true
      expect(post.publish!).to be(false)
      expect(post).to be_persisted
      post.veto = false
      expect(post.publish!).to be(true)
    end
    expect(model.count).to eq(1)
  end

  it "covers Activatable#activate!" do
    model = Class.new(TestModel) do
      self.table_name = "hw_plain"
      include ConcernsOnRails::Activatable

      def after_activate
        raise ActiveRecord::Rollback
      end
    end
    record = model.new(title: "a")
    model.transaction do
      expect(record.activate!).to be(false)
      expect(record).to be_new_record
      expect(record.id).to be_nil
      expect(record.save!).to be(true)
    end
    expect(model.count).to eq(1)
  end

  it "covers SoftDeletable#soft_delete!" do
    model = Class.new(TestModel) do
      self.table_name = "hw_plain"
      include ConcernsOnRails::SoftDeletable

      def after_soft_delete
        raise ActiveRecord::Rollback
      end
    end
    record = model.new(title: "a")
    model.transaction do
      expect(record.soft_delete!).to be(false)
      expect(record).to be_new_record
      expect(record.id).to be_nil
      expect(record.save!).to be(true)
    end
    expect(model.count).to eq(1)
  end

  context "a Stateable event" do
    let(:model) do
      Class.new(TestModel) do
        self.table_name = "hw_plain"
        include ConcernsOnRails::Stateable

        stateable_by :status, states: %i[draft published], default: :draft,
                              transitions: { publish: { from: :draft, to: :published } }
        attr_accessor :veto

        def after_transition(*)
          raise ActiveRecord::Rollback if veto
        end
      end
    end

    it "keeps the record new inside a caller transaction, and a later save! INSERTs one row" do
      record = model.new(title: "a", veto: true)
      model.transaction do
        expect(record.publish!).to be(false)
        expect(record).to be_new_record
        expect(record.id).to be_nil
        expect(record.status).to eq("draft")
        expect(record.save!).to be(true)
      end
      expect(model.count).to eq(1)
      expect(model.first.status).to eq("draft")
    end

    it "can be retried inside the same transaction" do
      record = model.new(title: "a", veto: true)
      model.transaction do
        expect(record.publish!).to be(false)
        record.veto = false
        expect(record.publish!).to be(true)
      end
      expect(model.count).to eq(1)
      expect(model.first.status).to eq("published")
    end
  end
end
