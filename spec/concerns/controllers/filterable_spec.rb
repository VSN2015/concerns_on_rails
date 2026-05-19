require "spec_helper"

describe ConcernsOnRails::Controllers::Filterable do
  before do
    ActiveRecord::Schema.define do
      create_table :articles, force: true do |t|
        t.string :title
        t.string :status
        t.string :category
        t.datetime :published_at
      end
    end

    class Article < TestModel
      self.table_name = "articles"
      scope :published, -> { where.not(published_at: nil) }
    end

    Article.create!(title: "A", status: "draft", category: "news")
    Article.create!(title: "B", status: "published", category: "news", published_at: Time.zone.now)
    Article.create!(title: "C", status: "published", category: "blog", published_at: Time.zone.now)
    Article.create!(title: "D", status: "draft", category: "blog")
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end

    Object.send(:remove_const, :Article) if Object.const_defined?(:Article)
  end

  describe "direct where mode" do
    let(:controller_class) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable

        filter_by :status, :category
      end
    end

    it "filters by a single param" do
      controller = controller_class.new(params: { status: "published" })
      expect(controller.filtered(Article.all).pluck(:title)).to match_array(%w[B C])
    end

    it "composes multiple filters" do
      controller = controller_class.new(params: { status: "published", category: "blog" })
      expect(controller.filtered(Article.all).pluck(:title)).to eq(["C"])
    end

    it "skips blank params" do
      controller = controller_class.new(params: { status: "" })
      expect(controller.filtered(Article.all).count).to eq(4)
    end

    it "skips missing params" do
      controller = controller_class.new
      expect(controller.filtered(Article.all).count).to eq(4)
    end
  end

  describe "scope mode" do
    let(:controller_class) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable

        filter_by :published, scope: :published
      end
    end

    it "calls the named scope when param is present and truthy" do
      controller = controller_class.new(params: { published: "1" })
      expect(controller.filtered(Article.all).pluck(:title)).to match_array(%w[B C])
    end

    it "skips when param is blank" do
      controller = controller_class.new
      expect(controller.filtered(Article.all).count).to eq(4)
    end
  end

  describe "lambda mode" do
    let(:controller_class) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Filterable

        filter_by :q, with: ->(rel, v) { rel.where("title LIKE ?", "%#{v}%") }
      end
    end

    it "delegates to the lambda" do
      controller = controller_class.new(params: { q: "C" })
      expect(controller.filtered(Article.all).pluck(:title)).to eq(["C"])
    end
  end

  describe "configuration errors" do
    it "raises when no fields are given" do
      expect do
        Class.new(FakeController) do
          include ConcernsOnRails::Controllers::Filterable

          filter_by
        end
      end.to raise_error(ArgumentError, /at least one field is required/)
    end

    it "raises when both :scope and :with are passed" do
      expect do
        Class.new(FakeController) do
          include ConcernsOnRails::Controllers::Filterable

          filter_by :status, scope: :published, with: ->(rel, _v) { rel }
        end
      end.to raise_error(ArgumentError, /pass either :scope or :with, not both/)
    end
  end
end
