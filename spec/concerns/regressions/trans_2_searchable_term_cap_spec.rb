require "spec_helper"

# TRANS-2: mode: :all turned every word of an untrusted query into an AND-ed
# predicate (and, ranked, a CASE per word) with no cap, so a ~5 KB query hit
# SQLite's expression-tree limit and a ~10 KB ranked one burned seconds of CPU.
describe "Searchable term cap (TRANS-2)" do
  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :trans_rows, force: true do |t|
        t.string :title
        t.text :body
      end
    end
  end
  after { ActiveRecord::Base.connection.drop_table(:trans_rows) }

  def searchable_class(ranked:)
    Class.new(TestModel) do
      self.table_name = "trans_rows"
      include ConcernsOnRails::Searchable

      searchable_by :title, :body, mode: :all, ranked: ranked
    end
  end

  def distinct_query(count)
    (1..count).map { |i| "t#{i}" }.join(" ")
  end

  it "does not crash on a ~5 KB query of distinct terms" do
    expect { searchable_class(ranked: false).search(distinct_query(1000)).to_a }.not_to raise_error
  end

  it "builds the SQL of a huge ranked query in time independent of its word count" do
    klass = searchable_class(ranked: true)
    clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    klass.search("warm up").to_sql
    started = clock.call
    klass.search(distinct_query(50)).to_sql
    baseline = clock.call - started
    started = clock.call
    klass.search(distinct_query(1500)).to_sql
    huge = clock.call - started

    expect(huge).to be < [baseline * 10, 0.2].max
  end

  it "ANDs at most MAX_TERMS distinct words and ignores repeats" do
    klass = searchable_class(ranked: false)
    cap = ConcernsOnRails::Models::Searchable::MAX_TERMS
    sql = klass.search(distinct_query(cap + 10)).to_sql
    expect(sql.scan("LIKE").size).to eq(cap * 2)
    expect(sql).not_to include("t#{cap + 1}%")
    expect(klass.search("rails rails rails").to_sql.scan("LIKE").size).to eq(2)
  end

  it "still matches on the leading terms of a capped query" do
    klass = searchable_class(ranked: false)
    cap = ConcernsOnRails::Models::Searchable::MAX_TERMS
    leading = (1..cap).map { |i| "t#{i}" }
    klass.create!(title: leading.join(" "))
    klass.create!(title: leading.first(cap - 1).join(" "))
    klass.create!(title: "unrelated")

    found = klass.search(distinct_query(cap + 10)).pluck(:title)
    expect(found).to eq([leading.join(" ")]) # the first `cap` terms decide; the extras are ignored
  end
end
