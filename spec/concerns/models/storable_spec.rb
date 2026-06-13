require "spec_helper"

describe ConcernsOnRails::Storable do
  before do
    ActiveRecord::Schema.define do
      create_table :storable_accounts, force: true do |t|
        t.text :settings
        t.json :prefs
        t.text :flags
        t.string :name
      end
    end
  end

  after(:each) do
    ActiveRecord::Base.connection.tables.each do |table|
      next if table == "schema_migrations"

      ActiveRecord::Base.connection.drop_table(table)
    end
  end

  # Anonymous classes avoid const leakage between examples.
  def model_class(&declaration)
    klass = Class.new(TestModel) do
      self.table_name = "storable_accounts"
      include ConcernsOnRails::Storable
    end
    klass.class_eval(&declaration) if declaration
    klass
  end

  describe "typed casting (text column)" do
    let(:klass) do
      model_class do
        storable_by :settings,
                    theme: { type: :string, default: "light" },
                    notifications: { type: :boolean, default: true },
                    items_per_page: { type: :integer, default: 25 },
                    ratio: { type: :float },
                    price: { type: :decimal },
                    starts_on: { type: :date },
                    trial_ends_at: { type: :datetime },
                    widgets: { type: :json, default: [] }
      end
    end

    it "round-trips a string through save and reload" do
      record = klass.create!(theme: "dark")
      expect(record.reload.theme).to eq("dark")
    end

    it "casts form-style string params to integers" do
      record = klass.new
      record.items_per_page = "50"
      expect(record.items_per_page).to eq(50)
    end

    it "casts form-style string params to floats" do
      record = klass.new
      record.ratio = "1.5"
      expect(record.ratio).to eq(1.5)
    end

    it "casts the truthy boolean param spellings" do
      record = klass.new
      %w[1 true t].each do |raw|
        record.notifications = raw
        expect(record.notifications).to be(true), "expected #{raw.inspect} to cast to true"
      end
    end

    it "casts the falsy boolean param spellings" do
      record = klass.new
      %w[0 false f].each do |raw|
        record.notifications = raw
        expect(record.notifications).to be(false), "expected #{raw.inspect} to cast to false"
      end
    end

    it "generates a predicate for boolean keys only" do
      record = klass.new
      record.notifications = "0"
      expect(record.notifications?).to be(false)
      expect(record).not_to respond_to(:theme?)
    end

    it "round-trips a decimal exactly, stored as a precision-safe string" do
      record = klass.create!(price: "0.1")
      expect(record.reload.price).to eq(BigDecimal("0.1"))
      expect(record.price).to be_a(BigDecimal)
      expect(JSON.parse(record.read_attribute(:settings))["price"]).to eq("0.1")
    end

    it "round-trips a date as an ISO8601 string" do
      record = klass.create!(starts_on: "2026-07-01")
      expect(record.reload.starts_on).to eq(Date.new(2026, 7, 1))
      expect(JSON.parse(record.read_attribute(:settings))["starts_on"]).to eq("2026-07-01")
    end

    it "round-trips a datetime in UTC at microsecond precision" do
      time = Time.utc(2026, 6, 13, 1, 2, 3, 123_456)
      record = klass.create!(trial_ends_at: time)
      expect(record.reload.trial_ends_at).to eq(time)
      expect(JSON.parse(record.read_attribute(:settings))["trial_ends_at"]).to eq("2026-06-13T01:02:03.123456Z")
    end

    it "reads unparseable datetime garbage as nil instead of raising" do
      record = klass.create!
      record.update_column(:settings, JSON.generate("trial_ends_at" => "not-a-time"))
      expect(record.reload.trial_ends_at).to be_nil
    end

    it "passes :json values through uncast" do
      record = klass.create!(widgets: [{ "id" => 1 }, { "id" => 2 }])
      expect(record.reload.widgets).to eq([{ "id" => 1 }, { "id" => 2 }])
    end

    it "returns a dup for :json values so in-place mutation cannot bypass the writer" do
      record = klass.create!(widgets: ["a"])
      record.widgets << "b"
      expect(record.widgets).to eq(["a"])
      expect(record.reload.widgets).to eq(["a"])
    end
  end

  describe "native json column" do
    let(:klass) do
      model_class do
        storable_by :prefs, digest: { type: :string, default: "weekly" }, seats: { type: :integer }
      end
    end

    it "stores a Hash (not a JSON string) and round-trips casts" do
      record = klass.create!(seats: "10")
      expect(record.read_attribute(:prefs)).to be_a(Hash)
      expect(record.reload.seats).to eq(10)
    end

    it "marks the column dirty on key writes" do
      record = klass.create!
      record.digest = "daily"
      expect(record.prefs_changed?).to be(true)
    end
  end

  describe "defaults" do
    it "returns the default when nothing is stored, without persisting it" do
      klass = model_class { storable_by :settings, theme: { default: "light" } }
      record = klass.create!
      expect(record.theme).to eq("light")
      expect(record.reload.read_attribute(:settings)).to be_nil
    end

    it "instance_execs a Proc default against the record" do
      klass = model_class { storable_by :settings, label: { default: -> { "#{name}-default" } } }
      record = klass.new(name: "acme")
      expect(record.label).to eq("acme-default")
    end

    it "deep-dups mutable defaults so mutation never leaks across instances" do
      klass = model_class { storable_by :settings, tags: { type: :json, default: [] } }
      klass.new.tags << "leak"
      expect(klass.new.tags).to eq([])
    end

    it "prefers a written value over the default" do
      klass = model_class { storable_by :settings, theme: { default: "light" } }
      record = klass.new(theme: "dark")
      expect(record.theme).to eq("dark")
    end
  end

  describe "nil vs unset" do
    let(:klass) { model_class { storable_by :settings, theme: { default: "light" } } }

    it "reads an explicitly-written nil as nil, not the default" do
      record = klass.create!(theme: "dark")
      record.theme = nil
      record.save!
      expect(record.reload.theme).to be_nil
      expect(JSON.parse(record.read_attribute(:settings))).to have_key("theme")
    end

    it "reset_<key> removes the key so the reader resolves the default again" do
      record = klass.create!(theme: "dark")
      record.reset_theme
      expect(record.theme).to eq("light")
      record.save!
      expect(JSON.parse(record.read_attribute(:settings))).not_to have_key("theme")
    end

    it "reset_<key> on an absent key is a no-op that does not dirty the column" do
      record = klass.create!
      record.reset_theme
      expect(record.settings_changed?).to be(false)
    end
  end

  describe "per-key dirty tracking" do
    let(:klass) do
      model_class do
        storable_by :settings, theme: { default: "light" }, notifications: { type: :boolean, default: true }
      end
    end

    it "tracks assignment on a new record, with _was returning the prior (default) value" do
      record = klass.new
      expect(record.theme_changed?).to be(false)
      record.theme = "dark"
      expect(record.theme_changed?).to be(true)
      expect(record.theme_was).to eq("light")
    end

    it "resets after save and tracks the next change with a cast _was" do
      record = klass.create!(theme: "dark")
      expect(record.theme_changed?).to be(false)
      record.theme = "solar"
      expect(record.theme_changed?).to be(true)
      expect(record.theme_was).to eq("dark")
    end

    it "leaves sibling keys unchanged when one key is written" do
      record = klass.create!
      record.theme = "dark"
      expect(record.notifications_changed?).to be(false)
      expect(record.settings_changed?).to be(true)
    end
  end

  describe "storage semantics" do
    let(:klass) { model_class { storable_by :settings, theme: { default: "light" } } }

    it "preserves undeclared keys through typed writes" do
      record = klass.create!
      record.update_column(:settings, JSON.generate("legacy" => 1))
      record.reload
      record.theme = "dark"
      record.save!
      expect(JSON.parse(record.reload.read_attribute(:settings))).to eq("legacy" => 1, "theme" => "dark")
    end

    it "preserves key insertion order" do
      klass = model_class { storable_by :settings, a: {}, b: {} }
      record = klass.new
      record.a = "1"
      record.b = "2"
      record.save!
      expect(JSON.parse(record.read_attribute(:settings)).keys).to eq(%w[a b])
    end

    it "stores string keys" do
      record = klass.new(theme: "dark")
      expect(JSON.parse(record.read_attribute(:settings))).to eq("theme" => "dark")
    end

    it "reads defaults out of a corrupt column without raising, and writes replace it" do
      record = klass.create!
      record.update_column(:settings, "{not json")
      record.reload
      expect(record.theme).to eq("light")
      record.theme = "dark"
      record.save!
      expect(JSON.parse(record.reload.read_attribute(:settings))).to eq("theme" => "dark")
    end
  end

  describe "in: validation" do
    let(:klass) do
      model_class { storable_by :settings, theme: { default: "light", in: %w[light dark] } }
    end

    it "passes a stored value inside the set" do
      expect(klass.new(theme: "dark")).to be_valid
    end

    it "rejects a stored value outside the set, on the accessor name" do
      record = klass.new(theme: "neon")
      expect(record).not_to be_valid
      expect(record.errors[:theme]).to include("is not included in the list")
    end

    it "passes when the key is absent (the default is not validated)" do
      expect(klass.new).to be_valid
    end

    it "passes an explicitly-written nil" do
      expect(klass.new(theme: nil)).to be_valid
    end

    it "reports errors on the affixed accessor name" do
      klass = model_class { storable_by :flags, { mode: { in: %w[a b] } }, prefix: :flag }
      record = klass.new(flag_mode: "c")
      expect(record).not_to be_valid
      expect(record.errors[:flag_mode]).to include("is not included in the list")
    end
  end

  describe "macro" do
    it "merges keys across repeat calls for the same column" do
      klass = model_class do
        storable_by :settings, theme: { default: "light" }
        storable_by :settings, lang: { default: "en" }
      end
      record = klass.new
      expect(record.theme).to eq("light")
      expect(record.lang).to eq("en")
    end

    it "keeps different columns independent" do
      klass = model_class do
        storable_by :settings, theme: { default: "light" }
        storable_by :flags, beta: { type: :boolean, default: false }
      end
      record = klass.new(theme: "dark", beta: true)
      record.save!
      expect(JSON.parse(record.read_attribute(:settings))).to eq("theme" => "dark")
      expect(JSON.parse(record.read_attribute(:flags))).to eq("beta" => true)
    end

    it "re-declaring the same key updates its spec instead of raising" do
      klass = model_class do
        storable_by :settings, theme: { default: "light" }
        storable_by :settings, theme: { default: "dark" }
      end
      expect(klass.new.theme).to eq("dark")
    end

    it "lets a subclass add keys without affecting the parent" do
      parent = model_class { storable_by :settings, theme: { default: "light" } }
      child = Class.new(parent) { storable_by :settings, lang: { default: "en" } }
      expect(child.new.lang).to eq("en")
      expect(child.new.theme).to eq("light")
      expect(parent.new).not_to respond_to(:lang)
      expect(parent.storable_keys[:settings]).not_to have_key(:lang)
    end

    it "affixes accessors with prefix: and suffix:" do
      klass = model_class do
        storable_by :flags, { beta: { type: :boolean, default: false } }, prefix: :flag
        storable_by :settings, { theme: { default: "light" } }, suffix: :setting
      end
      record = klass.new
      expect(record.flag_beta).to be(false)
      expect(record.flag_beta?).to be(false)
      expect(record.theme_setting).to eq("light")
      record.flag_beta = "1"
      expect(record.flag_beta_changed?).to be(true)
      record.reset_flag_beta
      expect(record.flag_beta).to be(false)
    end

    it "exposes the normalized registry on the class" do
      klass = model_class { storable_by :settings, theme: { type: :string, default: "light" } }
      spec = klass.storable_keys.fetch(:settings).fetch(:theme)
      expect(spec).to include(type: :string, default: "light", accessor: :theme)
    end

    it "accepts a key literally named prefix via the positional-hash escape hatch" do
      klass = model_class { storable_by :settings, { prefix: { type: :string, default: "pre" } } }
      expect(klass.new.prefix).to eq("pre")
    end

    describe "macro-time validation" do
      it "rejects a missing column" do
        expect { model_class { storable_by :nope, theme: {} } }
          .to raise_error(ArgumentError, /does not exist/)
      end

      it "rejects a key spec that is not a Hash" do
        expect { model_class { storable_by :settings, theme: "light" } }
          .to raise_error(ArgumentError, /must be a Hash/)
      end

      it "rejects unknown options inside a key spec" do
        expect { model_class { storable_by :settings, theme: { typo: 1 } } }
          .to raise_error(ArgumentError, /unknown option/)
      end

      it "rejects an unknown type" do
        expect { model_class { storable_by :settings, theme: { type: :uuid } } }
          .to raise_error(ArgumentError, /unknown type/)
      end

      it "rejects a non-enumerable in:" do
        expect { model_class { storable_by :settings, theme: { in: 5 } } }
          .to raise_error(ArgumentError, /enumerable/)
      end

      it "rejects a key colliding with an existing column" do
        expect { model_class { storable_by :settings, name: {} } }
          .to raise_error(ArgumentError, /collides/)
      end

      it "rejects a key colliding with an existing method" do
        expect do
          model_class do
            def theme
              "hard-coded"
            end

            storable_by :settings, theme: {}
          end
        end.to raise_error(ArgumentError, /collides/)
      end

      it "rejects the same accessor claimed from two different columns" do
        expect do
          model_class do
            storable_by :settings, beta: { type: :boolean }
            storable_by :flags, beta: { type: :boolean }
          end
        end.to raise_error(ArgumentError, /collides/)
      end
    end
  end
end
