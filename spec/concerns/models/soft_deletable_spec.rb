# frozen_string_literal: true

require 'spec_helper'

describe ConcernsOnRails::SoftDeletable do
  # Setup a dummy model for testing
  let(:dummy_class) do
    Class.new(ActiveRecord::Base) do
      self.table_name = 'dummy_soft_deletables'
      include ConcernsOnRails::SoftDeletable

      soft_deletable_by :deleted_at

      # For callback test
      attr_accessor :callback_log

      def before_soft_delete
        @callback_log ||= []
        @callback_log << :before_soft_delete
      end

      def after_soft_delete
        @callback_log ||= []
        @callback_log << :after_soft_delete
      end

      def before_restore
        @callback_log ||= []
        @callback_log << :before_restore
      end

      def after_restore
        @callback_log ||= []
        @callback_log << :after_restore
      end
    end
  end

  before(:all) do
    ActiveRecord::Schema.define do
      create_table :dummy_soft_deletables, force: true do |t|
        t.string :name
        t.datetime :deleted_at
        t.timestamps null: false
      end
    end
  end

  after(:all) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  let!(:record) { dummy_class.create!(name: 'test') }

  describe '.soft_deletable_by' do
    it 'raises error if field does not exist' do
      expect do
        Class.new(ActiveRecord::Base) do
          self.table_name = 'dummy_soft_deletables'
          include ConcernsOnRails::SoftDeletable

          soft_deletable_by :not_a_field
        end
      end.to raise_error(ArgumentError)
    end
    it 'sets the soft delete field' do
      expect(dummy_class.soft_delete_field).to eq(:deleted_at)
    end
  end

  describe 'scopes' do
    it 'returns active/without_deleted records' do
      expect(dummy_class.active).to include(record)
      expect(dummy_class.without_deleted).to include(record)
    end
    it 'returns no soft_deleted records initially' do
      expect(dummy_class.soft_deleted).to be_empty
    end
  end

  describe '#soft_delete!' do
    it 'sets the deleted_at field' do
      expect { record.soft_delete! }.to change { record.reload.deleted_at }.from(nil)
      expect(record).to be_deleted
      expect(record).to be_is_soft_deleted
      expect(record).to be_soft_deleted
    end
    it 'runs callbacks' do
      record.callback_log = []
      record.soft_delete!
      expect(record.callback_log).to include(:before_soft_delete, :after_soft_delete)
    end
    it 'touches updated_at if enabled' do
      t = record.updated_at
      travel(1.second) { record.soft_delete! }
      expect(record.reload.updated_at).to be > t
    end
    it 'does not touch updated_at if disabled' do
      dummy_class.soft_deletable_by :deleted_at, touch: false
      t = record.updated_at
      travel(1.second) { record.soft_delete! }
      expect(record.reload.updated_at).to eq t
    end
  end

  describe '#restore!' do
    before { record.soft_delete! }
    it 'restores the record' do
      expect { record.restore! }.to change { record.reload.deleted_at }.to(nil)
      expect(record).not_to be_deleted
    end
    it 'runs callbacks' do
      record.callback_log = []
      record.restore!
      expect(record.callback_log).to include(:before_restore, :after_restore)
    end
    it 'touches updated_at if enabled' do
      t = record.updated_at
      travel(1.second) { record.restore! }
      expect(record.reload.updated_at).to be > t
    end
    it 'does not touch updated_at if disabled' do
      dummy_class.soft_deletable_by :deleted_at, touch: false
      record.soft_delete!
      t = record.updated_at
      travel(1.second) { record.restore! }
      expect(record.reload.updated_at).to eq t
    end
  end

  describe '#really_delete!' do
    it 'destroys the record' do
      expect { record.really_delete! }.to change { dummy_class.count }.by(-1)
    end
  end

  describe '#is_really_deleted?' do
    it 'returns false if record exists' do
      expect(record.is_really_deleted?).to be false
    end
    it 'returns true after destroy' do
      record.really_delete!
      expect(record.is_really_deleted?).to be true
    end
  end

  context 'with multiple models using SoftDeletable' do
    let(:other_class) do
      Class.new(ActiveRecord::Base) do
        self.table_name = 'other_soft_deletables'
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :removed_on
      end
    end
    before(:all) do
      ActiveRecord::Schema.define do
        create_table :other_soft_deletables, force: true do |t|
          t.string :name
          t.datetime :removed_on
          t.timestamps null: false
        end
      end
    end
    let!(:other) { other_class.create!(name: 'other') }
    it 'does not interfere with other models' do
      expect(other_class.active).to include(other)
      other.soft_delete!
      expect(other_class.soft_deleted).to include(other)
    end
  end

  context 'with custom soft delete field' do
    let(:custom_class) do
      Class.new(ActiveRecord::Base) do
        self.table_name = 'custom_soft_deletables'
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :removed_on
      end
    end
    before(:all) do
      ActiveRecord::Schema.define do
        create_table :custom_soft_deletables, force: true do |t|
          t.string :name
          t.datetime :removed_on
          t.timestamps null: false
        end
      end
    end
    let!(:custom) { custom_class.create!(name: 'custom') }
    it 'soft deletes and restores using custom field' do
      expect { custom.soft_delete! }.to change { custom.reload.removed_on }.from(nil)
      expect(custom_class.soft_deleted).to include(custom)
      expect { custom.restore! }.to change { custom.reload.removed_on }.to(nil)
      expect(custom_class.active).to include(custom)
    end
  end

  context 'callbacks order' do
    it 'calls callbacks in order' do
      record.callback_log = []
      record.soft_delete!
      expect(record.callback_log).to eq(%i[before_soft_delete after_soft_delete])
      record.callback_log = []
      record.restore!
      expect(record.callback_log).to eq(%i[before_restore after_restore])
    end
  end

  context 'idempotency' do
    it 'soft_delete! twice does not error and does not change deleted_at again' do
      record.soft_delete!
      record.deleted_at
      sleep 1
      expect { record.soft_delete! }.not_to change { record.reload.deleted_at }
    end
    it 'restore! twice does not error and does not change deleted_at' do
      record.restore!
      expect { record.restore! }.not_to change { record.reload.deleted_at }
    end
  end

  context 'return values' do
    it 'returns true on successful soft_delete!' do
      expect(record.soft_delete!).to eq(true)
    end
    it 'returns true on successful restore!' do
      record.soft_delete!
      expect(record.restore!).to eq(true)
    end
  end

  context 'validation/failure cases' do
    it 'soft_delete! still works if other validations fail' do
      allow(record).to receive(:update).and_return(false)
      expect(record.soft_delete!).to eq(false)
    end
    it 'restore! still works if other validations fail' do
      record.soft_delete!
      allow(record).to receive(:update).and_return(false)
      expect(record.restore!).to eq(false)
    end
  end

  context 'scope chaining' do
    it 'returns no record when chaining soft_deleted and active' do
      record.soft_delete!
      # Chaining these scopes is not meaningful due to unscope usage, so test intersection instead
      expect(dummy_class.soft_deleted & dummy_class.active).to be_empty
    end
  end

  context 'STI (Single Table Inheritance)' do
    before do
      ActiveRecord::Schema.define do
        create_table :sti_models, force: true do |t|
          t.string :type
          t.string :name
          t.datetime :deleted_at
          t.timestamps null: false
        end
      end

      class StiModel < ActiveRecord::Base
        self.table_name = 'sti_models'
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :deleted_at
      end

      class ChildModel < StiModel; end
    end

    it 'works for subclasses' do
      child = ChildModel.create!(name: 'child')
      expect(ChildModel.active).to include(child)
      child.soft_delete!
      expect(ChildModel.soft_deleted).to include(child)
      child.restore!
      expect(ChildModel.active).to include(child)
    end
  end

  context 'with default_scope enabled' do
    let(:scoped_class) do
      Class.new(ActiveRecord::Base) do
        self.table_name = 'scoped_soft_deletables'
        include ConcernsOnRails::SoftDeletable

        default_scope { without_deleted }
        soft_deletable_by :deleted_at
      end
    end
    before(:all) do
      ActiveRecord::Schema.define do
        create_table :scoped_soft_deletables, force: true do |t|
          t.string :name
          t.datetime :deleted_at
          t.timestamps null: false
        end
      end
    end
    let!(:active) { scoped_class.create!(name: 'active') }
    let!(:deleted) { scoped_class.create!(name: 'deleted', deleted_at: Time.zone.now) }
    it 'hides soft deleted records by default' do
      expect(scoped_class.all).to include(active)
      expect(scoped_class.all).not_to include(deleted)
    end
    it 'can find soft deleted records with unscoped' do
      expect(scoped_class.unscoped.all).to include(deleted)
    end
    it 'still allows soft_delete! and restore! to work' do
      expect { active.soft_delete! }.to change { active.reload.deleted_at }.from(nil)
      expect(scoped_class.all).not_to include(active)
      expect { active.restore! }.to change { active.reload.deleted_at }.to(nil)
      expect(scoped_class.all).to include(active)
    end
  end

  describe '.destroy_all' do
    let!(:record1) { dummy_class.create!(name: 'foo') }
    let!(:record2) { dummy_class.create!(name: 'bar') }

    it 'soft deletes all records created in this test' do
      dummy_class.destroy_all
      expect(record1.reload).to be_deleted
      expect(record2.reload).to be_deleted
    end
  end

  describe '.really_destroy_all' do
    before do
      dummy_class.create!(name: 'baz')
      dummy_class.create!(name: 'qux')
    end

    it 'hard deletes all records' do
      expect do
        dummy_class.really_destroy_all
      end.to change { dummy_class.count }.to(0)
    end
  end

  describe '1.9 scopes and bulk restore' do
    let!(:kept)    { dummy_class.create!(name: 'kept') }
    let!(:removed) { dummy_class.create!(name: 'removed').tap(&:soft_delete!) }

    it '.with_deleted returns both deleted and non-deleted' do
      expect(dummy_class.with_deleted).to include(kept, removed)
    end

    it '.only_deleted returns just the deleted records' do
      expect(dummy_class.only_deleted).to include(removed)
      expect(dummy_class.only_deleted).not_to include(kept)
    end

    it '.deleted_within returns recently deleted, excludes older ones' do
      old = nil
      travel_to(3.days.ago) { old = dummy_class.create!(name: 'old').tap(&:soft_delete!) }
      expect(dummy_class.deleted_within(1.day)).to include(removed)
      expect(dummy_class.deleted_within(1.day)).not_to include(old)
    end

    it '.deleted_within uses a bounded >= predicate (no endless range; Rails 5.x safe)' do
      sql = dummy_class.deleted_within(1.day).to_sql
      expect(sql).to include('>=')
      expect(sql).to include('deleted_at')
    end

    it '.restore_all restores every soft-deleted record' do
      dummy_class.restore_all
      expect(removed.reload).not_to be_deleted
    end
  end

  describe 'default_scope option (1.12)' do
    before(:all) do
      ActiveRecord::Schema.define do
        create_table :ds_hidden_softs, force: true do |t|
          t.string :name
          t.datetime :deleted_at
        end
        create_table :ds_visible_softs, force: true do |t|
          t.string :name
          t.datetime :deleted_at
        end
      end
    end

    it 'hides soft-deleted rows from .all by default' do
      klass = Class.new(ActiveRecord::Base) do
        self.table_name = 'ds_hidden_softs'
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :deleted_at
      end
      klass.create!(name: 'a')
      klass.create!(name: 'b', deleted_at: Time.zone.now)
      expect(klass.count).to eq(1)
      expect(klass.unscoped.count).to eq(2)
    end

    it 'shows soft-deleted rows from .all when default_scope: false' do
      klass = Class.new(ActiveRecord::Base) do
        self.table_name = 'ds_visible_softs'
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :deleted_at, default_scope: false
      end
      klass.create!(name: 'a')
      klass.create!(name: 'b', deleted_at: Time.zone.now)
      expect(klass.count).to eq(2)
      expect(klass.without_deleted.count).to eq(1)
    end
  end

  describe '.soft_delete_all (1.12)' do
    let!(:r1) { dummy_class.create!(name: 'x') }
    let!(:r2) { dummy_class.create!(name: 'y') }

    it 'soft-deletes every matching record and returns the count' do
      expected = dummy_class.count # r1 + r2 + the outer let!(:record)
      expect(dummy_class.soft_delete_all).to eq(expected)
      expect(r1.reload).to be_deleted
      expect(r2.reload).to be_deleted
    end

    it 'raises RecordNotSaved and rolls the whole batch back when one record fails (1.22)' do
      allow_any_instance_of(dummy_class).to receive(:soft_delete!) do |rec|
        rec.name != 'y' && rec.update_column(:deleted_at, Time.zone.now)
      end
      expect { dummy_class.soft_delete_all }.to raise_error(ActiveRecord::RecordNotSaved, /failed to soft-delete/)
      expect(r1.reload).not_to be_deleted
    end
  end

  describe 'transactional hooks (1.12)' do
    let(:raising_class) do
      Class.new(ActiveRecord::Base) do
        self.table_name = 'dummy_soft_deletables'
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :deleted_at, default_scope: false

        def after_soft_delete
          raise 'boom'
        end
      end
    end

    it 'rolls the timestamp back when an after hook raises' do
      rec = raising_class.create!(name: 'z')
      expect { rec.soft_delete! }.to raise_error('boom')
      expect(rec.reload.deleted_at).to be_nil
    end
  end

  describe "scope affixing" do
    before do
      ActiveRecord::Schema.define do
        create_table :affixed_docs, force: true do |t|
          t.string :name
          t.datetime :deleted_at
        end
      end
    end

    def affixed_class(**options)
      Class.new(TestModel) do
        self.table_name = "affixed_docs"
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :deleted_at, **options
      end
    end

    it "keeps the default names with no affix" do
      klass = affixed_class
      expect(klass).to respond_to(:without_deleted)
      expect(klass).to respond_to(:only_deleted)
    end

    it "defines affixed names and removes the defaults" do
      klass = affixed_class(prefix: :doc)

      expect(klass).to respond_to(:doc_without_deleted)
      expect(klass).to respond_to(:doc_soft_deleted)
      expect(klass).not_to respond_to(:without_deleted)
      expect(klass).not_to respond_to(:active)
    end

    it "keeps the default_scope filtering deleted rows under an affix" do
      klass = affixed_class(prefix: :doc)
      live = klass.create!(name: "live")
      gone = klass.create!(name: "gone")
      gone.soft_delete!

      expect(klass.all.pluck(:id)).to eq([live.id])
      expect(klass.doc_with_deleted.count).to eq(2)
      expect(klass.doc_soft_deleted.pluck(:id)).to eq([gone.id])
    end

    it "keeps only_deleted delegating to soft_deleted under an affix" do
      klass = affixed_class(prefix: :doc)
      gone = klass.create!(name: "gone")
      gone.soft_delete!

      expect(klass.doc_only_deleted.pluck(:id)).to eq([gone.id])
    end

    it "keeps deleted_within working under an affix" do
      klass = affixed_class(prefix: :doc)
      gone = klass.create!(name: "gone")
      gone.soft_delete!

      expect(klass.doc_deleted_within(1.day).pluck(:id)).to eq([gone.id])
      expect(klass.doc_deleted_within(0.seconds).count).to eq(0)
    end

    it "honours default_scope: false under an affix" do
      klass = affixed_class(prefix: :doc, default_scope: false)
      klass.create!(name: "live")
      klass.create!(name: "gone").soft_delete!

      expect(klass.all.count).to eq(2)
      expect(klass.doc_without_deleted.count).to eq(1)
    end

    it "restores records via restore_all under an affix" do
      klass = affixed_class(prefix: :doc)
      gone = klass.create!(name: "gone")
      gone.soft_delete!

      expect(klass.restore_all).to eq(1)
      expect(gone.reload).not_to be_deleted
    end
  end
  # `restore_all` and `really_destroy_all` used to route through the
  # `soft_deleted` scope / a bare `unscope(where: deleted_at)`, which peels the
  # default scope's `deleted_at IS NULL` off — and, with it, every predicate the
  # CALLER put on that column. `deleted_within(1.hour).restore_all` therefore
  # restored the whole trash can. Same defect `publish_all` fixed in 1.27.
  describe 'restore_all / really_destroy_all keep a caller predicate on the soft-delete column' do
    before(:all) do
      ActiveRecord::Schema.define do
        create_table :trash_restorables, force: true do |t|
          t.string :name
          t.string :kind
          t.datetime :deleted_at
          t.timestamps null: false
        end
      end
    end

    # touch: false + no overridden hooks => single-UPDATE fast path
    let(:fast_class) do
      Class.new(ActiveRecord::Base) do
        self.table_name = 'trash_restorables'
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :deleted_at, touch: false
      end
    end

    # touch: true (default) => streaming per-record path through restore!
    let(:per_record_class) do
      Class.new(ActiveRecord::Base) do
        self.table_name = 'trash_restorables'
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :deleted_at
      end
    end

    let(:visible_class) do
      Class.new(ActiveRecord::Base) do
        self.table_name = 'trash_restorables'
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :deleted_at, touch: false, default_scope: false
      end
    end

    # A host model with its OWN default scope on top of the soft-delete one.
    let(:tenant_class) do
      Class.new(ActiveRecord::Base) do
        self.table_name = 'trash_restorables'
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :deleted_at, touch: false
        default_scope { where(kind: 'a') }
      end
    end

    def seed(klass)
      klass.unscoped.delete_all
      old = nil
      travel_to(3.days.ago) { old = klass.create!(name: 'old', kind: 'a').tap(&:soft_delete!) }
      recent = klass.create!(name: 'recent', kind: 'a').tap(&:soft_delete!)
      live = klass.create!(name: 'live', kind: 'a')
      other = klass.create!(name: 'other-kind', kind: 'b').tap(&:soft_delete!)
      [old, recent, live, other]
    end

    def deleted?(klass, record)
      klass.unscoped.find(record.id).deleted_at.present?
    end

    %i[fast_class per_record_class].each do |variant|
      context "on the #{variant.to_s.tr('_', ' ')} path" do
        let(:klass) { send(variant) }

        it 'deleted_within(...).restore_all restores only the recent trash' do
          old, recent, _live, other = seed(klass)
          expect(klass.deleted_within(1.day).restore_all).to eq(2)
          expect(deleted?(klass, recent)).to be(false)
          expect(deleted?(klass, other)).to be(false)
          expect(deleted?(klass, old)).to be(true)
        end

        it 'where(deleted_at: range).restore_all honours the range' do
          old, recent, _live, other = seed(klass)
          expect(klass.where(deleted_at: 1.day.ago..Time.zone.now).restore_all).to eq(2)
          expect(deleted?(klass, recent)).to be(false)
          expect(deleted?(klass, other)).to be(false)
          expect(deleted?(klass, old)).to be(true)
        end

        it 'soft_deleted.where(...).restore_all honours a predicate added after the scope' do
          old, recent, _live, other = seed(klass)
          expect(klass.soft_deleted.where(klass.arel_table[:deleted_at].gteq(1.day.ago)).restore_all).to eq(2)
          expect(deleted?(klass, recent)).to be(false)
          expect(deleted?(klass, other)).to be(false)
          expect(deleted?(klass, old)).to be(true)
        end

        it 'keeps a caller predicate on another column' do
          old, recent, = seed(klass)
          expect(klass.where(name: 'old').restore_all).to eq(1)
          expect(deleted?(klass, old)).to be(false)
          expect(deleted?(klass, recent)).to be(true)
        end

        it 'a bare restore_all on a default-scoped model still restores the whole trash can' do
          old, recent, live, other = seed(klass)
          expect(klass.restore_all).to eq(3)
          [old, recent, live, other].each { |r| expect(deleted?(klass, r)).to be(false) }
        end

        it 'returns 0 and touches nothing when the narrowed relation is empty' do
          seed(klass)
          expect(klass.where(name: 'nope').restore_all).to eq(0)
          expect(klass.soft_deleted.count).to eq(3)
        end
      end
    end

    it 'the fast path still collapses to a single UPDATE' do
      seed(fast_class)
      sql = []
      callback = ->(*, payload) { sql << payload[:sql] if payload[:sql] =~ /\AUPDATE/i }
      ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
        fast_class.deleted_within(1.day).restore_all
      end
      expect(sql.size).to eq(1)
      expect(sql.first).to match(/deleted_at.*>=/m)
    end

    it 'with default_scope: false a caller predicate on the column is honoured too' do
      old, recent, _live, other = seed(visible_class)
      expect(visible_class.where(deleted_at: 1.day.ago..Time.zone.now).restore_all).to eq(2)
      expect(deleted?(visible_class, recent)).to be(false)
      expect(deleted?(visible_class, other)).to be(false)
      expect(deleted?(visible_class, old)).to be(true)
    end

    it "preserves the host model's own default scope while peeling only the soft-delete one" do
      old, recent, _live, other = seed(tenant_class)
      expect(tenant_class.restore_all).to eq(2)
      expect(deleted?(tenant_class, old)).to be(false)
      expect(deleted?(tenant_class, recent)).to be(false)
      expect(deleted?(tenant_class, other)).to be(true) # kind 'b' is outside the tenant default scope
    end

    describe 'really_destroy_all' do
      it 'only_deleted.really_destroy_all purges the trash and nothing else' do
        _old, _recent, live, other = seed(fast_class)
        expect { fast_class.only_deleted.really_destroy_all }
          .to change { fast_class.unscoped.count }.from(4).to(1)
        expect(fast_class.unscoped.pluck(:name)).to eq(['live'])
        expect(fast_class.unscoped.where(id: [live.id, other.id]).count).to eq(1)
      end

      it 'a predicate on another column still hard-deletes soft-deleted rows too' do
        seed(fast_class)
        expect { fast_class.where(name: %w[old live]).really_destroy_all }
          .to change { fast_class.unscoped.count }.from(4).to(2)
        expect(fast_class.unscoped.pluck(:name)).to match_array(%w[recent other-kind])
      end

      it 'deleted_within(...).really_destroy_all purges only the recent trash' do
        seed(fast_class)
        fast_class.deleted_within(1.day).really_destroy_all
        expect(fast_class.unscoped.pluck(:name)).to match_array(%w[old live])
      end
    end
  end

  describe "cascade: (soft-deleting and restoring dependents)" do
    before(:all) do
      ActiveRecord::Schema.define do
        create_table :casc_posts, force: true do |t|
          t.string :title
          t.datetime :deleted_at, precision: 6
          t.timestamps null: false
        end
        create_table :casc_comments, force: true do |t|
          t.integer :casc_post_id
          t.string :body
          t.datetime :deleted_at, precision: 6
          t.timestamps null: false
        end
        create_table :casc_likes, force: true do |t|
          t.integer :casc_comment_id
          t.datetime :deleted_at, precision: 6
        end
        create_table :casc_covers, force: true do |t|
          t.integer :casc_post_id
          t.datetime :deleted_at, precision: 6
        end
        create_table :casc_tags, force: true do |t|
          t.integer :casc_post_id
          t.string :name
        end
      end
    end

    before do
      stub_const("CascLike", Class.new(ActiveRecord::Base) do
        self.table_name = "casc_likes"
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :deleted_at, touch: false
        belongs_to :casc_comment
      end)
      stub_const("CascComment", Class.new(ActiveRecord::Base) do
        self.table_name = "casc_comments"
        include ConcernsOnRails::SoftDeletable

        has_many :casc_likes, dependent: :destroy
        soft_deletable_by :deleted_at, cascade: :casc_likes
        belongs_to :casc_post

        attr_accessor :log

        def before_soft_delete
          (@log ||= []) << :before_soft_delete
        end

        def after_soft_delete
          (@log ||= []) << :after_soft_delete
        end
      end)
      stub_const("CascCover", Class.new(ActiveRecord::Base) do
        self.table_name = "casc_covers"
        include ConcernsOnRails::SoftDeletable

        soft_deletable_by :deleted_at
        belongs_to :casc_post
      end)
      stub_const("CascTag", Class.new(ActiveRecord::Base) do
        self.table_name = "casc_tags"
        belongs_to :casc_post
      end)
      stub_const("CascPost", Class.new(ActiveRecord::Base) do
        self.table_name = "casc_posts"
        include ConcernsOnRails::SoftDeletable

        has_many :casc_comments
        has_one :casc_cover
        has_many :casc_tags
        soft_deletable_by :deleted_at, cascade: %i[casc_comments casc_cover]
      end)
      %w[casc_posts casc_comments casc_likes casc_covers casc_tags].each do |table|
        ActiveRecord::Base.connection.execute("DELETE FROM #{table}")
      end
    end

    let!(:post) { CascPost.create!(title: "p") }
    let!(:comment) { CascComment.create!(casc_post: post, body: "c1") }
    let!(:like) { CascLike.create!(casc_comment: comment) }
    let!(:cover) { CascCover.create!(casc_post: post) }

    def deleted_at(klass, record)
      klass.unscoped.find(record.id).deleted_at
    end

    it "soft-deletes has_many and has_one dependents with the parent's exact timestamp, recursively" do
      post.soft_delete!(at: Time.utc(2026, 6, 1, 12, 0, 0.5r)) # travel_to truncates usec; at: carries it
      stamp = deleted_at(CascPost, post)
      expect(stamp).to eq(Time.utc(2026, 6, 1, 12, 0, 0.5r))
      expect(deleted_at(CascComment, comment)).to eq(stamp)
      expect(deleted_at(CascCover, cover)).to eq(stamp)
      expect(deleted_at(CascLike, like)).to eq(stamp) # through the comment's own cascade
    end

    it "runs the dependents' own hooks" do
      post.soft_delete!
      reloaded = CascComment.unscoped.find(comment.id)
      expect(reloaded.deleted_at).to be_present
      # hooks fire on the instances the cascade loaded; assert through a probe
      probe = CascComment.unscoped.find(comment.id)
      probe.restore!
      probe.soft_delete!
      expect(probe.log).to eq(%i[before_soft_delete after_soft_delete])
    end

    it "restore! restores the cascaded dependents but not one that was deleted independently earlier" do
      earlier = CascComment.create!(casc_post: post, body: "old")
      travel_to(Time.utc(2026, 5, 1)) { earlier.soft_delete! }
      travel_to(Time.utc(2026, 6, 1)) { post.soft_delete! }

      post.restore!
      expect(deleted_at(CascPost, post)).to be_nil
      expect(deleted_at(CascComment, comment)).to be_nil
      expect(deleted_at(CascCover, cover)).to be_nil
      expect(deleted_at(CascLike, like)).to be_nil
      expect(deleted_at(CascComment, earlier)).to eq(Time.utc(2026, 5, 1))
    end

    it "leaves already-deleted dependents' own timestamps alone when the parent is deleted" do
      earlier = CascComment.create!(casc_post: post, body: "old")
      travel_to(Time.utc(2026, 5, 1)) { earlier.soft_delete! }
      travel_to(Time.utc(2026, 6, 1)) { post.soft_delete! }
      expect(deleted_at(CascComment, earlier)).to eq(Time.utc(2026, 5, 1))
    end

    it "soft_delete!(at:) backdates, standalone and through the cascade" do
      post.soft_delete!(at: Time.utc(2020, 1, 1))
      expect(deleted_at(CascPost, post)).to eq(Time.utc(2020, 1, 1))
      expect(deleted_at(CascComment, comment)).to eq(Time.utc(2020, 1, 1))
    end

    it "shares the parent's transaction — a failing dependent rolls everything back" do
      failing = Class.new(CascComment) do
        def after_soft_delete
          raise "child boom"
        end
      end
      stub_const("CascComment", failing)
      CascPost.has_many :casc_comments, class_name: "CascComment"
      expect { post.soft_delete! }.to raise_error("child boom")
      expect(deleted_at(CascPost, post)).to be_nil
      expect(deleted_at(CascCover, cover)).to be_nil
    end

    it "disables the single-UPDATE fast paths so soft_delete_all / restore_all cascade too" do
      other = CascPost.create!(title: "q")
      other_comment = CascComment.create!(casc_post: other, body: "c2")
      expect(CascPost.soft_delete_all).to eq(2)
      expect(deleted_at(CascComment, comment)).to be_present
      expect(deleted_at(CascComment, other_comment)).to be_present
      expect(CascPost.restore_all).to eq(2)
      expect(deleted_at(CascComment, other_comment)).to be_nil
    end

    it "exposes the configured cascade" do
      expect(CascPost.soft_delete_cascade).to eq(%i[casc_comments casc_cover])
      expect(CascCover.soft_delete_cascade).to eq([])
    end

    it "rejects an unknown association, a belongs_to, a :through, and a non-SoftDeletable target at class load" do
      # A NAMED class: from inside an anonymous class body Rails cannot resolve
      # association targets (compute_type needs `name`), so the target check
      # would be deferred to cascade time instead of firing at class load.
      build = lambda do |cascade|
        klass = Class.new(ActiveRecord::Base)
        stub_const("CascValidation", klass)
        klass.class_eval do
          self.table_name = "casc_posts"
          include ConcernsOnRails::SoftDeletable

          has_many :casc_comments
          has_many :casc_tags
          has_many :casc_likes, through: :casc_comments
          belongs_to :owner, class_name: "CascPost", optional: true
          soft_deletable_by :deleted_at, cascade: cascade
        end
      end
      expect { build.call(:nope) }.to raise_error(ArgumentError, /cascade: 'nope' is not an association/)
      expect { build.call(:owner) }.to raise_error(ArgumentError, /cascade: 'owner' must be a has_many or has_one/)
      expect { build.call(:casc_likes) }.to raise_error(ArgumentError, /cascade: 'casc_likes'.*through/)
      expect do
        build.call(:casc_tags)
      end.to raise_error(ArgumentError, /cascade: 'casc_tags' targets CascTag, which does not include SoftDeletable/)
    end
  end
end
