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

  # `serialize :col, coder:, type:` is Rails 7.1+ syntax; 5.0-7.0 (which the
  # gemspec still supports) take the coder positionally, and 7.1 deprecates
  # that form. Both shapes must be recognized as JSON / non-JSON alike.
  def serialized_model(coder, &declaration)
    klass = Class.new(TestModel) { self.table_name = "storable_accounts" }
    if ActiveRecord.version >= Gem::Version.new("7.1")
      klass.serialize :settings, coder: coder, type: Hash
    elsif coder == YAML
      # 5.0-7.0 have no ColumnSerializer to wrap the coder in: `serialize :col,
      # YAML` installs the bare module, whose `load(nil)` raises TypeError on
      # the first read. `serialize :col, Hash` is that era's spelling of a YAML
      # column — an ActiveRecord::Coders::YAMLColumn, equally non-JSON.
      klass.serialize :settings, Hash
    else
      klass.serialize :settings, coder
    end
    klass.include ConcernsOnRails::Storable
    klass.class_eval(&declaration)
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

    it "dups a mutable String default so in-place mutation never leaks across instances" do
      klass = model_class { storable_by :settings, theme: { type: :string, default: +"light" } }
      klass.new.theme << "-custom"
      expect(klass.new.theme).to eq("light")
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

      it "rejects a key name that is not a plain identifier" do
        # A key names the generated methods AND the `$.key` JSON path the query
        # scopes address: a "." would reach into a nested document and a "?"
        # would break the emitted fragment's bind-parameter arity.
        expect { model_class { storable_by :settings, 'theme.dark': {} } }
          .to raise_error(ArgumentError, /must be a plain identifier/)
        expect { model_class { storable_by :settings, theme?: {} } }
          .to raise_error(ArgumentError, /must be a plain identifier/)
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

  describe "querying: where_<key> scopes" do
    let(:klass) do
      model_class do
        storable_by :settings,
                    theme: { default: "light", in: %w[light dark] },
                    notifications: { type: :boolean, default: true },
                    items_per_page: { type: :integer },
                    ratio: { type: :float },
                    price: { type: :decimal },
                    trial_ends_at: { type: :datetime },
                    widgets: { type: :json }
        storable_by :prefs, digest: { type: :string }, seats: { type: :integer }
        storable_by :flags, { beta: { type: :boolean } }, prefix: :flag
      end
    end

    it "refuses to query a column the host app serialized with a non-JSON coder" do
      # Reads and writes are supported on such a column, but it holds YAML, so
      # json_extract would fail deep in the adapter ("malformed JSON").
      yaml_klass = serialized_model(YAML) { storable_by :settings, theme: { default: "light" } }
      yaml_klass.create!(theme: "dark")

      expect { yaml_klass.where_theme("dark").to_a }
        .to raise_error(ArgumentError, /serialized with a non-JSON coder/)
    end

    describe "a column that is also encryptable" do
      # The column holds a ciphertext envelope, not JSON: the scope used to
      # return nothing for a real value and — worse — `where_<key>(nil)`
      # matched EVERY row (json_valid is false for ciphertext, so the key read
      # as NULL everywhere); PostgreSQL/MySQL raised deep in the adapter.
      before do
        ConcernsOnRails.encryption.key = "storable-spec-encryption-key"
        ConcernsOnRails.encryption.on_missing_key = :raise
      end

      after { ConcernsOnRails.encryption.key = nil }

      {
        "encryptable declared after storable_by" => proc do
          storable_by :settings, theme: { default: "light" }
          include ConcernsOnRails::Models::Encryptable

          encryptable :settings
        end,
        "encryptable declared before storable_by" => proc do
          include ConcernsOnRails::Models::Encryptable

          encryptable :settings
          storable_by :settings, theme: { default: "light" }
        end
      }.each do |order, declaration|
        it "refuses to query it (#{order}) instead of failing open" do
          encrypted_klass = model_class(&declaration)
          record = encrypted_klass.create!(theme: "dark")
          encrypted_klass.create!

          # Reads and writes still work through the encrypted type.
          expect(encrypted_klass.find(record.id).theme).to eq("dark")
          expect(encrypted_klass.find(record.id).settings_encrypted?).to be(true)

          expect { encrypted_klass.where_theme("dark").to_a }
            .to raise_error(ArgumentError, /'settings' is encrypted/)
          expect { encrypted_klass.where_theme(nil).to_a }
            .to raise_error(ArgumentError, /'settings' is encrypted/)
        end
      end
    end

    it "queries a column serialized with the JSON coder" do
      # Rails 7.1 hides the coder inside an ActiveRecord::Coders::ColumnSerializer,
      # so the canonical `serialize :settings, coder: JSON, type: Hash` looked
      # non-JSON until the coder was unwrapped.
      json_klass = serialized_model(JSON) { storable_by :settings, theme: { default: "light" } }
      dark = json_klass.create!(theme: "dark")
      json_klass.create!(theme: "light")

      expect(json_klass.where_theme("dark")).to eq([dark])
    end

    it "filters a text-column store by key with typed values" do
      dark = klass.create!(theme: "dark", items_per_page: 50, notifications: false, ratio: 1.5, price: "19.99",
                           trial_ends_at: Time.utc(2026, 1, 2, 3, 4, 5))
      light = klass.create!(theme: "light", items_per_page: 25, notifications: true)
      klass.create! # never writes a key — defaults are not queryable

      expect(klass.where_theme("dark")).to eq([dark])
      expect(klass.where_items_per_page(50)).to eq([dark])
      expect(klass.where_items_per_page("25")).to eq([light]) # cast like the writer
      expect(klass.where_notifications(false)).to eq([dark])
      expect(klass.where_notifications(true)).to eq([light]) # the third row never stored the key — defaults are not queryable
      expect(klass.where_ratio(1.5)).to eq([dark])
      expect(klass.where_price(BigDecimal("19.99"))).to eq([dark])
      expect(klass.where_price("19.99")).to eq([dark])
      expect(klass.where_trial_ends_at(Time.utc(2026, 1, 2, 3, 4, 5))).to eq([dark])
    end

    it "nil matches an unset key, an explicit JSON null and a NULL column, and the scope chains" do
      unset = klass.create!(name: "u")
      explicit = klass.create!(name: "e", theme: nil)
      klass.create!(name: "d", theme: "dark")

      expect(klass.where_theme(nil).order(:id)).to eq([unset, explicit])
      expect(klass.where(name: "d").where_theme("dark").count).to eq(1)
      expect(klass.where(name: "u").where_theme("dark").count).to eq(0)
    end

    it "reads a blank or corrupt column as an unset key wherever the adapter can test JSON validity" do
      # The readers decode such a row as {}; without the json_valid guard
      # json_extract raises "malformed JSON" and takes the whole query with it.
      dark = klass.create!(name: "d", theme: "dark")
      blank = klass.create!(name: "b")
      corrupt = klass.create!(name: "c")
      klass.where(name: "b").update_all(settings: "")
      klass.where(name: "c").update_all(settings: "not json at all")

      if TestDatabase.sqlite?
        expect(klass.where_theme("dark")).to eq([dark])
        expect(klass.where_theme(nil).order(:id)).to eq([blank, corrupt])
      else
        # The documented limitation (README + docs/concerns/storable.md):
        # PostgreSQL's ::jsonb cast of a text store and MySQL's JSON_EXTRACT get
        # no guard, so ONE such row fails the whole query. Asserted rather than
        # skipped, so the day that stops being true this example says so.
        expect { klass.where_theme("dark").to_a }.to raise_error(ActiveRecord::StatementInvalid)
      end
    end

    it "works on native json columns and affixed accessors" do
      klass.create!(digest: "daily", seats: 3, flag_beta: true)
      klass.create!(digest: "weekly", seats: 3, flag_beta: false)

      expect(klass.where_digest("daily").count).to eq(1)
      expect(klass.where_seats(3).count).to eq(2)
      expect(klass.where_flag_beta(true).count).to eq(1)
      expect(klass.where_flag_beta(false).count).to eq(1)
    end

    it "rejects a value that will not cast to the key's type" do
      # The comparison it would otherwise emit is adapter-dependent nonsense:
      # `= ''` on PostgreSQL/MySQL (matching empty strings), `= NULL` on SQLite.
      expect { klass.where_price("not money") }
        .to raise_error(ArgumentError, /where_price: "not money" is not a valid :decimal value/)
      expect { klass.where_trial_ends_at("whenever") }
        .to raise_error(ArgumentError, /is not a valid :datetime value/)
      expect { klass.where_notifications("") }
        .to raise_error(ArgumentError, /is not a valid :boolean value/)
    end

    it "does not mutate the Time it is handed" do
      time = Time.new(2026, 1, 2, 3, 4, 5, "+02:00").freeze
      record = klass.create!(trial_ends_at: time)

      expect(klass.where_trial_ends_at(time)).to eq([record])
      expect(time.utc_offset).to eq(7200)
    end

    it "emits the adapter's own extraction (json_valid-guarded on SQLite) and refuses :json keys" do
      column = TestDatabase.qualified("storable_accounts", "settings")
      expression =
        if TestDatabase.postgresql?
          %(((#{column})::jsonb ->> 'theme'))
        elsif TestDatabase.mysql?
          %(JSON_UNQUOTE(JSON_EXTRACT(#{column}, '$.theme')))
        else
          # SQLite's json_valid guard is what keeps a blank or corrupt row from
          # taking the whole query down with it.
          %((CASE WHEN json_valid(#{column}) THEN json_extract(#{column}, '$.theme') END))
        end

      expect(klass.where_theme("dark").to_sql).to include("#{expression} = 'dark'")
      expect(klass.where_theme(nil).to_sql).to include("#{expression} IS NULL")
      expect { klass.where_widgets([]) }.to raise_error(ArgumentError, /where_widgets: :json keys are not queryable/)
    end

    it "tells an explicit JSON null apart from the string 'null' on MySQL" do
      # JSON_UNQUOTE renders a stored JSON null as the 4-character string
      # 'null', so IS NULL alone would miss it and = 'null' would match all of them.
      allow(klass).to receive(:storable_adapter).and_return(:mysql)
      column = TestDatabase.qualified("storable_accounts", "settings")
      json_type = %(JSON_TYPE(JSON_EXTRACT(#{column}, '$.theme')) = 'NULL')

      expect(klass.where_theme(nil).to_sql).to include("IS NULL OR #{json_type}")
      expect(klass.where_theme("null").to_sql).to include("= 'null' AND NOT (#{json_type})")
      # and chained, the fragment is grouped — the OR cannot leak past an AND
      expect(klass.where(name: "x").where_theme(nil).to_sql).to include("'x' AND (JSON_UNQUOTE")
    end

    describe "the where_ scope name" do
      it "leaves a class method the host app already defines alone, warning instead of raising" do
        host = nil

        expect do
          host = model_class do
            def self.where_theme(*)
              :host
            end

            storable_by :settings, theme: { default: "light" }
          end
        end.to output(/already defines 'where_theme'/).to_stderr

        expect(host.where_theme("dark")).to eq(:host) # not clobbered
        expect(host.new.theme).to eq("light")         # and the key is still declared
      end

      it "detects one hidden behind private_class_method" do
        host = nil

        expect do
          host = model_class do
            def self.where_theme(*)
              :host
            end
            private_class_method :where_theme

            storable_by :settings, theme: {}
          end
        end.to output(/already defines 'where_theme'/).to_stderr

        expect(host.send(:where_theme, "dark")).to eq(:host)
      end

      it "skips the scope for query: false, per key and per macro" do
        opted_out = model_class do
          storable_by :settings, theme: {}, items_per_page: { type: :integer, query: false }
          storable_by :flags, { beta: { type: :boolean } }, query: false
        end

        expect(opted_out).to respond_to(:where_theme)
        expect(opted_out).not_to respond_to(:where_items_per_page)
        expect(opted_out).not_to respond_to(:where_beta)
        expect(opted_out.new).to respond_to(:items_per_page, :beta) # the accessors are untouched
      end

      it "re-declares its own scope without warning" do
        merged = nil

        expect do
          merged = model_class do
            storable_by :settings, theme: { default: "light" }
            storable_by :settings, theme: { default: "dark" } # same key re-declared — merge, no collision
          end
        end.not_to output.to_stderr

        expect(merged).to respond_to(:where_theme)
        expect(merged.new.theme).to eq("dark")
      end
    end
  end
end
