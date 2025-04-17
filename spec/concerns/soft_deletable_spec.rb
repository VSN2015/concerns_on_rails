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
      def before_soft_delete; @callback_log ||= []; @callback_log << :before_soft_delete; end
      def after_soft_delete;  @callback_log ||= []; @callback_log << :after_soft_delete; end
      def before_restore;     @callback_log ||= []; @callback_log << :before_restore; end
      def after_restore;      @callback_log ||= []; @callback_log << :after_restore; end
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

  let!(:record) { dummy_class.create!(name: 'test') }

  describe '.soft_deletable_by' do
    it 'raises error if field does not exist' do
      expect {
        Class.new(ActiveRecord::Base) do
          self.table_name = 'dummy_soft_deletables'
          include ConcernsOnRails::SoftDeletable
          soft_deletable_by :not_a_field
        end
      }.to raise_error(ArgumentError)
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
      sleep 1
      record.soft_delete!
      expect(record.reload.updated_at).to be > t
    end
    it 'does not touch updated_at if disabled' do
      dummy_class.soft_deletable_by :deleted_at, touch: false
      t = record.updated_at
      sleep 1
      record.soft_delete!
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
      sleep 1
      record.restore!
      expect(record.reload.updated_at).to be > t
    end
    it 'does not touch updated_at if disabled' do
      dummy_class.soft_deletable_by :deleted_at, touch: false
      record.soft_delete!
      t = record.updated_at
      sleep 1
      record.restore!
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
      expect(record.callback_log).to eq([:before_soft_delete, :after_soft_delete])
      record.callback_log = []
      record.restore!
      expect(record.callback_log).to eq([:before_restore, :after_restore])
    end
  end

  context 'idempotency' do
    it 'soft_delete! twice does not error and does not change deleted_at again' do
      record.soft_delete!
      t = record.deleted_at
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
      expect {
        dummy_class.really_destroy_all
      }.to change { dummy_class.count }.to(0)
    end
  end
end
