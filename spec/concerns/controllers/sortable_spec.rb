require "spec_helper"

describe ConcernsOnRails::Controllers::Sortable do
  before do
    ActiveRecord::Schema.define do
      create_table :articles, force: true do |t|
        t.string :title
        t.datetime :created_at
      end
    end

    class Article < TestModel
      self.table_name = "articles"
    end

    Article.create!(title: "Charlie", created_at: 3.days.ago)
    Article.create!(title: "Alice",   created_at: 1.day.ago)
    Article.create!(title: "Bob",     created_at: 2.days.ago)
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end

    Object.send(:remove_const, :Article) if Object.const_defined?(:Article)
  end

  let(:controller_class) do
    Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Sortable

      sortable_by :created_at, :title, default: :created_at, direction: :desc
    end
  end

  it "applies a whitelisted sort column from params" do
    controller = controller_class.new(params: { sort: "title", direction: "asc" })
    expect(controller.sorted(Article.all).pluck(:title)).to eq(%w[Alice Bob Charlie])
  end

  it "falls back to the default field when params[:sort] is not whitelisted" do
    controller = controller_class.new(params: { sort: "; DROP TABLE articles;--" })
    # Default field :created_at, default direction :desc — newest first
    expect(controller.sorted(Article.all).first.title).to eq("Alice")
  end

  it "falls back to the default direction when params[:direction] is invalid" do
    controller = controller_class.new(params: { sort: "title", direction: "sideways" })
    # default direction :desc
    expect(controller.sorted(Article.all).pluck(:title)).to eq(%w[Charlie Bob Alice])
  end

  it "uses defaults when no params are given" do
    controller = controller_class.new
    expect(controller.sorted(Article.all).first.title).to eq("Alice")
  end

  it "accepts direction case-insensitively" do
    controller = controller_class.new(params: { sort: "title", direction: "ASC" })
    expect(controller.sorted(Article.all).pluck(:title)).to eq(%w[Alice Bob Charlie])
  end

  it "uses the first declared field as default when :default is not specified" do
    klass = Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Sortable

      sortable_by :title, :created_at
    end
    controller = klass.new
    expect(controller.sorted(Article.all).pluck(:title)).to eq(%w[Alice Bob Charlie])
  end

  it "raises when no fields are given" do
    expect do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Sortable

        sortable_by
      end
    end.to raise_error(ArgumentError, /at least one field is required/)
  end
end
