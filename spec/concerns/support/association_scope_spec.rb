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
        t.string :tenant, default: "t1"
        t.datetime :published_at
        t.datetime :deleted_at
        t.integer :position
      end
    end

    # The gem's own hiding default scopes (Publishable's `default_scope:
    # true`, SoftDeletable's) next to an application one (a tenant) and a
    # default ORDER.
    stub_const("ScopeChild", Class.new(TestModel) do
      self.table_name = "scope_children"
      include ConcernsOnRails::Models::Publishable
      include ConcernsOnRails::Models::SoftDeletable

      publishable_by :published_at, default_scope: true
      soft_deletable_by :deleted_at
      default_scope { where(tenant: "t1").order(position: :desc) }
    end)
    stub_const("ScopeSpecialChild", Class.new(ScopeChild))
    stub_const("ScopeOwner", Class.new(TestModel) do
      self.table_name = "scope_owners"
      has_many :scope_children
      has_many :loud_children, -> { where(body: "loud") }, class_name: "ScopeChild"
      has_many :live_children, -> { where(deleted_at: nil) }, class_name: "ScopeChild"
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
    ScopeChild.unscoped.create!(published_at: 1.day.ago, **attributes)
  end

  def bodies(name)
    described_class.unfiltered(owner, name).map(&:body)
  end

  it "returns the children the gem's own default scopes hide, in the default scope's order" do
    child(scope_owner_id: owner.id, body: "shown", position: 1)
    child(scope_owner_id: owner.id, body: "draft", published_at: nil, position: 2)
    child(scope_owner_id: owner.id, body: "trashed", deleted_at: 1.hour.ago, position: 3)
    child(scope_owner_id: other.id, body: "other", position: 4)

    expect(owner.scope_children.map(&:body)).to eq(%w[shown])
    expect(bodies(:scope_children)).to eq(%w[trashed draft shown])
  end

  # Dropping EVERY default scope (the original unscoped build) let a cascade
  # or deep copy reach another tenant's rows through a shared parent, and
  # read a discriminator-scoped sibling association's rows as its own.
  it "keeps the application's own default scopes" do
    child(scope_owner_id: owner.id, body: "mine")
    child(scope_owner_id: owner.id, body: "theirs", tenant: "t2")

    expect(bodies(:scope_children)).to eq(%w[mine])
  end

  it "keeps the association's own scope" do
    child(scope_owner_id: owner.id, body: "loud")
    child(scope_owner_id: owner.id, body: "quiet")

    expect(bodies(:loud_children)).to eq(%w[loud])
  end

  # unscope(where: :deleted_at) strips the association's own predicate on
  # the column along with the default scope's; it is put back.
  it "keeps the association's own condition on a peeled column" do
    child(scope_owner_id: owner.id, body: "draft", published_at: nil)
    child(scope_owner_id: owner.id, body: "trashed", deleted_at: 1.hour.ago)

    expect(bodies(:live_children)).to eq(%w[draft])
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
  # first built, so a normal read beforehand leaked the default scope into
  # the association's "own" conditions (and so back onto the peeled column).
  describe "a declared scope that reaches the target model" do
    before do
      ScopeOwner.has_many :merged_children, -> { merge(ScopeChild.where.not(body: "zzz")) },
                          class_name: "ScopeChild"
    end

    it "ignores a default-scoped memo left by an earlier normal read" do
      child(scope_owner_id: owner.id, body: "draft", published_at: nil)
      owner.merged_children.to_a

      expect(bodies(:merged_children)).to eq(%w[draft])
    end

    it "leaves no unscoped memo behind for a later normal read" do
      child(scope_owner_id: owner.id, body: "draft", published_at: nil)

      expect(bodies(:merged_children)).to eq(%w[draft])
      expect(owner.merged_children.reload.map(&:body)).to eq([])
    end
  end

  it "keeps the through model's default scopes on a :through association" do
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
    kept = child(body: "kept", published_at: nil)
    unlinked = child(body: "unlinked")
    ScopeLink.create!(scope_owner_id: owner.id, scope_child_id: kept.id, active: true)
    ScopeLink.create!(scope_owner_id: owner.id, scope_child_id: unlinked.id, active: false)

    expect(bodies(:linked_children)).to eq(%w[kept])
  end

  describe "has_one" do
    it "keeps the single row" do
      child(scope_owner_id: owner.id, body: "a", position: 1)
      child(scope_owner_id: owner.id, body: "b", position: 2)

      expect(bodies(:scope_child)).to eq(%w[b])
    end

    # Peeling the hiding predicates let LIMIT 1 pick the hidden draft that
    # sorts first — not the child `owner.scope_child` returns.
    it "picks the row the reader returns over a hidden one sorting first" do
      child(scope_owner_id: owner.id, body: "shown", position: 1)
      child(scope_owner_id: owner.id, body: "draft", published_at: nil, position: 2)

      expect(owner.scope_child.body).to eq("shown")
      expect(bodies(:scope_child)).to eq(%w[shown])
    end

    it "falls back to a hidden row when the reader returns none" do
      child(scope_owner_id: owner.id, body: "draft", published_at: nil)

      expect(owner.scope_child).to be_nil
      expect(bodies(:scope_child)).to eq(%w[draft])
    end
  end

  it "returns the association scope unchanged when the child declares no gem default scope" do
    plain = Class.new(TestModel) do
      self.table_name = "scope_children"
      default_scope { where(tenant: "t1") }
    end
    stub_const("ScopePlainChild", plain)
    ScopeOwner.has_many :plain_children, class_name: "ScopePlainChild"
    child(scope_owner_id: owner.id, body: "draft", published_at: nil)

    expect(described_class.unfiltered(owner, :plain_children).to_sql).to eq(owner.plain_children.scope.to_sql)
  end

  # Publishable's boolean `.published` predicate is an Arel Grouping on
  # Rails 6.1+ and `<> FALSE` on 6.0 — both must be peelable by
  # unscope(where:), or its hidden rows stay out.
  it "peels Publishable's boolean predicate" do
    ActiveRecord::Schema.define do
      create_table :scope_flags, force: true do |t|
        t.integer :scope_owner_id
        t.string :body
        t.boolean :live
      end
    end
    stub_const("ScopeFlag", Class.new(TestModel) do
      self.table_name = "scope_flags"
      include ConcernsOnRails::Models::Publishable

      publishable_by :live, default_scope: true
    end)
    ScopeOwner.has_many :scope_flags
    ScopeFlag.unscoped.create!(scope_owner_id: owner.id, body: "on", live: true)
    ScopeFlag.unscoped.create!(scope_owner_id: owner.id, body: "off", live: false)
    ScopeFlag.unscoped.create!(scope_owner_id: owner.id, body: "unset", live: nil)

    relation = described_class.unfiltered(owner, :scope_flags)

    expect(owner.scope_flags.map(&:body)).to eq(%w[on])
    expect(relation.order(:id).map(&:body)).to eq(%w[on off unset])
    expect(relation.to_sql).not_to include(TestDatabase.quoted_column("live"))
  end
end
