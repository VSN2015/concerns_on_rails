# Regression (audit 2026-10-10, SCOPE-9): Duplicable copied acts_as_list's
# generated position, so the copy was INSERTed at the original's slot and
# acts_as_list shifted the list: copy = 1, original = 2, b = 3. Since 1.32.1
# the position is a reported create-time generated value, like a slug or a
# token, so the top-level copy now gets a fresh one. Deep-copied children keep
# theirs, so a copied list keeps its order.
RSpec.describe "Duplicable with a Sortable (acts_as_list) position" do
  before do
    ActiveRecord::Schema.define do
      create_table :dup_lists, force: true do |t|
        t.string :name
        t.integer :position
      end
      create_table :dup_items, force: true do |t|
        t.integer :dup_list_id
        t.integer :account_id
        t.string :name
        t.integer :position
      end
    end
  end

  after do
    %i[dup_items dup_lists].each { |table| ActiveRecord::Base.connection.drop_table(table, if_exists: true) }
  end

  # Named BEFORE the body runs: acts_as_list (1.1 on the Rails 6.0 line)
  # builds `delegate ..., to: self` from the class name, which an anonymous
  # Class.new body does not have yet.
  def named_model(name, &body)
    stub_const(name, Class.new(TestModel)).tap { |klass| klass.class_eval(&body) }
  end

  context "a top-level copy" do
    before do
      named_model("DupList") do
        self.table_name = "dup_lists"
        include ConcernsOnRails::Models::Sortable
        include ConcernsOnRails::Models::Duplicable

        sortable_by :position
      end
    end

    it "takes a fresh position at the bottom; the original keeps its place" do
      a = DupList.create!(name: "a")
      b = DupList.create!(name: "b")
      copy = a.duplicate!

      expect(a.reload.position).to eq(1)
      expect(b.reload.position).to eq(2)
      expect(copy.reload.position).to eq(3)
    end

    it "honours add_new_at: :top" do
      named_model("DupList") do
        self.table_name = "dup_lists"
        include ConcernsOnRails::Models::Sortable
        include ConcernsOnRails::Models::Duplicable

        sortable_by :position, add_new_at: :top
      end
      a = DupList.create!(name: "a")
      b = DupList.create!(name: "b")
      c = DupList.create!(name: "c")
      expect([a, b, c].map { |row| row.reload.position }).to eq([3, 2, 1])

      copy = a.duplicate!

      expect([copy, c, b, a].map { |row| row.reload.position }).to eq([1, 2, 3, 4])
    end

    it "leaves the position blank on the unsaved copy and keeps an explicit override" do
      a = DupList.create!(name: "a")
      DupList.create!(name: "b")

      expect(a.duplicate.position).to be_nil
      copy = a.duplicate!(position: 2)
      expect(copy.reload.position).to eq(2)
    end
  end

  it "keeps the position of a Sortable model without acts_as_list (nothing would regenerate it)" do
    named_model("DupList") do
      self.table_name = "dup_lists"
      include ConcernsOnRails::Models::Sortable
      include ConcernsOnRails::Models::Duplicable

      sortable_by :position, use_acts_as_list: false
    end
    a = DupList.create!(name: "a", position: 7)

    expect(a.duplicate!.reload.position).to eq(7)
  end

  context "deep-copied children" do
    def define_models(child_duplicable:, child_reset: nil, scope: :dup_list, **sortable_options)
      named_model("DupItem") do
        self.table_name = "dup_items"
        include ConcernsOnRails::Models::Sortable
        include ConcernsOnRails::Models::Duplicable if child_duplicable

        belongs_to :dup_list, optional: true
        sortable_by :position, scope: scope, **sortable_options
        duplicable_by reset: child_reset if child_reset
      end
      named_model("DupList") do
        self.table_name = "dup_lists"
        include ConcernsOnRails::Models::Sortable
        include ConcernsOnRails::Models::Duplicable

        has_many :dup_items, class_name: "DupItem", foreign_key: :dup_list_id
        sortable_by :position
        duplicable_by associations: %i[dup_items]
      end
    end

    [true, false].each do |child_duplicable|
      it "keep their positions (child #{child_duplicable ? 'is' : 'is not'} Duplicable)" do
        define_models(child_duplicable: child_duplicable)
        list = DupList.create!(name: "list")
        first = list.dup_items.create!(name: "first")
        second = list.dup_items.create!(name: "second")
        third = list.dup_items.create!(name: "third")
        # Sparse positions (a list after deletions, or numbered by hand), out
        # of id order, so a regenerated 1-2-3 would show.
        first.update_columns(position: 20)
        second.update_columns(position: 10)
        third.update_columns(position: 30)

        copy = list.duplicate!

        expect(copy.reload.position).to eq(2)
        expect(copy.dup_items.order(:position).map { |item| [item.name, item.position] })
          .to eq([["second", 10], ["first", 20], ["third", 30]])
        expect(list.dup_items.order(:position).map { |item| [item.name, item.position] })
          .to eq([["second", 10], ["first", 20], ["third", 30]])
      end
    end

    it "take a fresh position when the child's own reset: lists the column" do
      define_models(child_duplicable: true, child_reset: %i[position])
      list = DupList.create!(name: "list")
      first = list.dup_items.create!(name: "first")
      first.update_columns(position: 20)

      copy = list.duplicate!

      expect(copy.dup_items.map { |item| item.reload.position }).to eq([1])
    end

    # Review follow-up: a list NOT scoped by the parent's foreign key is shared
    # with the original children, so a copy keeping the position would land in
    # the original's list and push the originals down — the same bug one level
    # deeper.
    # label => [scope, positions the copies take]. The copies are appended to
    # the list they land in: the originals' shared list (3, 4) or, for the
    # opaque String scope that happens to include the new parent's id, a fresh
    # one (1, 2).
    {
      "another column (scope: :account_id)" => [:account_id, [3, 4]],
      "an array scope (scope: %i[account_id])" => [%i[account_id], [3, 4]],
      "no scope at all" => [nil, [3, 4]],
      "an opaque SQL scope" => ["dup_list_id = \#{dup_list_id}", [1, 2]]
    }.each do |label, (scope, copied_positions)|
      [true, false].each do |child_duplicable|
        it "blanks the position of a child whose list is scoped by #{label} (child #{child_duplicable ? 'is' : 'is not'} Duplicable)" do
          define_models(child_duplicable: child_duplicable, scope: scope)
          list = DupList.create!(name: "list")
          originals = %w[first second].map { |name| list.dup_items.create!(name: name, account_id: 1) }

          copy = list.duplicate!

          expect(originals.map { |item| item.reload.position }).to eq([1, 2])
          copied = copy.dup_items.order(:id).to_a
          expect(copied.map(&:name)).to eq(%w[first second])
          expect(copied.map(&:position)).to eq(copied_positions)
        end
      end
    end

    it "keeps a composite scope's positions when the array names the foreign key" do
      define_models(child_duplicable: true, scope: %i[dup_list_id account_id])
      list = DupList.create!(name: "list")
      list.dup_items.create!(name: "first", account_id: 1).update_columns(position: 20)

      copy = list.duplicate!

      expect(copy.dup_items.map { |item| item.reload.position }).to eq([20])
    end

    it "blanks in the original order when the children's list adds new rows at the top" do
      define_models(child_duplicable: false, scope: :account_id, add_new_at: :top, default_scope: false)
      list = DupList.create!(name: "list")
      %w[a b c].each { |name| list.dup_items.create!(name: name, account_id: 1) }
      before = DupItem.order(:position).pluck(:name)

      copy = list.duplicate!

      expect(before).to eq(%w[c b a])
      # New rows go on TOP of the shared list (pushing the originals down), in
      # the original order: c, b, a take 1, 2, 3.
      copied = DupItem.where(id: copy.dup_items.select(:id)).order(:position)
      expect(copied.map { |item| [item.name, item.position] }).to eq([["c", 1], ["b", 2], ["a", 3]])
    end

    it "keeps every position in order under default_scope: false, whatever the id order" do
      define_models(child_duplicable: false, default_scope: false)
      list = DupList.create!(name: "list")
      first = list.dup_items.create!(name: "first")
      second = list.dup_items.create!(name: "second")
      third = list.dup_items.create!(name: "third")
      first.update_columns(position: 20)
      second.update_columns(position: 10)
      third.update_columns(position: 30)

      copy = list.duplicate!

      expect(copy.dup_items.sort_by(&:position).map { |item| [item.name, item.reload.position] })
        .to eq([["second", 10], ["first", 20], ["third", 30]])
    end
  end
end
