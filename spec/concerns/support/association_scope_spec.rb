require "spec_helper"

describe ConcernsOnRails::Support::AssociationScope do
  before do
    ActiveRecord::Schema.define do
      create_table :scope_owners, force: true do |t|
        t.string :name
      end
      create_table :scope_children, force: true do |t|
        t.integer :scope_owner_id
        t.string :owner_type
        t.integer :owner_id
        t.string :type
        t.string :body
        t.boolean :visible, default: false
        t.integer :position
      end
    end

    stub_const("ScopeChild", Class.new(TestModel) do
      self.table_name = "scope_children"
      default_scope { where(visible: true).order(position: :desc) }
    end)
    stub_const("ScopeSpecialChild", Class.new(ScopeChild))
    stub_const("ScopeOwner", Class.new(TestModel) do
      self.table_name = "scope_owners"
      has_many :scope_children
      has_many :loud_children, -> { where(body: "loud") }, class_name: "ScopeChild"
      has_many :special_children, class_name: "ScopeSpecialChild"
      has_many :tagged_children, as: :owner, class_name: "ScopeChild"
      has_one :scope_child
    end)
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  let(:owner) { ScopeOwner.create!(name: "o") }
  let(:other) { ScopeOwner.create!(name: "x") }

  def child(**attributes)
    ScopeChild.unscoped.create!(**attributes)
  end

  def bodies(name)
    described_class.unfiltered(owner, name).map(&:body)
  end

  it "returns the children the target's default scope hides, in the default scope's order" do
    child(scope_owner_id: owner.id, body: "shown", visible: true, position: 1)
    child(scope_owner_id: owner.id, body: "hidden", visible: false, position: 2)
    child(scope_owner_id: other.id, body: "other", visible: true, position: 3)

    expect(owner.scope_children.map(&:body)).to eq(%w[shown])
    expect(bodies(:scope_children)).to eq(%w[hidden shown])
  end

  it "keeps the association's own scope" do
    child(scope_owner_id: owner.id, body: "loud")
    child(scope_owner_id: owner.id, body: "quiet")

    expect(bodies(:loud_children)).to eq(%w[loud])
  end

  it "keeps the STI type condition" do
    child(scope_owner_id: owner.id, body: "plain")
    ScopeSpecialChild.unscoped.create!(scope_owner_id: owner.id, body: "special")

    expect(bodies(:special_children)).to eq(%w[special])
  end

  it "keeps the polymorphic type" do
    child(owner_id: owner.id, owner_type: "ScopeOwner", body: "mine")
    child(owner_id: owner.id, owner_type: "Elsewhere", body: "theirs")

    expect(bodies(:tagged_children)).to eq(%w[mine])
  end

  # Rails memoizes the association's own scope half; a declared lambda that
  # reaches the target model captures the default scope in force when it is
  # first built, so a normal read beforehand leaked the default scope in.
  describe "a declared scope that reaches the target model" do
    before do
      ScopeOwner.has_many :merged_children, -> { merge(ScopeChild.where.not(body: "zzz")) },
                          class_name: "ScopeChild"
    end

    it "ignores a default-scoped memo left by an earlier normal read" do
      child(scope_owner_id: owner.id, body: "hidden", visible: false)
      owner.merged_children.to_a

      expect(bodies(:merged_children)).to eq(%w[hidden])
    end

    it "leaves no unscoped memo behind for a later normal read" do
      child(scope_owner_id: owner.id, body: "hidden", visible: false)

      expect(bodies(:merged_children)).to eq(%w[hidden])
      expect(owner.merged_children.reload.map(&:body)).to eq([])
    end
  end

  it "drops only the TARGET's default scopes on a :through association" do
    ActiveRecord::Schema.define do
      create_table :scope_links, force: true do |t|
        t.integer :scope_owner_id
        t.integer :scope_child_id
        t.boolean :active, default: true
      end
    end
    stub_const("ScopeLink", Class.new(TestModel) do
      self.table_name = "scope_links"
      default_scope { where(active: true) }
      belongs_to :scope_child
    end)
    ScopeOwner.has_many :scope_links
    ScopeOwner.has_many :linked_children, through: :scope_links, source: :scope_child
    kept = child(body: "kept")
    unlinked = child(body: "unlinked")
    ScopeLink.create!(scope_owner_id: owner.id, scope_child_id: kept.id, active: true)
    ScopeLink.create!(scope_owner_id: owner.id, scope_child_id: unlinked.id, active: false)

    expect(bodies(:linked_children)).to eq(%w[kept])
  end

  it "keeps has_one's single row" do
    child(scope_owner_id: owner.id, body: "a", position: 1)
    child(scope_owner_id: owner.id, body: "b", position: 2)

    expect(bodies(:scope_child)).to eq(%w[b])
  end
end
