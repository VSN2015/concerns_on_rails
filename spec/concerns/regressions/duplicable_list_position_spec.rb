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
    def define_models(child_duplicable:, child_reset: nil)
      named_model("DupItem") do
        self.table_name = "dup_items"
        include ConcernsOnRails::Models::Sortable
        include ConcernsOnRails::Models::Duplicable if child_duplicable

        belongs_to :dup_list, optional: true
        sortable_by :position, scope: :dup_list
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
  end
end
