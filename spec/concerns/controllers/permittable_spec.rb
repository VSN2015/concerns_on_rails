require "spec_helper"
require "support/integration_harness"

describe ConcernsOnRails::Controllers::Permittable do
  # FakeController responds to neither before_action nor rescue_from, so the
  # concern's guarded included-block installs nothing — specs drive
  # #permitted_params / #enforce_params_contract directly.
  def permittable_class(&declaration)
    Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Permittable

      class_eval(&declaration) if declaration
    end
  end

  def controller(klass, params: {}, action: "create")
    c = klass.new(params: params)
    c.define_singleton_method(:action_name) { action }
    c
  end

  # Build + validate in one step for the common case.
  def permit(params, action: "create", &declaration)
    controller(permittable_class(&declaration), params: params, action: action).permitted_params
  end

  def violations_for(params, action: "create", &declaration)
    permit(params, action: action, &declaration)
    raise "expected InvalidParameters"
  rescue described_class::InvalidParameters => e
    e
  end

  after { ConcernsOnRails.filter_parameter_registry.reset! }

  describe "macro validation" do
    it "requires a block" do
      expect { permittable_class { permit_params :create } }
        .to raise_error(ArgumentError, /requires a block/)
    end

    it "rejects an empty contract" do
      expect { permittable_class { permit_params(:create) {} } }
        .to raise_error(ArgumentError, /at least one field/)
    end

    it "rejects an unknown :unknown mode" do
      expect { permittable_class { permit_params(:create, unknown: :explode) { required :a } } }
        .to raise_error(ArgumentError, /:unknown must be one of ignore, log, error/)
    end

    it "rejects an unknown field option, naming the allowed ones" do
      expect { permittable_class { permit_params(:create) { required :a, :string, minimum: 3 } } }
        .to raise_error(ArgumentError, /unknown option\(s\) :minimum for field :a.*allowed:/)
    end

    it "rejects an unknown type" do
      expect { permittable_class { permit_params(:create) { required :a, :money } } }
        .to raise_error(ArgumentError, /unknown type :money.*supported: string, integer/)
    end

    it "rejects required + default (default implies optional)" do
      expect { permittable_class { permit_params(:create) { required :a, :string, default: "x" } } }
        .to raise_error(ArgumentError, /required and cannot have a :default/)
    end

    it "rejects format/length/normalize on non-string fields" do
      %i[format length normalize].zip([/\d/, 1..3, :squish]).each do |opt, value|
        expect { permittable_class { permit_params(:create) { required :a, :integer, opt => value } } }
          .to raise_error(ArgumentError, /:#{opt} is only supported on :string fields/)
      end
    end

    it "rejects :in that does not respond to include?" do
      expect { permittable_class { permit_params(:create) { required :a, :integer, in: 5 } } }
        .to raise_error(ArgumentError, /:in for field :a must respond to include\?/)
    end

    it "rejects a non-callable :validate" do
      expect { permittable_class { permit_params(:create) { required :a, :string, validate: :nope } } }
        .to raise_error(ArgumentError, /:validate for field :a must be callable/)
    end

    it "rejects a duplicate field in the same contract" do
      expect { permittable_class { permit_params(:create) { required :a; optional :a } } }
        .to raise_error(ArgumentError, /:a is declared twice/)
    end

    it "rejects a type combined with a nested block" do
      expect { permittable_class { permit_params(:create) { required(:a, :string) { required :b } } } }
        .to raise_error(ArgumentError, /takes a type OR a nested block/)
    end

    it "rejects an empty nested block" do
      expect { permittable_class { permit_params(:create) { required(:a) {} } } }
        .to raise_error(ArgumentError, /nested field :a declares no sub-fields/)
    end

    it "rejects array with both of: and a block" do
      expect { permittable_class { permit_params(:create) { array(:a, of: :string) { required :b } } } }
        .to raise_error(ArgumentError, /takes of: OR a block/)
    end

    it "rejects a non-Array array default and elements violating of:" do
      expect { permittable_class { permit_params(:create) { array :a, default: "x" } } }
        .to raise_error(ArgumentError, /:default for array :a must be an Array/)
      expect { permittable_class { permit_params(:create) { array :a, of: :integer, default: ["x"] } } }
        .to raise_error(ArgumentError, /contains an element violating of: :integer/)
    end

    it "rejects a default that violates the field's own contract" do
      expect { permittable_class { permit_params(:create) { optional :a, :string, in: %w[x y], default: "z" } } }
        .to raise_error(ArgumentError, /:default for field :a violates its own contract \(inclusion\)/)
    end

    it "rejects an unknown normalize preset, listing the presets" do
      expect { permittable_class { permit_params(:create) { optional :a, :string, normalize: :shout } } }
        .to raise_error(ArgumentError, /unknown :normalize preset :shout.*squish, strip, downcase, upcase, email/)
    end
  end

  describe "type casting" do
    it "casts integers strictly" do
      result = permit({ n: "42" }) { permit_params(:create) { required :n, :integer } }
      expect(result[:n]).to eq(42)

      e = violations_for({ n: "abc" }) { permit_params(:create) { required :n, :integer } }
      expect(e.details).to eq([{ param: "n", code: "invalid_type" }])
      expect(violations_for({ n: "4.5" }) { permit_params(:create) { required :n, :integer } }.details.first[:code]).to eq("invalid_type")
    end

    it "accepts a whole Float for :integer but rejects a fractional one (JSON numbers)" do
      klass = permittable_class { permit_params(:create) { required :n, :integer } }
      expect(controller(klass, params: { n: 42.0 }).permitted_params[:n]).to eq(42)
      expect { controller(klass, params: { n: 42.5 }).permitted_params }
        .to raise_error(described_class::InvalidParameters)
    end

    it "rejects array/hash values where a scalar is expected (type confusion)" do
      e = violations_for({ n: ["1"] }) { permit_params(:create) { required :n, :integer } }
      expect(e.details).to eq([{ param: "n", code: "invalid_type" }])
      e = violations_for({ n: { x: "1" } }) { permit_params(:create) { required :n, :integer } }
      expect(e.details).to eq([{ param: "n", code: "invalid_type" }])
    end

    it "casts booleans from the strict truth set only" do
      klass = permittable_class { permit_params(:create) { required :flag, :boolean } }
      expect(controller(klass, params: { flag: "true" }).permitted_params[:flag]).to be(true)
      expect(controller(klass, params: { flag: "1" }).permitted_params[:flag]).to be(true)
      expect(controller(klass, params: { flag: "0" }).permitted_params[:flag]).to be(false)
      expect(controller(klass, params: { flag: false }).permitted_params[:flag]).to be(false)
      expect { controller(klass, params: { flag: "yes" }).permitted_params }
        .to raise_error(described_class::InvalidParameters)
    end

    it "casts float, decimal, date, and datetime" do
      result = permit({ f: "3.14", d: "19.99", day: "2026-08-15", at: "2026-08-15T10:00:00" }) do
        permit_params(:create) do
          required :f,   :float
          required :d,   :decimal
          required :day, :date
          required :at,  :datetime
        end
      end
      expect(result[:f]).to eq(3.14)
      expect(result[:d]).to eq(BigDecimal("19.99"))
      expect(result[:d]).to be_a(BigDecimal)
      expect(result[:day]).to eq(Date.new(2026, 8, 15))
      # Zoneless strings parse as UTC — deterministic across host timezones.
      expect(result[:at]).to eq(Time.utc(2026, 8, 15, 10))
    end

    it "rejects unparseable dates and datetimes" do
      expect(violations_for({ day: "not-a-day" }) { permit_params(:create) { required :day, :date } }.details.first[:code]).to eq("invalid_type")
      expect(violations_for({ at: "not-a-time" }) { permit_params(:create) { required :at, :datetime } }.details.first[:code]).to eq("invalid_type")
    end

    it "stringifies numbers and booleans for :string (JSON bodies)" do
      klass = permittable_class { permit_params(:create) { required :s } }
      expect(controller(klass, params: { s: 42 }).permitted_params[:s]).to eq("42")
      expect(controller(klass, params: { s: true }).permitted_params[:s]).to eq("true")
    end
  end

  describe "validations" do
    it "checks in: as Range (cover) and as Array (inclusion)" do
      decl = proc { permit_params(:create) { required :age, :integer, in: 18..120 } }
      expect(permit({ age: "30" }, &decl)[:age]).to eq(30)
      expect(violations_for({ age: "12" }, &decl).details).to eq([{ param: "age", code: "inclusion" }])

      e = violations_for({ plan: "gold" }) { permit_params(:create) { required :plan, :string, in: %w[free pro] } }
      expect(e.details.first[:code]).to eq("inclusion")
    end

    it "checks format on strings" do
      decl = proc { permit_params(:create) { required :zip, :string, format: /\A\d{5}\z/ } }
      expect(permit({ zip: "12345" }, &decl)[:zip]).to eq("12345")
      expect(violations_for({ zip: "12a45" }, &decl).details).to eq([{ param: "zip", code: "format" }])
    end

    it "checks length as a Range and as an exact Integer" do
      decl = proc { permit_params(:create) { required :name, :string, length: 1..3 } }
      expect(violations_for({ name: "toolong" }, &decl).details).to eq([{ param: "name", code: "length" }])

      exact = proc { permit_params(:create) { required :code, :string, length: 2 } }
      expect(permit({ code: "ab" }, &exact)[:code]).to eq("ab")
      expect(violations_for({ code: "abc" }, &exact).details.first[:code]).to eq("length")
    end

    it "normalizes before validating (presets and Procs)" do
      email = permit({ email: "  Jo@Example.COM " }) do
        permit_params(:create) { required :email, :string, normalize: :email, format: /\A\S+@\S+\z/ }
      end
      expect(email[:email]).to eq("jo@example.com")

      squished = permit({ name: "  a   b  " }) { permit_params(:create) { required :name, :string, normalize: :squish } }
      expect(squished[:name]).to eq("a b")

      custom = permit({ sku: "ab-1" }) { permit_params(:create) { required :sku, :string, normalize: ->(v) { v.upcase } } }
      expect(custom[:sku]).to eq("AB-1")
    end

    it "runs a custom validate: — falsy fails as 'invalid', a Symbol fails as that code, truthy passes" do
      falsy = proc { permit_params(:create) { required :n, :integer, validate: ->(v) { v.even? } } }
      expect(permit({ n: "4" }, &falsy)[:n]).to eq(4)
      expect(violations_for({ n: "3" }, &falsy).details).to eq([{ param: "n", code: "invalid" }])

      coded = proc { permit_params(:create) { required :n, :integer, validate: ->(v) { v.even? || :must_be_even } } }
      expect(violations_for({ n: "3" }, &coded).details).to eq([{ param: "n", code: "must_be_even" }])
    end
  end

  describe "absence, defaults, and required" do
    let(:decl) do
      proc do
        permit_params(:create) do
          required :name, :string
          optional :plan, :string, default: "free"
          optional :note, :string
        end
      end
    end

    it "applies defaults when the key is missing, nil, or empty" do
      expect(permit({ name: "a" }, &decl)[:plan]).to eq("free")
      expect(permit({ name: "a", plan: nil }, &decl)[:plan]).to eq("free")
      expect(permit({ name: "a", plan: "" }, &decl)[:plan]).to eq("free")
    end

    it "OMITS absent optional fields (partial updates never nil-out columns)" do
      result = permit({ name: "a" }, &decl)
      expect(result.key?("note")).to be(false)
      expect(result.to_h).to eq("name" => "a", "plan" => "free")
    end

    it "flags a missing / nil / empty required field" do
      expect(violations_for({}, &decl).details).to eq([{ param: "name", code: "missing" }])
      expect(violations_for({ name: "" }, &decl).details).to eq([{ param: "name", code: "missing" }])
    end

    it "treats boolean false as PRESENT" do
      result = permit({ ok: false }) { permit_params(:create) { required :ok, :boolean } }
      expect(result[:ok]).to be(false)
    end
  end

  describe "root:" do
    let(:decl) { proc { permit_params(:create, root: :user) { required :name, :string } } }

    it "unwraps the root key and prefixes violation paths with it" do
      expect(permit({ user: { name: "Jo" }, other: "ignored" }, &decl)[:name]).to eq("Jo")
      expect(violations_for({ user: {} }, &decl).details).to eq([{ param: "user.name", code: "missing" }])
    end

    it "raises with status :bad_request when the root key is missing or not a hash" do
      e = violations_for({}, &decl)
      expect(e.status).to eq(:bad_request)
      expect(e.details).to eq([{ param: "user", code: "missing" }])

      expect(violations_for({ user: "nope" }, &decl).status).to eq(:bad_request)
    end
  end

  describe "unknown:" do
    it "ignores undeclared keys by default" do
      result = permit({ name: "a", extra: "x" }) { permit_params(:create) { required :name, :string } }
      expect(result.to_h).to eq("name" => "a")
    end

    it "flags undeclared keys with unknown: :error, skipping routing keys at the top level" do
      e = violations_for({ name: "a", extra: "x", controller: "users", action: "create", format: "json" }) do
        permit_params(:create, unknown: :error) { required :name, :string }
      end
      expect(e.details).to eq([{ param: "extra", code: "unknown" }])
    end

    it "flags undeclared keys inside root and nested hashes (routing keys are only top-level)" do
      e = violations_for({ user: { name: "a", controller: "smuggled" } }) do
        permit_params(:create, root: :user, unknown: :error) { required :name, :string }
      end
      expect(e.details).to eq([{ param: "user.controller", code: "unknown" }])
    end

    it "logs undeclared keys with unknown: :log" do
      klass = permittable_class { permit_params(:create, unknown: :log) { required :name, :string } }
      c = controller(klass, params: { name: "a", extra: "x" })
      messages = []
      logger = Object.new
      logger.define_singleton_method(:warn) { |msg| messages << msg }
      c.define_singleton_method(:logger) { logger }

      expect(c.permitted_params.to_h).to eq("name" => "a")
      expect(messages.join).to match(/unknown parameter\(s\) ignored.*extra/)
    end
  end

  describe "nested hashes and arrays" do
    it "validates nested fields with dotted violation paths" do
      decl = proc do
        permit_params(:create, root: :user) do
          required :name, :string
          optional :address do
            required :city, :string
            optional :zip,  :string, format: /\A\d{5}\z/
          end
        end
      end
      result = permit({ user: { name: "Jo", address: { city: "Hanoi", zip: "10000" } } }, &decl)
      expect(result[:address].to_h).to eq("city" => "Hanoi", "zip" => "10000")

      e = violations_for({ user: { name: "Jo", address: { zip: "1" } } }, &decl)
      expect(e.details).to contain_exactly({ param: "user.address.city", code: "missing" },
                                           { param: "user.address.zip", code: "format" })
    end

    it "rejects a non-hash where a nested hash is declared" do
      e = violations_for({ address: "nope" }) { permit_params(:create) { optional(:address) { required :city } } }
      expect(e.details).to eq([{ param: "address", code: "invalid_type" }])
    end

    it "casts array elements and pinpoints the failing index" do
      decl = proc { permit_params(:create) { array :ids, of: :integer } }
      expect(permit({ ids: %w[1 2 3] }, &decl)[:ids]).to eq([1, 2, 3])
      expect(violations_for({ ids: %w[1 x 3] }, &decl).details).to eq([{ param: "ids[1]", code: "invalid_type" }])
    end

    it "validates arrays of hashes via a block" do
      decl = proc do
        permit_params(:create) do
          array :items do
            required :sku, :string
            optional :qty, :integer, default: 1
          end
        end
      end
      result = permit({ items: [{ sku: "a" }, { sku: "b", qty: "3" }] }, &decl)
      expect(result[:items].map(&:to_h)).to eq([{ "sku" => "a", "qty" => 1 }, { "sku" => "b", "qty" => 3 }])

      e = violations_for({ items: [{ sku: "a" }, "nope"] }, &decl)
      expect(e.details).to eq([{ param: "items[1]", code: "invalid_type" }])
    end

    it "checks array length (element count), requiredness, non-array values, and defaults" do
      expect(violations_for({ tags: %w[a b c] }) { permit_params(:create) { array :tags, length: 0..2 } }
        .details.first).to eq({ param: "tags", code: "length" })
      expect(violations_for({}) { permit_params(:create) { array :tags, required: true } }
        .details).to eq([{ param: "tags", code: "missing" }])
      expect(violations_for({ tags: "solo" }) { permit_params(:create) { array :tags } }
        .details).to eq([{ param: "tags", code: "invalid_type" }])
      expect(permit({}) { permit_params(:create) { array :tags, default: [] } }[:tags]).to eq([])
    end

    it "runs validate: on the whole cast array" do
      decl = proc { permit_params(:create) { array :ids, of: :integer, validate: ->(v) { v.uniq == v || :duplicates } } }
      expect(violations_for({ ids: %w[1 1] }, &decl).details).to eq([{ param: "ids", code: "duplicates" }])
    end
  end

  describe "rule matching and inheritance" do
    it "the LAST matching rule wins and no positional actions means catch-all" do
      klass = permittable_class do
        permit_params { required :anything, :string }
        permit_params(:create) { required :name, :string }
      end
      expect(controller(klass, params: { name: "a" }, action: "create").permitted_params[:name]).to eq("a")
      expect(controller(klass, params: { anything: "x" }, action: "destroy").permitted_params[:anything]).to eq("x")
    end

    it "subclasses inherit contracts copy-on-write and can override" do
      parent = permittable_class { permit_params(:create) { required :name, :string } }
      child = Class.new(parent) { permit_params(:create) { required :title, :string } }

      expect(controller(child, params: { title: "t" }).permitted_params[:title]).to eq("t")
      expect(controller(parent, params: { name: "n" }).permitted_params[:name]).to eq("n")
      expect(parent.permittable_contracts.length).to eq(1)
    end

    it "exposes the contract registry for introspection" do
      klass = permittable_class { permit_params(:create, root: :user) { required :name, :string, length: 1..80 } }
      rule = klass.permit_rule_for(:create)
      expect(rule[:root]).to eq(:user)
      expect(rule[:fields].first).to include(name: :name, kind: :scalar, type: :string, required: true, length: 1..80)
      expect(klass.permit_rule_for(:destroy)).to be_nil
    end

    it "raises ArgumentError (programmer error) when no contract covers the action" do
      klass = permittable_class { permit_params(:create) { required :name, :string } }
      expect { controller(klass, params: {}, action: "destroy").permitted_params }
        .to raise_error(ArgumentError, /no params contract declared covering #destroy/)
    end
  end

  describe "memoization and enforcement" do
    it "memoizes per action" do
      klass = permittable_class { permit_params(:create) { required :name, :string } }
      c = controller(klass, params: { name: "a" })
      expect(c.permitted_params).to equal(c.permitted_params)
    end

    it "enforce_params_contract validates only rules that opted in" do
      lazy = permittable_class { permit_params(:create) { required :name, :string } }
      expect { controller(lazy, params: {}).enforce_params_contract }.not_to raise_error

      eager = permittable_class { permit_params(:create, enforce: true) { required :name, :string } }
      expect { controller(eager, params: {}).enforce_params_contract }
        .to raise_error(described_class::InvalidParameters)
    end
  end

  describe "observability" do
    it "registers sensitive: fields (nested included) with the FilterParameterRegistry" do
      permittable_class do
        permit_params(:create) do
          required :name, :string
          optional :ssn,  :string, sensitive: true
          optional :bank do
            required :iban, :string, sensitive: true
          end
        end
      end
      expect(ConcernsOnRails.filter_parameter_registry.include?("ssn")).to be(true)
      expect(ConcernsOnRails.filter_parameter_registry.include?("iban")).to be(true)
      expect(ConcernsOnRails.filter_parameter_registry.include?("name")).to be(false)
    end

    it "instruments invalid_parameters.concerns_on_rails with the violation details" do
      events = []
      subscription = ActiveSupport::Notifications.subscribe("invalid_parameters.concerns_on_rails") do |*, payload|
        events << payload
      end
      begin
        violations_for({}) { permit_params(:create) { required :name, :string } }
      ensure
        ActiveSupport::Notifications.unsubscribe(subscription)
      end
      expect(events.length).to eq(1)
      expect(events.first[:action]).to eq("create")
      expect(events.first[:details]).to eq([{ param: "name", code: "missing" }])
    end

    it "renders the shared error envelope from render_invalid_parameters" do
      klass = permittable_class { permit_params(:create) { required :name, :string } }
      c = controller(klass, params: {})
      begin
        c.permitted_params
      rescue described_class::InvalidParameters => e
        c.render_invalid_parameters(e)
      end
      expect(c.rendered[:status]).to eq(:unprocessable_entity)
      expect(c.rendered[:json][:error][:code]).to eq("invalid_parameters")
      expect(c.rendered[:json][:error][:details]).to eq([{ param: "name", code: "missing" }])
    end
  end

  describe "schema-drift guard (model:)" do
    before do
      ActiveRecord::Schema.define do
        create_table :permit_users do |t|
          t.string :name
          t.integer :age
        end
      end
    end

    after do
      ActiveRecord::Base.connection.drop_table(:permit_users, if_exists: true)
    end

    let(:model) do
      Class.new(TestModel) do
        self.table_name = "permit_users"
      end
    end

    it "accepts a contract whose scalar fields are all columns" do
      m = model
      expect do
        permittable_class do
          permit_params(:create, model: m) do
            required :name, :string
            optional :age,  :integer
          end
        end
      end.not_to raise_error
    end

    it "raises at class load for a field whose column does not exist, teaching both fixes" do
      m = model
      expect do
        permittable_class { permit_params(:create, model: m) { required :nickname, :string } }
      end.to raise_error(ArgumentError) do |e|
        expect(e.message).to match(/'nickname' does not exist in the database \(table: permit_users\)/)
        expect(e.message).to match(%r{bin/rails generate migration AddNicknameToPermitUsers nickname:string})
        expect(e.message).to match(/declare it with virtual: true/)
      end
    end

    it "skips virtual fields and (implicitly) nested/array fields" do
      m = model
      expect do
        permittable_class do
          permit_params(:create, model: m) do
            required :name, :string
            optional :password, :string, virtual: true
            array    :tag_names, of: :string
            optional(:address) { required :city, :string }
          end
        end
      end.not_to raise_error
    end

    it "skips silently when the schema is unreachable (the ColumnGuard contract)" do
      unreachable = Class.new(TestModel) { self.table_name = "no_such_table" }
      expect do
        permittable_class { permit_params(:create, model: unreachable) { required :ghost, :string } }
      end.not_to raise_error
    end

    it "rejects a :model that is not a model class" do
      expect { permittable_class { permit_params(:create, model: "User") { required :name } } }
        .to raise_error(ArgumentError, /:model must be an ActiveRecord model class/)
    end

    it "model: true infers the class from controller_name, and raises without one" do
      stub_const("PermitUser", model)
      inferring = Class.new(FakeController) do
        def self.controller_name
          "permit_users"
        end
        include ConcernsOnRails::Controllers::Permittable
      end
      expect { inferring.class_eval { permit_params(:create, model: true) { required :name, :string } } }
        .not_to raise_error
      expect(inferring.permit_rule_for(:create)[:model]).to eq(PermitUser)

      expect { permittable_class { permit_params(:create, model: true) { required :name } } }
        .to raise_error(ArgumentError, /model: true needs controller_name/)
    end
  end

  describe "through the real ActionController stack", :integration do
    def build_api_controller(&extra)
      IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Permittable

        permit_params :create, root: :user do
          required :name, :string, length: 1..80
          optional :age,  :integer, in: 18..120
          optional :plan, :string, default: "free"
        end

        def create
          render json: { received: permitted_params }
        end

        class_eval(&extra) if extra
      end
    end

    it "casts and defaults real form-encoded ActionController::Parameters" do
      result = IntegrationHarness.dispatch(build_api_controller, :create,
                                           method: "POST", params: { user: { name: "Jo", age: "30" } })
      expect(result.status).to eq(200)
      body = JSON.parse(result.body)
      expect(body["received"]).to eq("name" => "Jo", "age" => 30, "plan" => "free")
    end

    it "rescues InvalidParameters into the 422 envelope with machine-readable details" do
      result = IntegrationHarness.dispatch(build_api_controller, :create,
                                           method: "POST", params: { user: { name: "Jo", age: "12" } })
      expect(result.status).to eq(422)
      body = JSON.parse(result.body)
      expect(body["success"]).to be(false)
      expect(body["error"]["code"]).to eq("invalid_parameters")
      expect(body["error"]["details"]).to eq([{ "param" => "user.age", "code" => "inclusion" }])
    end

    it "renders 400 when the root key is missing" do
      result = IntegrationHarness.dispatch(build_api_controller, :create,
                                           method: "POST", params: { name: "rootless" })
      expect(result.status).to eq(400)
      expect(JSON.parse(result.body)["error"]["details"]).to eq([{ "param" => "user", "code" => "missing" }])
    end

    it "enforce: true rejects before the action body runs" do
      controller = IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Permittable

        permit_params :create, root: :user, enforce: true do
          required :name, :string
        end

        def create
          raise "action body must not run"
        end
      end
      result = IntegrationHarness.dispatch(controller, :create, method: "POST", params: {})
      expect(result.status).to eq(400)
    end

    it "unknown: :error does not flag Rails' routing keys on top-level contracts" do
      controller = IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Permittable

        permit_params :index, unknown: :error do
          optional :page, :integer, default: 1
        end

        def index
          render json: permitted_params
        end
      end
      result = IntegrationHarness.dispatch(controller, :index, query: "page=2")
      expect(result.status).to eq(200)
      expect(JSON.parse(result.body)).to eq("page" => 2)

      result = IntegrationHarness.dispatch(controller, :index, query: "page=2&rogue=1")
      expect(result.status).to eq(422)
      expect(JSON.parse(result.body)["error"]["details"]).to eq([{ "param" => "rogue", "code" => "unknown" }])
    end
  end
end
