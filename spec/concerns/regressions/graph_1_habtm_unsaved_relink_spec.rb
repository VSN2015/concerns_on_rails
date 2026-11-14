require "spec_helper"

# GRAPH-1 follow-up: a HABTM copy re-links only persisted records. An unsaved tag built on the
# original was handed to the copy too, which inserted it and stole it from the original.
RSpec.describe "Duplicable HABTM with an unsaved built record" do
  before do
    ActiveRecord::Schema.define do
      create_table :g1h_posts, force: true do |t|
        t.string :name
      end
      create_table :g1h_tags, force: true do |t|
        t.string :name
      end
      create_table :g1h_posts_tags, id: false, force: true do |t|
        t.integer :g1h_post_id
        t.integer :g1h_tag_id
      end
    end
    stub_const("G1hTag", Class.new(TestModel) { self.table_name = "g1h_tags" })
    stub_const("G1hPost", Class.new(TestModel) { self.table_name = "g1h_posts" })
    # HABTM derives its join model from the class name, so declare it once the constant is set.
    G1hPost.class_eval do
      include ConcernsOnRails::Models::Duplicable

      has_and_belongs_to_many :g1h_tags, class_name: "G1hTag", join_table: "g1h_posts_tags",
                                         foreign_key: :g1h_post_id, association_foreign_key: :g1h_tag_id
      duplicable_by associations: %i[g1h_tags]
    end
  end

  after { %w[g1h_posts g1h_tags g1h_posts_tags].each { |t| ActiveRecord::Base.connection.drop_table(t, if_exists: true) } }

  [true, false].each do |loaded|
    it "keeps the original's new tag after save! (association #{loaded ? 'loaded' : 'unloaded'})" do
      post = G1hPost.create!(name: "p")
      post.g1h_tags << G1hTag.create!(name: "old")
      post = G1hPost.find(post.id)
      post.g1h_tags.load if loaded
      post.g1h_tags.build(name: "new")

      copy = post.duplicate!
      post.save!

      expect(G1hPost.find(copy.id).g1h_tags.map(&:name)).to eq(["old"])
      expect(G1hPost.find(post.id).g1h_tags.map(&:name)).to match_array(%w[old new])
    end
  end
end
