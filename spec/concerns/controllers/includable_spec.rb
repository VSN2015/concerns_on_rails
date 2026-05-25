require "spec_helper"

describe ConcernsOnRails::Controllers::Includable do
  before do
    ActiveRecord::Schema.define do
      create_table :writers, force: true do |t|
        t.string :name
        t.string :email
      end
      create_table :stories, force: true do |t|
        t.string :title
        t.text :body
        t.integer :writer_id
      end
      create_table :remarks, force: true do |t|
        t.string :content
        t.integer :story_id
      end
    end

    class Writer < TestModel
      has_many :stories
    end

    class Story < TestModel
      belongs_to :writer
      has_many :remarks
    end

    class Remark < TestModel
      belongs_to :story
    end

    class StoriesController < FakeController
      include ConcernsOnRails::Controllers::Includable

      includable :writer, :remarks,
                 fields: { stories: %i[id title], writers: %i[id name] }
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  describe "#with_includes" do
    it "eager-loads the whitelisted associations from ?include=" do
      controller = StoriesController.new(params: { include: "writer,remarks" })
      expect(controller.with_includes(Story.all).includes_values).to match_array(%i[writer remarks])
    end

    it "drops associations that are not whitelisted" do
      controller = StoriesController.new(params: { include: "writer,secret" })
      expect(controller.with_includes(Story.all).includes_values).to eq([:writer])
    end

    it "returns the relation unchanged when nothing is requested" do
      controller = StoriesController.new
      expect(controller.with_includes(Story.all).includes_values).to eq([])
    end

    it "actually loads the association without error" do
      writer = Writer.create!(name: "Ann")
      Story.create!(title: "T", writer: writer)
      controller = StoriesController.new(params: { include: "writer" })
      stories = controller.with_includes(Story.all).to_a
      expect(stories.first.writer).to eq(writer)
    end
  end

  describe "#requested_includes" do
    it "returns the sanitized association list" do
      controller = StoriesController.new(params: { include: "writer,secret,remarks" })
      expect(controller.requested_includes).to match_array(%i[writer remarks])
    end

    it "returns an empty array when absent" do
      expect(StoriesController.new.requested_includes).to eq([])
    end
  end

  describe "#requested_fields" do
    it "intersects requested columns with the allow-list and drops unknown tables" do
      controller = StoriesController.new(
        params: { fields: { stories: "id,title,secret", unknown: "x" } }
      )
      expect(controller.requested_fields).to eq(stories: %i[id title])
    end

    it "returns an empty hash when absent" do
      expect(StoriesController.new.requested_fields).to eq({})
    end
  end
end
