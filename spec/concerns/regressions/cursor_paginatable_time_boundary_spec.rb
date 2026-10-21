require "spec_helper"

# Audit 2026-10-10 PARAM-11 (Rails 6.0 / 6.1). A `time` column's boundary was
# minted as iso8601(6) — "2000-01-01T10:30:15.500000Z" — and Rails 6.0/6.1's
# Time type misreads that T-separated form: its fast path only strips a date
# followed by a SPACE, so the String falls through to Date._parse, whose
# sec_fraction is passed on as microseconds (10:30:15.0000005). The WHERE then
# bound 10:30:15, the boundary row (10:30:15.5) was "after" its own cursor,
# and every next page returned that same row with has_more: true — a client
# following X-Next-Cursor never terminated. The walk must visit every row once
# whether or not the column is time-zone aware, and under default_timezone
# :local too, including times whose UTC rendering falls on another day.
describe ConcernsOnRails::Controllers::CursorPaginatable do
  # Ties, fractions, and times that fall on the previous / next UTC day in
  # Tokyo (08:15 JST) and New York (21:45 EST).
  let(:slot_times) do
    %w[09:00 09:00 10:30:15.5 12:00:00.25 23:59:59.999999 08:15:30.75 21:45:00.5 00:00:00.000001]
  end

  before do
    ActiveRecord::Schema.define(verbose: false) do
      create_table :time_slots, force: true do |t|
        t.time :opens_at, precision: 6
      end
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  def controller_class(bidirectional: false)
    Class.new(FakeController) do
      include ConcernsOnRails::Controllers::CursorPaginatable

      cursor_paginate_by order: { opens_at: :asc }, per_page: 1, bidirectional: bidirectional
    end
  end

  # Follows `key` from `cursor` until it runs out (or a few pages past the
  # row count, so an endless walk shows up as repeated ids). [ids, last meta]
  def walk(model, klass: controller_class, cursor: nil, key: :next_cursor)
    seen = []
    meta = nil
    (slot_times.size + 3).times do
      controller = klass.new(params: { cursor: cursor })
      seen.concat(controller.cursor_paginated(model.all).map(&:id))
      meta = controller.cursor_pagination_meta
      cursor = meta[key]
      break unless cursor
    end
    [seen, meta]
  end

  def seeded_model(&block)
    model = Class.new(TestModel) do
      self.table_name = "time_slots"
      class_eval(&block) if block
    end
    slot_times.each { |time| model.create!(opens_at: time) }
    model
  end

  def database_order(model)
    model.order(:opens_at, :id).pluck(:id)
  end

  it "walks a time column with fractional seconds, every row once" do
    model = seeded_model

    expect(walk(model).first).to eq(database_order(model))
  end

  it "walks a time column back from its last page, every row once" do
    model = seeded_model
    klass = controller_class(bidirectional: true)
    forward, last_meta = walk(model, klass: klass)
    backward, = walk(model, klass: klass, cursor: last_meta[:prev_cursor], key: :prev_cursor)

    expect(forward).to eq(database_order(model))
    expect(backward).to eq(database_order(model).reverse.drop(1))
  end

  it "walks a time-zone-aware time column (Time.zone not UTC), every row once" do
    Time.use_zone("Eastern Time (US & Canada)") do
      model = seeded_model { self.time_zone_aware_attributes = true }

      expect(walk(model).first).to eq(database_order(model))
    end
  end

  it "walks a time column under default_timezone :local, every row once" do
    holder = ActiveRecord.respond_to?(:default_timezone=) ? ActiveRecord : ActiveRecord::Base
    old_zone = holder.default_timezone
    old_tz = ENV.fetch("TZ", nil)
    begin
      ENV["TZ"] = "Asia/Tokyo"
      holder.default_timezone = :local
      model = seeded_model

      expect(walk(model).first).to eq(database_order(model))
    ensure
      holder.default_timezone = old_zone
      ENV["TZ"] = old_tz
    end
  end

  # Cursors minted before the fix carry the ISO 8601 form, and a zoned String
  # is still cast as it always was: an in-flight cursor on a time-zone-aware
  # column (every Rails app's setting) continues from its own boundary.
  it "continues a walk from a cursor minted in the old ISO 8601 form" do
    Time.use_zone("Eastern Time (US & Canada)") do
      model = seeded_model { self.time_zone_aware_attributes = true }
      rows = model.order(:opens_at, :id).to_a

      rows.each_with_index do |boundary, index|
        payload = { "t" => "time_slots", "o" => %w[opens_at:asc id:asc], "d" => "next",
                    "v" => [boundary.opens_at.getutc.iso8601(6), boundary.id] }
        legacy = [JSON.generate(payload)].pack("m0").tr("+/", "-_").delete("=")

        expect(walk(model, cursor: legacy).first).to eq(rows.drop(index + 1).map(&:id)), "after #{boundary.opens_at.inspect}"
      end
    end
  end
end
