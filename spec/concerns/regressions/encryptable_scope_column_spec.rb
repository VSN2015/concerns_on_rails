require "spec_helper"
require "friendly_id"

# Regression (audit 2026-10-10, SCOPE-1): an `encryptable` column used as a
# Sequenceable `scope:` or a friendly_id (Sluggable) scope column holds
# ciphertext under a random IV, so every scoped query — the counter's MAX,
# friendly_id's slug-conflict check — serialized a fresh envelope that
# matched no stored row: two invoices in one region were both numbered 1,
# two pages in one tenant both got the slug "about". A unique index over the
# ciphertext cannot catch either. Refused at macro time from both
# declaration orders, as Searchable/Taggable already are.
RSpec.describe "Encryptable column as a Sequenceable / Sluggable scope" do
  before do
    ConcernsOnRails.encryption.key = "scope-guard-key-0123456789-abcdefgh"
    ActiveRecord::Schema.define do
      create_table :enc_scope_invoices, force: true do |t|
        t.integer :sequence
        t.text :region
        t.text :notes
        t.integer :account_id
      end
      create_table :enc_scope_tenants, force: true do |t|
        t.string :name
      end
      create_table :enc_scope_pages, force: true do |t|
        t.string :title
        t.string :slug
        t.text :tenant
        t.text :notes
        t.integer :enc_scope_tenant_id
        t.text :locale
      end
    end
  end

  after do
    ConcernsOnRails.encryption.key = nil
    %i[enc_scope_invoices enc_scope_tenants enc_scope_pages].each do |table|
      ActiveRecord::Base.connection.drop_table(table, if_exists: true)
    end
  end

  def invoice_model(&body)
    Class.new(TestModel) do
      self.table_name = "enc_scope_invoices"
      include ConcernsOnRails::Models::Encryptable
      include ConcernsOnRails::Models::Sequenceable

      class_eval(&body)
    end
  end

  # Named BEFORE the body runs: a belongs_to needs a class name.
  def page_model(&body)
    stub_const("EncScopePage", Class.new(TestModel)).tap do |klass|
      klass.class_eval do
        self.table_name = "enc_scope_pages"
        include ConcernsOnRails::Models::Encryptable
        include ConcernsOnRails::Models::Sluggable
      end
      klass.class_eval(&body)
    end
  end

  describe "Sequenceable scope:" do
    it "refuses an encrypted scope column declared before sequenceable_by" do
      expect do
        invoice_model do
          encryptable :region
          sequenceable_by :sequence, scope: :region
        end
      end.to raise_error(ArgumentError, /scope: :region is an `encryptable` column/)
    end

    it "refuses an encrypted column inside a multi-column scope" do
      expect do
        invoice_model do
          encryptable :region
          sequenceable_by :sequence, scope: %i[account_id region]
        end
      end.to raise_error(ArgumentError, /:region/)
    end

    it "refuses encrypting a column already used as a scope (sequenceable_by first)" do
      expect do
        invoice_model do
          sequenceable_by :sequence, scope: :region
          encryptable :region
        end
      end.to raise_error(ArgumentError, /':region' is a Sequenceable scope: column/)
    end

    it "keeps numbering per scope with other encrypted fields" do
      klass = invoice_model do
        encryptable :notes
        sequenceable_by :sequence, scope: :account_id
      end

      first = klass.create!(account_id: 1, notes: "a")
      second = klass.create!(account_id: 1, notes: "b")
      other = klass.create!(account_id: 2, notes: "c")

      expect([first.sequence, second.sequence, other.sequence]).to eq([1, 2, 1])
    end
  end

  describe "Sluggable / friendly_id scope" do
    it "refuses an encrypted scope column declared before sluggable_by" do
      expect do
        page_model do
          encryptable :tenant
          sluggable_by :title, scope: :tenant
        end
      end.to raise_error(ArgumentError, /scope: :tenant is an `encryptable` column/)
    end

    it "refuses an encrypted column inside a multi-column scope" do
      expect do
        page_model do
          encryptable :locale
          sluggable_by :title, scope: %i[enc_scope_tenant_id locale]
        end
      end.to raise_error(ArgumentError, /:locale/)
    end

    it "refuses an association scope whose foreign key is encrypted" do
      expect do
        page_model do
          belongs_to :enc_scope_tenant, optional: true
          encryptable :enc_scope_tenant_id, type: :integer
          sluggable_by :title, scope: :enc_scope_tenant
        end
      end.to raise_error(ArgumentError, /:enc_scope_tenant_id/)
    end

    it "refuses encrypting a column already used as the scope (sluggable_by first)" do
      expect do
        page_model do
          sluggable_by :title, scope: :tenant
          encryptable :tenant
        end
      end.to raise_error(ArgumentError, /':tenant' is a friendly_id scope column/)
    end

    it "refuses encrypting a bare friendly_id model's scope column" do
      expect do
        Class.new(TestModel) do
          self.table_name = "enc_scope_pages"
          extend FriendlyId
          include ConcernsOnRails::Models::Encryptable

          friendly_id :title, use: %i[slugged scoped], scope: :tenant
          encryptable :tenant
        end
      end.to raise_error(ArgumentError, /':tenant' is a friendly_id scope column/)
    end

    it "refuses to save a bare friendly_id model scoped by a column encrypted earlier" do
      klass = Class.new(TestModel) do
        self.table_name = "enc_scope_pages"
        extend FriendlyId
        include ConcernsOnRails::Models::Encryptable

        encryptable :tenant
        friendly_id :title, use: %i[slugged scoped], scope: :tenant
      end

      expect { klass.create!(title: "About", tenant: "acme") }
        .to raise_error(ArgumentError, /':tenant' is a friendly_id scope column/)
      expect(klass.unscoped.count).to eq(0)
    end

    it "keeps an association scope and other encrypted fields working" do
      stub_const("EncScopeTenant", Class.new(TestModel) { self.table_name = "enc_scope_tenants" })
      klass = page_model do
        belongs_to :enc_scope_tenant, optional: true
        encryptable :notes
        sluggable_by :title, scope: :enc_scope_tenant
      end
      tenant = EncScopeTenant.create!(name: "acme")

      first = klass.create!(title: "About", notes: "x", enc_scope_tenant: tenant)
      second = klass.create!(title: "About", notes: "y", enc_scope_tenant: tenant)

      expect(first.slug).to eq("about")
      expect(second.slug).not_to eq("about")
    end
  end
end
