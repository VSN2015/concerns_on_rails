require "spec_helper"

# Audit 2026-10-10 DATA-11: `Model.anonymize_all!` started from `all`, which
# carries SoftDeletable's default scope (and Publishable's under
# `default_scope: true`), so a class-level erasure sweep erased live rows only
# and returned a count that looked complete — a soft-deleted account, the
# typical right-to-erasure subject, kept its PII. Called on the model it now
# peels only the gem's own hiding predicates (as `reencrypt_all!` covers the
# whole table); called on a relation it still means exactly that relation.
describe "Anonymizable: Model.anonymize_all! and rows a gem default_scope hides" do
  before do
    ActiveRecord::Schema.define do
      create_table :anon_sweep_users, force: true do |t|
        t.string :name
        t.integer :tenant_id
        t.datetime :anonymized_at
        t.datetime :deleted_at
        t.datetime :published_at
      end
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.drop_table(:anon_sweep_users, if_exists: true)
  end

  def model(&declaration)
    klass = Class.new(TestModel) do
      self.table_name = "anon_sweep_users"
      include ConcernsOnRails::Models::SoftDeletable
      include ConcernsOnRails::Models::Anonymizable
    end
    klass.class_eval(&declaration)
    klass
  end

  let(:klass) do
    model do
      soft_deletable_by :deleted_at
      anonymizable :name, with: :redact
    end
  end

  it "erases soft-deleted rows too when called on the model" do
    live = klass.create!(name: "Alice")
    gone = klass.create!(name: "Bob")
    gone.soft_delete!

    expect(klass.anonymize_all!).to eq(2)
    expect(live.reload.name).to eq("[REDACTED]")
    expect(klass.unscoped.find(gone.id).name).to eq("[REDACTED]")
    expect(klass.unscoped.find(gone.id).deleted_at).not_to be_nil # still in the trash
  end

  it "erases rows Publishable's `default_scope: true` hides" do
    published = model do
      include ConcernsOnRails::Models::Publishable

      soft_deletable_by :deleted_at, default_scope: false
      publishable_by :published_at, default_scope: true
      anonymizable :name, with: :redact
    end
    draft = published.unscoped.create!(name: "Draft")
    shown = published.unscoped.create!(name: "Shown", published_at: 1.day.ago)

    expect(published.anonymize_all!).to eq(2)
    expect(published.unscoped.find(draft.id).name).to eq("[REDACTED]")
    expect(published.unscoped.find(shown.id).name).to eq("[REDACTED]")
  end

  it "keeps an application's own default scope (a tenant) in force" do
    tenanted = model do
      default_scope { where(tenant_id: 1) }
      soft_deletable_by :deleted_at
      anonymizable :name, with: :redact
    end
    mine = tenanted.create!(name: "Mine", tenant_id: 1)
    mine.soft_delete!
    theirs = tenanted.unscoped.create!(name: "Theirs", tenant_id: 2)

    expect(tenanted.anonymize_all!).to eq(1)
    expect(tenanted.unscoped.find(mine.id).name).to eq("[REDACTED]")
    expect(tenanted.unscoped.find(theirs.id).name).to eq("Theirs")
  end

  it "covers exactly the relation it is called on, default scope included" do
    live = klass.create!(name: "Alice")
    gone = klass.create!(name: "Bob")
    gone.soft_delete!

    expect(klass.where(name: %w[Alice Bob]).anonymize_all!).to eq(1)
    expect(live.reload.name).to eq("[REDACTED]")
    expect(klass.unscoped.find(gone.id).name).to eq("Bob")

    expect(klass.unscoped.where(id: gone.id).anonymize_all!).to eq(1)
    expect(klass.unscoped.find(gone.id).name).to eq("[REDACTED]")
  end

  it "still skips rows already stamped and counts only rows it erased" do
    klass.create!(name: "Alice").anonymize!
    gone = klass.create!(name: "Bob")
    gone.soft_delete!

    expect(klass.anonymize_all!).to eq(1)
    expect(klass.anonymize_all!).to eq(0)
  end
end
