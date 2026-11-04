require "spec_helper"

# TRANS-4 (audit 2026-10-29): with a multi-character delimiter that overlaps
# itself ("--"), a tag ending with the start of it ("a-") joined to "a---b",
# which splits as ["a", "-b"]: the tag was never stored as given and
# tagged_with("a-") could not find it. tag_list= also joined an Array and
# re-split it. A tag's trailing part that would run into the delimiter is now
# dropped when cleaning (as the delimiter itself splits a tag), and an Array is
# cleaned item by item.
describe "Taggable with a delimiter that overlaps itself" do
  before do
    ActiveRecord::Schema.define do
      create_table :straddle_posts, force: true do |t|
        t.string :tags
      end
    end
  end

  after { ActiveRecord::Base.connection.drop_table(:straddle_posts, if_exists: true) }

  def model(delimiter)
    Class.new(TestModel) do
      self.table_name = "straddle_posts"
      include ConcernsOnRails::Models::Taggable

      taggable_by :tags, delimiter: delimiter
    end
  end

  it "reads back what it stored, in memory and from the database" do
    klass = model("--")
    record = klass.new
    record.tag_list = ["a-", "b", "-c", "d--e"]

    expect(record.tag_list).to eq(%w[a b c d e])
    record.save!
    expect(klass.find(record.id).tag_list).to eq(%w[a b c d e])
    expect(klass.tagged_with("a", "b", "c")).to contain_exactly(record)
  end

  it "reads back every list over a small alphabet, for self-overlapping and plain delimiters" do
    ["--", "||", "-|-", " | ", ", ", ",", "ab"].each do |delimiter|
      klass = model(delimiter)
      alphabet = ["a", "-", "|", " ", "b"]
      pieces = (1..3).flat_map { |n| alphabet.repeated_permutation(n).map(&:join) }
      pieces.each_slice(3).first(300).each do |tags|
        record = klass.new
        record.tag_list = tags
        stored = record.tag_list
        reread = klass.new(tags: klass.taggable_join(stored)).tag_list
        expect(reread).to eq(stored), "delimiter #{delimiter.inspect}: #{tags.inspect} -> #{stored.inspect} -> #{reread.inspect}"
      end
    end
  end

  it "drops a leading part too, so tagged_with('b') never matches a stored '-b'" do
    klass = model("--")
    record = klass.create!(tag_list: ["x", "-b"])

    expect(record.reload.tag_list).to eq(%w[x b])
    expect(klass.create!(tag_list: ["x", "-y"]).reload.tag_list).to eq(%w[x y])
    expect(klass.tagged_with("-b")).to contain_exactly(record)
    expect(klass.where(id: record.id).tagged_with("c")).to be_empty
  end

  it "keeps a tag intact under a delimiter that does not overlap itself" do
    ["--x", ", ", " | ", ","].each do |delimiter|
      record = model(delimiter).new
      record.tag_list = ["a-", "b,", "c |", "d"]
      expect(record.tag_list).to include("a-", "d")
    end
  end

  it "keeps whitespace-padded delimiters working" do
    record = model(", ").new
    record.tag_list = " ruby ,  rails "
    expect(record.tag_list).to eq(%w[ruby rails])
    record.add_tags("go")
    expect(record.tags).to eq("ruby, rails, go")
  end

  it "drops a tag that is nothing but the delimiter's start" do
    record = model("--").new
    record.tag_list = ["-", "x"]

    expect(record.tag_list).to eq(%w[x])
  end
end
