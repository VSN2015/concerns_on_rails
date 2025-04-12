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

      expect(PriorityTask.all.pluck(:name)).to eq(["High", "Medium", "Low"])
    end
  end

  context "when given invalid field" do
    it "raises error when sortable field is missing from DB" do
      ActiveRecord::Schema.define do
        create_table :invalid_tasks, force: true do |t|
          t.string :name
        end
      end

      expect {
        class InvalidTask < TestModel
          include ConcernsOnRails::Sortable
          sortable_by :nonexistent_column
        end
      }.to raise_error(ArgumentError, /sortable_field 'nonexistent_column' does not exist/)
    end
  end

  context "when given invalid direction" do
    before do
      ActiveRecord::Schema.define do
        create_table :fallback_direction_tasks, force: true do |t|
          t.string  :name
          t.integer :priority
        end
      end

      class FallbackDirectionTask < TestModel
        include ConcernsOnRails::Sortable
        sortable_by priority: :invalid_direction
      end
    end

    it "defaults to ascending if direction is invalid" do
      FallbackDirectionTask.create!(name: "Low", priority: 1)
      FallbackDirectionTask.create!(name: "High", priority: 3)
      FallbackDirectionTask.create!(name: "Medium", priority: 2)

      expect(FallbackDirectionTask.all.pluck(:name)).to eq(["Low", "Medium", "High"])
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
  
      expect(MultiSortableTask.all.pluck(:name)).to eq(["High", "Medium", "Low"])
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
  
      expect(MultiSortableTask.all.pluck(:name)).to eq(["High", "Medium", "Low"])
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
      expect(names).to eq(["Low", "Medium", "High"])
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
      ActiveRecord::Base.connection.drop_table(:tasks) rescue nil
      Object.send(:remove_const, :Task) if defined?(Task)
    end
  
    it "automatically assigns position on creation" do
      task1 = Task.create!(name: "Task 1")
      task2 = Task.create!(name: "Task 2")
      task3 = Task.create!(name: "Task 3")
  
      expect([task1.position, task2.position, task3.position]).to eq([1, 2, 3])
    end
  
    it "allows moving higher in the list" do
      task1 = Task.create!(name: "Task 1")
      task2 = Task.create!(name: "Task 2")
  
      task2.move_higher
  
      expect(Task.order(:position).pluck(:name)).to eq(["Task 2", "Task 1"])
    end
  
    it "allows moving lower in the list" do
      task1 = Task.create!(name: "Task 1")
      task2 = Task.create!(name: "Task 2")
  
      task1.move_lower
  
      expect(Task.order(:position).pluck(:name)).to eq(["Task 2", "Task 1"])
    end
  
    it "can move to top" do
      task1 = Task.create!(name: "Task 1")
      task2 = Task.create!(name: "Task 2")
      task3 = Task.create!(name: "Task 3")
  
      task3.move_to_top
  
      expect(Task.order(:position).pluck(:name)).to eq(["Task 3", "Task 1", "Task 2"])
    end
  
    it "can move to bottom" do
      task1 = Task.create!(name: "Task 1")
      task2 = Task.create!(name: "Task 2")
      task3 = Task.create!(name: "Task 3")
  
      task1.move_to_bottom
  
      expect(Task.order(:position).pluck(:name)).to eq(["Task 2", "Task 3", "Task 1"])
    end
  
    it "reorders remaining items correctly when one is removed" do
      task1 = Task.create!(name: "Task 1")
      task2 = Task.create!(name: "Task 2")
      task3 = Task.create!(name: "Task 3")
  
      task2.destroy
  
      expect(Task.order(:position).pluck(:name)).to eq(["Task 1", "Task 3"])
      expect(Task.pluck(:position)).to eq([1, 2])
    end
  end
end
