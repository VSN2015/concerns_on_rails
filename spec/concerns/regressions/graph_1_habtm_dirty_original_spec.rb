require "spec_helper"

# GRAPH-1 (audit v1.36.1): a HABTM copy was linked to the ORIGINAL's in-memory tag objects, so
# saving the copy autosaved the original's unsaved nested edit into the shared row.
RSpec.describe "Duplicable HABTM with an unsaved nested edit on the original" do
  before do
    ActiveRecord::Schema.define do
      create_table :g1d_posts, force: true do |t|
        t.string :name
      end
      create_table :g1d_tags, force: true do |t|
        t.string :name
      end
      create_table :g1d_posts_tags, id: false, force: true do |t|
        t.integer :g1d_post_id
        t.integer :g1d_tag_id
      end
    end
    stub_const("G1dTag", Class.new(TestModel) do
      self.table_name = "g1d_tags"
      before_validation { self.name = name.downcase if name }
    end)
    stub_const("G1dPost", Class.new(TestModel) { self.table_name = "g1d_posts" })
    G1dPost.class_eval do
      include ConcernsOnRails::Models::Duplicable

      has_and_belongs_to_many :g1d_tags, class_name: "G1dTag", join_table: "g1d_posts_tags",
                                         foreign_key: :g1d_post_id, association_foreign_key: :g1d_tag_id
      accepts_nested_attributes_for :g1d_tags, allow_destroy: true
      duplicable_by associations: %i[g1d_tags]
    end
  end

  after { %w[g1d_posts g1d_tags g1d_posts_tags].each { |t| ActiveRecord::Base.connection.drop_table(t, if_exists: true) } }

  [false, true].each do |loaded|
    context "association #{loaded ? 'loaded' : 'unloaded'}" do
      let!(:tag) { G1dTag.create!(name: "old") }
      let(:post) do
        original = G1dPost.create!(name: "p")
        original.g1d_tags << tag
        original = G1dPost.find(original.id)
        original.g1d_tags.load if loaded
        original.assign_attributes(g1d_tags_attributes: [{ id: tag.id, name: "edited" }])
        original
      end

      it "leaves the shared row, and the original's pending edit, untouched" do
        pending_tag = post.g1d_tags.target.find { |t| t.id == tag.id }
        expect(pending_tag.name).to eq("edited")

        copy = post.duplicate!

        expect(G1dTag.find(tag.id).name).to eq("old")
        expect(pending_tag.name).to eq("edited")
        expect(pending_tag).to be_changed
        expect(post.g1d_tags.target).to include(pending_tag)
        expect(G1dPost.find(copy.id).g1d_tags.map(&:id)).to eq([tag.id])
      end

      it "still saves the original's edit when the original is saved" do
        post.duplicate!
        post.save!
        expect(G1dTag.find(tag.id).name).to eq("edited")
      end

      it "keeps a tag marked for destruction out of the copy and leaves the original's mark" do
        post.assign_attributes(g1d_tags_attributes: [{ id: tag.id, _destroy: "1" }])
        copy = post.duplicate!
        expect(G1dPost.find(copy.id).g1d_tags).to be_empty
        expect(post.g1d_tags.target.first).to be_marked_for_destruction
        expect(G1dPost.find(post.id).g1d_tags.map(&:id)).to eq([tag.id])
      end
    end
  end

  context "re-linking never shares the original's objects" do
    let(:post) do
      original = G1dPost.create!(name: "p")
      tags.each { |t| original.g1d_tags << t }
      G1dPost.find(original.id)
    end
    let(:tags) { [G1dTag.create!(name: "a"), G1dTag.create!(name: "b"), G1dTag.create!(name: "c")] }

    # The copy's own save still validates (and so normalizes) the tag it now owns, as Rails does for any
    # linked record; what must hold is that the ORIGINAL's object is never the one that is rewritten.
    it "does not let a before_validation rewrite of a clean-looking tag reach the original's object" do
      tags.first.update_column(:name, "UPPER")
      post.g1d_tags.load
      shared = post.g1d_tags.target.find { |t| t.id == tags.first.id }

      post.duplicate!

      expect(shared.name).to eq("UPPER")
      expect(shared).not_to be_changed
    end

    it "leaves a tag whose row was deleted meanwhile out of the copy instead of raising" do
      post.g1d_tags.load
      post.assign_attributes(g1d_tags_attributes: [{ id: tags[0].id, name: "x" }, { id: tags[1].id, name: "y" }])
      G1dTag.where(id: tags[0].id).delete_all

      copy = nil
      expect { copy = post.duplicate! }.not_to raise_error
      expect(G1dPost.find(copy.id).g1d_tags.map(&:id)).to match_array([tags[1].id, tags[2].id])
    end

    it "reads the edited tags back in one SELECT" do
      post.assign_attributes(g1d_tags_attributes: tags.map { |t| { id: t.id, name: "n#{t.id}" } })
      selects = []
      counter = lambda do |*, payload|
        sql = payload[:sql]
        selects << sql if sql.match?(/\ASELECT/) && sql.match?(/FROM\s+\W?g1d_tags\W?\s+WHERE/) && sql !~ /JOIN/
      end
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { post.duplicate! }
      expect(selects.size).to eq(1)
    end

    it "looks a row up by its stored key, not an unsaved key edit" do
      post.g1d_tags.load
      edited = post.g1d_tags.target.find { |t| t.id == tags[0].id }
      edited.id = tags[1].id
      edited.name = "moved"

      copy = post.duplicate!

      expect(G1dPost.find(copy.id).g1d_tags.map(&:name)).to match_array(%w[a b c])
      expect(G1dTag.pluck(:name)).to match_array(%w[a b c])
    end
  end
end
