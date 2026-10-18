require "spec_helper"
require "erb"

# Audit 2026-10-10, TRANS-9. Each before_validation pass re-applied every rule
# to the current value, ignoring what the previous, still-unconsumed pass had
# produced. `record.save if record.valid?` validates twice, so a
# non-idempotent Proc ran twice ("Tom &amp;amp; Jerry"). The same held for
# Sanitizable `on: :write`; Addressable mirrors the fix.
describe "Field transforms run once when valid? precedes save" do
  before do
    ActiveRecord::Schema.define do
      create_table :valid_then_save_posts, force: true do |t|
        t.string :title
        t.integer :views
      end

      create_table :valid_then_save_locations, force: true do |t|
        t.string :line1
        t.string :city
        t.string :postal_code
        t.string :country
      end
    end
  end

  after do
    %i[valid_then_save_posts valid_then_save_locations].each do |table|
      ActiveRecord::Base.connection.drop_table(table, if_exists: true)
    end
  end

  escape = ->(v) { ERB::Util.html_escape(v).to_str }

  let(:normalized) do
    Class.new(TestModel) do
      self.table_name = "valid_then_save_posts"
      include ConcernsOnRails::Models::Normalizable

      normalizable :title, with: escape
    end
  end

  let(:sanitized) do
    Class.new(TestModel) do
      self.table_name = "valid_then_save_posts"
      include ConcernsOnRails::Models::Sanitizable

      sanitizable :title, with: escape, on: :write
    end
  end

  %i[normalized sanitized].each do |kind|
    context "with a #{kind == :normalized ? 'Normalizable' : 'Sanitizable on: :write'} Proc" do
      let(:klass) { public_send(kind) }

      it "applies it once for a new record (save! if valid?)" do
        record = klass.new(title: "Tom & Jerry")
        record.save! if record.valid?

        expect(record.reload.title).to eq("Tom &amp; Jerry")
      end

      it "applies it once on an update (save! if valid?)" do
        record = klass.create!(title: "x")
        record.title = "Tom & Jerry"
        record.save! if record.valid?

        expect(record.reload.title).to eq("Tom &amp; Jerry")
      end

      it "applies it once across repeated validations" do
        record = klass.new(title: "Tom & Jerry")
        3.times { record.valid? }
        record.save!

        expect(record.reload.title).to eq("Tom &amp; Jerry")
      end

      it "still applies it to a value assigned between the validations" do
        record = klass.new(title: "a & b")
        record.valid?
        record.title = "Tom & Jerry"
        record.save!

        expect(record.reload.title).to eq("Tom &amp; Jerry")
      end

      it "starts afresh with the next save cycle" do
        record = klass.create!(title: "Tom & Jerry")
        record.title = "Bert & Ernie"
        record.save! if record.valid?

        expect(record.reload.title).to eq("Bert &amp; Ernie")
      end
    end
  end

  # Two transforms on ONE column. Normalizable compares against what IT
  # produced; Sanitizable's writer rewrote the field after that, so a repeat
  # validation ran Normalizable again (titleize turned "&amp;" into "&Amp;")
  # and Sanitizable then saw a changed value and escaped it a second time.
  # A validated save has to store exactly what a plain save stores.
  context "with Normalizable and a Sanitizable on: :write rule on the same column" do
    bang = ->(v) { "#{v}!" }

    {
      "Normalizable first" => %i[normalizable sanitizable],
      "Sanitizable first" => %i[sanitizable normalizable]
    }.each do |label, order|
      {
        "titleize + html_escape" => [:titleize, escape, "tom & jerry"],
        "bang + html_escape" => [bang, escape, "a&b"]
      }.each do |procs, (norm, san, input)|
        context "#{label}, #{procs}" do
          let(:klass) do
            # The include order is what orders the before_validation passes.
            k = Class.new(TestModel)
            k.table_name = "valid_then_save_posts"
            order.each do |kind|
              if kind == :normalizable
                k.include ConcernsOnRails::Models::Normalizable
                k.normalizable :title, with: norm
              else
                k.include ConcernsOnRails::Models::Sanitizable
                k.sanitizable :title, with: san, on: :write
              end
            end
            k
          end
          let(:plain) { klass.create!(title: input).reload.title }

          it "stores what a plain save stores (valid? then save)" do
            record = klass.new(title: input)
            record.save! if record.valid?

            expect(record.reload.title).to eq(plain)
          end

          it "stores what a plain save stores across repeated validations" do
            record = klass.new(title: input)
            3.times { record.valid? }
            record.save!

            expect(record.reload.title).to eq(plain)
          end

          it "stores what a plain save stores on an update" do
            record = klass.create!(title: "seed")
            record.title = input
            record.save! if record.valid?

            expect(record.reload.title).to eq(plain)
          end

          it "treats an update_attribute after a stray valid? like a fresh one" do
            expected = klass.create!(title: "seed").tap { |r| r.update_attribute(:title, input) }.reload.title

            record = klass.create!(title: "seed")
            record.title = "stray"
            record.valid? # never followed by a save
            record.update_attribute(:title, input)

            expect(record.reload.title).to eq(expected)
          end
        end
      end
    end
  end

  # The previous pass's record belongs to one unsaved state of the row: a
  # reload throws that state away, so a value assigned afterwards is new work.
  {
    "Normalizable" => ->(k, proc) { k.normalizable :title, with: proc },
    "Sanitizable on: :write" => ->(k, proc) { k.sanitizable :title, with: proc, on: :write }
  }.each do |label, declare|
    it "runs a #{label} Proc on a value assigned after a reload" do
      klass = Class.new(TestModel) do
        self.table_name = "valid_then_save_posts"
        include ConcernsOnRails::Models::Normalizable
        include ConcernsOnRails::Models::Sanitizable
      end
      declare.call(klass, ->(v) { "#{v}!" })
      record = klass.create!(title: "seed")
      record.title = "a"
      record.valid? # "a" -> "a!", never saved
      record.reload
      record.title = "a!"
      record.save!

      expect(record.reload.title).to eq("a!!")
    end
  end

  it "normalizes Addressable parts once when valid? precedes save" do
    klass = Class.new(TestModel) do
      self.table_name = "valid_then_save_locations"
      include ConcernsOnRails::Models::Addressable

      addressable_by
    end
    record = klass.new(line1: " 1  Main St ", city: " Ottawa ", postal_code: "k1a0b1", country: "ca")
    calls = 0
    allow(record).to receive(:normalize_part).and_wrap_original do |original, *args|
      calls += 1
      original.call(*args)
    end

    record.save! if record.valid?

    expect(calls).to eq(4) # one per column, not two
    expect(record.reload.postal_code).to eq("K1A 0B1")
  end
end
