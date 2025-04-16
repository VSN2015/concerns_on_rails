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
end