require "spec_helper"

# Three concerns each define a `.active` scope. Before 1.27 the last one
# included silently won and there was no way out on SoftDeletable's side.
describe "scope-name collisions across concerns" do
  before do
    ActiveRecord::Schema.define do
      create_table :memberships, force: true do |t|
        t.boolean :active
        t.datetime :expires_at
        t.datetime :deleted_at
      end
    end

    stub_const("Membership", Class.new(TestModel) do
      self.table_name = "memberships"

      include ConcernsOnRails::SoftDeletable
      include ConcernsOnRails::Activatable
      include ConcernsOnRails::Expirable

      soft_deletable_by :deleted_at, prefix: :trash, default_scope: false
      activatable_by :active, prefix: :flag
      expirable_by :expires_at, prefix: :term
    end)
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  it "gives each concern its own non-colliding scopes" do
    expect(Membership).to respond_to(:trash_without_deleted)
    expect(Membership).to respond_to(:flag_active)
    expect(Membership).to respond_to(:term_active)
    expect(Membership).not_to respond_to(:active)
  end

  it "returns the right rows from each affixed scope" do
    healthy = Membership.create!(active: true, expires_at: 1.day.from_now, deleted_at: nil)
    flagged_off = Membership.create!(active: false, expires_at: 1.day.from_now, deleted_at: nil)
    lapsed = Membership.create!(active: true, expires_at: 1.day.ago, deleted_at: nil)
    trashed = Membership.create!(active: true, expires_at: 1.day.from_now, deleted_at: Time.zone.now)

    expect(Membership.flag_active.pluck(:id)).to match_array([healthy.id, lapsed.id, trashed.id])
    expect(Membership.flag_inactive.pluck(:id)).to eq([flagged_off.id])
    expect(Membership.term_active.pluck(:id)).to match_array([healthy.id, flagged_off.id, trashed.id])
    expect(Membership.term_expired.pluck(:id)).to eq([lapsed.id])
    expect(Membership.trash_soft_deleted.pluck(:id)).to eq([trashed.id])
    expect(Membership.trash_without_deleted.pluck(:id)).to match_array([healthy.id, flagged_off.id, lapsed.id])
  end

  it "composes the three affixed scopes in one chain" do
    healthy = Membership.create!(active: true, expires_at: 1.day.from_now, deleted_at: nil)
    Membership.create!(active: true, expires_at: 1.day.ago, deleted_at: nil)

    result = Membership.trash_without_deleted.flag_active.term_active
    expect(result.pluck(:id)).to eq([healthy.id])
  end
end
