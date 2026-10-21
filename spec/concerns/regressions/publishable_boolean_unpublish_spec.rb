require "spec_helper"

# Audit 2026-10-10 (STATE-1): on a boolean publish column, unpublish! and
# unpublish_all wrote NULL — a NotNullViolation on the usual
# `t.boolean :published, null: false, default: false`, and a third state on a
# nullable one. They write false there; a timestamp column still gets NULL.
describe "Publishable unpublishing a boolean column" do
  before do
    ActiveRecord::Schema.define do
      create_table :pbu_posts, force: true do |t|
        t.boolean :published, null: false, default: false
        t.timestamps
      end
      create_table :pbu_nullable_posts, force: true do |t|
        t.boolean :published
      end
      create_table :pbu_stamped_posts, force: true do |t|
        t.datetime :published_at
      end
    end
  end

  after do
    %i[pbu_posts pbu_nullable_posts pbu_stamped_posts].each do |table|
      ActiveRecord::Base.connection.drop_table(table, if_exists: true)
    end
  end

  def publishable_model(table, field)
    Class.new(TestModel) do
      self.table_name = table
      include ConcernsOnRails::Publishable

      publishable_by field
    end
  end

  let(:model) { publishable_model("pbu_posts", :published) }

  it "unpublish! writes false into a NOT NULL boolean column" do
    post = model.create!(published: true)

    expect(post.unpublish!).to be(true)
    expect(post.reload.published).to be(false)
    expect(post).not_to be_published
  end

  it "unpublish_all's single UPDATE writes false into a NOT NULL boolean column" do
    model.create!(published: true)
    model.create!(published: true)

    expect(model.unpublish_all).to eq(2)
    expect(model.pluck(:published)).to eq([false, false])
  end

  it "unpublish_all's per-record path writes false too" do
    validated = Class.new(model) { validates :published, inclusion: { in: [true, false] } }
    validated.create!(published: true)

    expect(validated.unpublish_all).to eq(1)
    expect(validated.pluck(:published)).to eq([false])
  end

  it "leaves no NULL behind on a nullable boolean column" do
    nullable = publishable_model("pbu_nullable_posts", :published)
    post = nullable.create!(published: true)
    nullable.create!(published: true)

    post.unpublish!
    nullable.unpublish_all

    expect(nullable.pluck(:published)).to eq([false, false])
    expect(nullable.unpublished.count).to eq(2)
  end

  it "still clears a timestamp column to NULL" do
    stamped = publishable_model("pbu_stamped_posts", :published_at)
    post = stamped.create!(published_at: 1.day.ago)
    stamped.create!(published_at: 1.day.ago)

    post.unpublish!
    expect(post.reload.published_at).to be_nil
    stamped.unpublish_all
    expect(stamped.pluck(:published_at)).to eq([nil, nil])
  end
end
