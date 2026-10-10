# Regression (audit 2026-10-10, SCOPE-8): friendly_id supports a multi-column
# scope (`scope: [:account_id, :locale]`), but sluggable_by called `to_sym` on
# the Array, so declaring the class raised NoMethodError at boot.
RSpec.describe "Sluggable with a multi-column scope:" do
  before do
    ActiveRecord::Schema.define do
      create_table :multi_scope_accounts, force: true
      create_table :multi_scope_pages, force: true do |t|
        t.string :title
        t.string :slug
        t.integer :multi_scope_account_id
        t.string :locale
      end
    end
  end

  after do
    %i[multi_scope_pages multi_scope_accounts].each do |table|
      ActiveRecord::Base.connection.drop_table(table, if_exists: true)
    end
  end

  def page_class(scope)
    Class.new(TestModel) do
      self.table_name = "multi_scope_pages"
      include ConcernsOnRails::Models::Sluggable

      sluggable_by :title, scope: scope
    end
  end

  it "accepts an Array of columns and keeps slugs unique per combination" do
    klass = page_class(%i[multi_scope_account_id locale])

    en = klass.create!(title: "About", multi_scope_account_id: 1, locale: "en")
    de = klass.create!(title: "About", multi_scope_account_id: 1, locale: "de")
    other = klass.create!(title: "About", multi_scope_account_id: 2, locale: "en")
    clash = klass.create!(title: "About", multi_scope_account_id: 1, locale: "en")

    expect([en.slug, de.slug, other.slug]).to all(eq("about"))
    expect(clash.slug).not_to eq("about")
  end

  it "accepts an association alongside a column" do
    stub_const("MultiScopeAccount", Class.new(TestModel) { self.table_name = "multi_scope_accounts" })
    klass = stub_const("MultiScopePage", Class.new(TestModel) do
      self.table_name = "multi_scope_pages"
      belongs_to :multi_scope_account, optional: true
      include ConcernsOnRails::Models::Sluggable

      sluggable_by :title, scope: %i[multi_scope_account locale]
    end)
    account = MultiScopeAccount.create!

    first = klass.create!(title: "About", multi_scope_account: account, locale: "en")
    second = klass.create!(title: "About", multi_scope_account: account, locale: "de")
    clash = klass.create!(title: "About", multi_scope_account: account, locale: "en")

    expect([first.slug, second.slug]).to all(eq("about"))
    expect(clash.slug).not_to eq("about")
  end

  it "reports every missing scope column in one ArgumentError" do
    expect { page_class(%i[tenant_id region]) }
      .to raise_error(ArgumentError, /tenant_id.*region|region.*tenant_id/m)
  end
end
