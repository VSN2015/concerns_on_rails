describe ConcernsOnRails::Sortable do
  before(:each) do
    ActiveRecord::Schema.define do
      create_table :tasks, force: true do |t|
        t.string  :name
        t.integer :position
        t.integer :priority
      end
    end

    class Task < TestModel
      include ConcernsOnRails::Sortable
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  context "with default configuration" do
    it "sorts records by position ascending" do
      Task.create!(name: "Task B", position: 2)
      Task.create!(name: "Task A", position: 1)
      Task.create!(name: "Task C", position: 3)

      names = Task.pluck(:name)
      expect(names).to eq(["Task A", "Task B", "Task C"])
    end
  end

  context "with custom field and direction" do
    before do
      ActiveRecord::Schema.define do
        create_table :priority_tasks, force: true do |t|
          t.string  :name
          t.integer :priority
        end
      end

      class PriorityTask < TestModel
        include ConcernsOnRails::Sortable

        sortable_by priority: :desc
      end
    end

    it "sorts by priority descending" do
      PriorityTask.create!(name: "Low", priority: 1)
      PriorityTask.create!(name: "High", priority: 3)
      PriorityTask.create!(name: "Medium", priority: 2)

      expect(PriorityTask.all.pluck(:name)).to eq(%w[High Medium Low])
    end
  end

  context "when given invalid field" do
    it "raises error when sortable field is missing from DB" do
      ActiveRecord::Schema.define do
        create_table :invalid_tasks, force: true do |t|
          t.string :name
        end
      end

      expect do
        class InvalidTask < TestModel
          include ConcernsOnRails::Sortable

          sortable_by :nonexistent_column
        end
      end.to raise_error(ArgumentError, /'nonexistent_column' does not exist/)
    end
  end

  context "when given invalid or unknown configuration" do
    before do
      ActiveRecord::Schema.define do
        create_table :fallback_direction_tasks, force: true do |t|
          t.string  :name
          t.integer :priority
        end
      end
    end

    def strict_task_class(&macro_call)
      Class.new(TestModel) do
        self.table_name = "fallback_direction_tasks"
        include ConcernsOnRails::Sortable

        class_eval(&macro_call)
      end
    end

    it "raises on an invalid direction (pre-1.26 silently fell back to :asc)" do
      expect { strict_task_class { sortable_by priority: :invalid_direction } }
        .to raise_error(ArgumentError, /direction must be :asc or :desc/)
    end

    it "raises on unknown trailing options (pre-1.26 a typo vanished silently)" do
      expect { strict_task_class { sortable_by :priority, ad_new_at: :top } }
        .to raise_error(ArgumentError, /unknown option\(s\): ad_new_at/)
    end

    it "raises when more than one field => direction pair is passed" do
      expect { strict_task_class { sortable_by priority: :asc, name: :desc } }
        .to raise_error(ArgumentError, /exactly one field => direction pair/)
    end
  end

  context "when sortable_by is called multiple times" do
    before do
      ActiveRecord::Schema.define do
        create_table :multi_sortable_tasks, force: true do |t|
          t.string  :name
          t.integer :position
          t.integer :priority
        end
      end

      class MultiSortableTask < TestModel
        include ConcernsOnRails::Sortable

        sortable_by :position
      end
    end

    it "respects the latest sortable_by config" do
      MultiSortableTask.sortable_by(priority: :desc)

      MultiSortableTask.create!(name: "Low",    priority: 1, position: 1)
      MultiSortableTask.create!(name: "Medium", priority: 2, position: 3)
      MultiSortableTask.create!(name: "High",   priority: 3, position: 2)

      expect(MultiSortableTask.all.pluck(:name)).to eq(%w[High Medium Low])
    end
  end

  context "with sorting but without acts_as_list" do
    before do
      ActiveRecord::Schema.define do
        create_table :simple_tasks, force: true do |t|
          t.string  :name
          t.integer :priority
        end
      end

      class SimpleTask < TestModel
        include ConcernsOnRails::Sortable

        sortable_by :priority, use_acts_as_list: false
      end
    end

    it "sorts correctly without using acts_as_list" do
      SimpleTask.create!(name: "Low", priority: 1)
      SimpleTask.create!(name: "High", priority: 3)
      SimpleTask.create!(name: "Medium", priority: 2)

      names = SimpleTask.all.pluck(:name)
      expect(names).to eq(%w[Low Medium High])
    end
  end

  context "acts_as_list functionality" do
    before do
      ActiveRecord::Schema.define do
        create_table :tasks, force: true do |t|
          t.string  :name
          t.integer :position
        end
      end

      class Task < TestModel
        include ConcernsOnRails::Sortable

        sortable_by :position
      end
    end

    after do
      begin
        ActiveRecord::Base.connection.drop_table(:tasks)
      rescue StandardError
        nil
      end
      Object.send(:remove_const, :Task) if defined?(Task)
    end

    it "automatically assigns position on creation" do
      task1 = Task.create!(name: "Task 1")
      task2 = Task.create!(name: "Task 2")
      task3 = Task.create!(name: "Task 3")

      expect([task1.position, task2.position, task3.position]).to eq([1, 2, 3])
    end

    it "allows moving higher in the list" do
      Task.create!(name: "Task 1")
      task2 = Task.create!(name: "Task 2")

      task2.move_higher

      expect(Task.order(:position).pluck(:name)).to eq(["Task 2", "Task 1"])
    end

    it "allows moving lower in the list" do
      task1 = Task.create!(name: "Task 1")
      Task.create!(name: "Task 2")

      task1.move_lower

      expect(Task.order(:position).pluck(:name)).to eq(["Task 2", "Task 1"])
    end

    it "can move to top" do
      Task.create!(name: "Task 1")
      Task.create!(name: "Task 2")
      task3 = Task.create!(name: "Task 3")

      task3.move_to_top

      expect(Task.order(:position).pluck(:name)).to eq(["Task 3", "Task 1", "Task 2"])
    end

    it "can move to bottom" do
      task1 = Task.create!(name: "Task 1")
      Task.create!(name: "Task 2")
      Task.create!(name: "Task 3")

      task1.move_to_bottom

      expect(Task.order(:position).pluck(:name)).to eq(["Task 2", "Task 3", "Task 1"])
    end

    it "reorders remaining items correctly when one is removed" do
      Task.create!(name: "Task 1")
      task2 = Task.create!(name: "Task 2")
      Task.create!(name: "Task 3")

      task2.destroy

      expect(Task.order(:position).pluck(:name)).to eq(["Task 1", "Task 3"])
      expect(Task.pluck(:position)).to eq([1, 2])
    end
  end

  context "acts_as_list scope: option (1.12)" do
    before do
      ActiveRecord::Schema.define do
        create_table :list_items, force: true do |t|
          t.string  :name
          t.integer :position
          t.integer :list_id
        end
      end

      class ListItem < TestModel
        include ConcernsOnRails::Sortable

        sortable_by :position, scope: :list_id
      end
    end

    after do
      Object.send(:remove_const, :ListItem) if defined?(ListItem)
    end

    it "numbers position independently per scope" do
      a = ListItem.create!(name: "a", list_id: 1)
      b = ListItem.create!(name: "b", list_id: 1)
      c = ListItem.create!(name: "c", list_id: 2)

      expect([a.position, b.position]).to eq([1, 2])
      expect(c.position).to eq(1)
    end
  end

  context "acts_as_list add_new_at: option (1.12)" do
    before do
      ActiveRecord::Schema.define do
        create_table :stack_items, force: true do |t|
          t.string  :name
          t.integer :position
        end
      end

      class StackItem < TestModel
        include ConcernsOnRails::Sortable

        sortable_by :position, add_new_at: :top
      end
    end

    after do
      Object.send(:remove_const, :StackItem) if defined?(StackItem)
    end

    it "inserts new records at the top of the list" do
      first  = StackItem.create!(name: "first")
      second = StackItem.create!(name: "second")

      expect(second.position).to eq(1)
      expect(first.reload.position).to eq(2)
    end
  end

  describe ".reposition! (bulk reorder from an id list)" do
    let!(:a) { Task.create!(name: "A") }
    let!(:b) { Task.create!(name: "B") }
    let!(:c) { Task.create!(name: "C") }

    it "sets positions to match the id order in one UPDATE and returns the count" do
      queries = []
      callback = ->(*, payload) { queries << payload[:sql] if payload[:sql] =~ /\AUPDATE/i }
      count = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { Task.reposition!([c.id, a.id, b.id]) }

      expect(count).to eq(3)
      expect(queries.size).to eq(1)
      expect(queries.first).to match(/CASE .*"tasks"\."id" WHEN/i)
      expect(Task.pluck(:name)).to eq(%w[C A B])
      expect(Task.pluck(:position)).to eq([1, 2, 3])
      expect(Task.reposition!(%w[1 2 3].map { |i| Task.find_by!(position: i).id.to_s })).to eq(3) # String ids from params
    end

    it "pushes rows missing from the list after it (in their current order) — or raises with missing: :raise" do
      expect(Task.reposition!([c.id])).to eq(3)
      expect(Task.pluck(:name)).to eq(%w[C A B])

      expect { Task.reposition!([b.id], missing: :raise) }
        .to raise_error(ArgumentError, /2 record\(s\) in this relation are missing from ids \(pass missing: :append/)
      expect(Task.pluck(:name)).to eq(%w[C A B]) # nothing written
      expect { Task.reposition!([b.id], missing: :nope) }.to raise_error(ArgumentError, /missing: must be :append or :raise/)
    end

    it "rejects ids outside the relation and duplicates, and stays inside a scoped relation" do
      ActiveRecord::Schema.define do
        create_table :scoped_tasks, force: true do |t|
          t.string :name
          t.integer :list_id
          t.integer :position
        end
      end
      klass = Class.new(TestModel) do
        self.table_name = "scoped_tasks"
        include ConcernsOnRails::Sortable

        sortable_by :position, scope: :list_id
      end
      l1 = %w[x y z].map { |n| klass.create!(name: n, list_id: 1) }
      l2 = klass.create!(name: "other", list_id: 2)

      expect(klass.where(list_id: 1).reposition!([l1[2].id, l1[0].id, l1[1].id])).to eq(3)
      expect(klass.where(list_id: 1).pluck(:name)).to eq(%w[z x y])
      expect(l2.reload.position).to eq(1)

      expect { klass.where(list_id: 1).reposition!([l2.id, l1[0].id]) }
        .to raise_error(ArgumentError, /id\(s\) #{l2.id} are not in this relation/)
      expect { klass.where(list_id: 1).reposition!([l1[0].id, l1[0].id]) }.to raise_error(ArgumentError, /duplicate id\(s\)/)
      expect(klass.where(list_id: 3).reposition!([])).to eq(0)
    end

    it "gives the first id the highest position on a descending list" do
      ActiveRecord::Schema.define do
        create_table :ranked_tasks, force: true do |t|
          t.string :name
          t.integer :priority
        end
      end
      klass = Class.new(TestModel) do
        self.table_name = "ranked_tasks"
        include ConcernsOnRails::Sortable

        sortable_by priority: :desc, use_acts_as_list: false
      end
      x, y, z = %w[x y z].map { |n| klass.create!(name: n) }

      expect(klass.reposition!([y.id, z.id, x.id])).to eq(3)
      expect(klass.pluck(:name)).to eq(%w[y z x])
      expect(klass.pluck(:priority)).to eq([3, 2, 1])
    end
  end
end
