require "spec_helper"
require "base64"
require "securerandom"

# Audit 2026-10-10 PARAM-3. The primary key is always appended as the keyset
# tiebreaker, so with a binary(16) primary key (the MySQL "UUID as binary"
# layout) — or a binary ordering column — every page boundary carried raw
# bytes that are not UTF-8, and JSON.generate raised JSON::GeneratorError on
# EVERY page that had a next page: the endpoint could not paginate at all.
# A binary boundary is now carried as strict Base64 and decoded on the way
# back; a boundary that is not Base64 is an InvalidCursor.
describe ConcernsOnRails::Controllers::CursorPaginatable do
  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :binary_docs, id: false, force: true do |t|
        t.binary :id, limit: 16, primary_key: true, null: false
        t.string :name
      end
      create_table :binary_blobs, force: true do |t|
        t.binary :sort_key, limit: 16, null: false
        t.string :name
      end
    end
    stub_const("BinaryDoc", Class.new(TestModel) do
      self.table_name = "binary_docs"
      self.primary_key = "id"
    end)
    stub_const("BinaryBlob", Class.new(TestModel) { self.table_name = "binary_blobs" })
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  def controller_for(order, **options)
    Class.new(FakeController) do
      include ConcernsOnRails::Controllers::CursorPaginatable

      cursor_paginate_by order: order, per_page: 2, **options
    end
  end

  def walk(klass, relation)
    seen = []
    token = nil
    10.times do
      controller = klass.new(params: { cursor: token })
      seen.concat(controller.cursor_paginated(relation).map(&:name))
      token = controller.cursor_pagination_meta[:next_cursor]
      break unless token
    end
    seen
  end

  it "walks a table with a binary primary key (the tiebreaker) page by page" do
    5.times { |i| BinaryDoc.create!(id: SecureRandom.random_bytes(16), name: "doc#{i}") }

    expect(walk(controller_for({ name: :asc }), BinaryDoc.all)).to eq(%w[doc0 doc1 doc2 doc3 doc4])
  end

  it "walks a binary ordering column, every row once in byte order" do
    keys = Array.new(5) { SecureRandom.random_bytes(16) }
    keys.each_with_index { |key, i| BinaryBlob.create!(sort_key: key, name: "blob#{i}") }
    expected = keys.each_with_index.sort_by(&:first).map { |_key, i| "blob#{i}" }

    expect(walk(controller_for({ sort_key: :asc }), BinaryBlob.all)).to eq(expected)
    expect(walk(controller_for({ sort_key: :asc }, predicate: :row), BinaryBlob.all)).to eq(expected)
  end

  it "walks a binary ordering column under a signed cursor" do
    keys = Array.new(3) { SecureRandom.random_bytes(16) }
    keys.each_with_index { |key, i| BinaryBlob.create!(sort_key: key, name: "blob#{i}") }
    expected = keys.each_with_index.sort_by(&:first).map { |_key, i| "blob#{i}" }

    expect(walk(controller_for({ sort_key: :asc }, signed: "k" * 32), BinaryBlob.all)).to eq(expected)
  end

  it "rejects a binary boundary that is not strict Base64, or not a String, as an InvalidCursor" do
    BinaryBlob.create!(sort_key: SecureRandom.random_bytes(16), name: "blob")
    klass = controller_for({ sort_key: :asc })

    ["not base64!", "abc", 12].each do |boundary|
      payload = { "t" => "binary_blobs", "o" => ["sort_key:asc", "id:asc"], "d" => "next", "v" => [boundary, 1] }
      token = [JSON.generate(payload)].pack("m0").tr("+/", "-_").delete("=")
      expect { klass.new(params: { cursor: token }).cursor_paginated(BinaryBlob.all) }
        .to raise_error(ConcernsOnRails::Controllers::CursorPaginatable::InvalidCursor)
    end
  end
end
