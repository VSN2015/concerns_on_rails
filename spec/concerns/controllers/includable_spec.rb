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

  describe "nested includes, default: and strategy:" do
    let(:klass) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Includable

        includable writer: :stories, remarks: :story, default: :writer, strategy: :preload
      end
    end

    it "accepts dotted paths that follow the allow-list tree and drops the rest" do
      c = klass.new(params: { include: "remarks.story, writer.stories,writer.secret,remarks.story.writer,remarks,,bogus" })
      expect(c.requested_includes(as: :paths)).to eq(%w[remarks.story writer.stories remarks])
      expect(c.requested_includes).to eq([{ remarks: :story }, { writer: :stories }])
      expect(klass.includable_associations).to eq(%i[writer remarks])
    end

    it "mixes flat and nested entries in the query shape and nests the as_json shape" do
      c = klass.new(params: { include: "writer,remarks.story" })
      expect(c.requested_includes).to eq([:writer, { remarks: :story }])
      expect(c.requested_includes(as: :json)).to eq([:writer, { remarks: { include: :story } }])

      writer = Writer.create!(name: "Ann")
      story = Story.create!(title: "T", writer: writer)
      Remark.create!(content: "nice", story: story)
      json = story.as_json(include: c.requested_includes(as: :json))
      expect(json["writer"]["name"]).to eq("Ann")
      expect(json["remarks"].first["story"]["title"]).to eq("T")
    end

    it "with_includes applies the configured strategy and really loads the nested graph" do
      writer = Writer.create!(name: "Ann")
      story = Story.create!(title: "T", writer: writer)
      Remark.create!(content: "nice", story: story)

      relation = klass.new(params: { include: "remarks.story" }).with_includes(Story.all)
      expect(relation.preload_values).to eq([{ remarks: :story }])
      expect(relation.includes_values).to eq([])
      loaded = relation.to_a.first
      expect(loaded.association(:remarks)).to be_loaded
      expect(loaded.remarks.first.association(:story)).to be_loaded
    end

    it "uses default: when ?include is absent, and nothing when the client sends a blank include" do
      expect(klass.new.requested_includes(as: :paths)).to eq(["writer"])
      expect(klass.new.with_includes(Story.all).preload_values).to eq([:writer])
      expect(klass.new(params: { include: "" }).requested_includes).to eq([])
      expect(klass.new(params: { include: "remarks" }).requested_includes).to eq([:remarks])
    end

    it "accepts Array params, ignores hash-shaped garbage and rejects an unknown as:" do
      c = klass.new(params: { include: ["writer", "remarks,secret"] })
      expect(c.requested_includes).to eq(%i[writer remarks])
      expect(klass.new(params: { include: { "x" => "y" } }).requested_includes).to eq([])
      expect { c.requested_includes(as: :xml) }.to raise_error(ArgumentError, /as: must be :query, :paths or :json/)
    end

    it "validates default: against the allow-list, strategy:, and the declaration shape at class load" do
      build = lambda do |**opts|
        Class.new(FakeController) do
          include ConcernsOnRails::Controllers::Includable

          includable(*opts.delete(:assoc), **opts)
        end
      end
      expect { build.call(assoc: [:writer], default: :remarks) }
        .to raise_error(ArgumentError, /default: remarks is not an includable path/)
      expect { build.call(assoc: [{ remarks: :story }], default: "remarks.story") }.not_to raise_error
      expect { build.call(assoc: [:writer], strategy: :join) }
        .to raise_error(ArgumentError, /strategy: must be one of includes, preload, eager_load/)
      expect { build.call(assoc: [42]) }.to raise_error(ArgumentError, /associations must be Symbols, Strings, Arrays or Hashes/)
    end
  end
end
