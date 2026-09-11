require "spec_helper"
require "active_support/rescuable"
require "action_controller"
require "action_controller/metal/request_forgery_protection" # defines InvalidAuthenticityToken
require "support/integration_harness"

describe ConcernsOnRails::Controllers::ErrorHandleable do
  # The real ActionController already pulls in ActiveSupport::Rescuable, but
  # our FakeController is intentionally bare. Mixing in Rescuable here gives
  # us `rescue_from` + `rescue_with_handler` so we can exercise the dispatch.
  let(:rescuable_base) do
    Class.new(FakeController) { include ActiveSupport::Rescuable }
  end

  let(:controller_class) do
    rescuable = rescuable_base
    Class.new(rescuable) { include ConcernsOnRails::Controllers::ErrorHandleable }
  end

  let(:controller) { controller_class.new }

  describe "handler registration" do
    it "registers rescue_from for the three handled exceptions" do
      exceptions = controller_class.rescue_handlers.map(&:first)
      expect(exceptions).to include(
        "ActiveRecord::RecordNotFound",
        "ActionController::ParameterMissing",
        "ActiveRecord::RecordInvalid"
      )
    end
  end

  describe "#handle_record_not_found" do
    it "renders a 404 error envelope" do
      error = ActiveRecord::RecordNotFound.new("Couldn't find User with 'id'=99")
      controller.handle_record_not_found(error)

      expect(controller.rendered[:status]).to eq(:not_found)
      expect(controller.rendered[:json]).to eq(
        success: false,
        error: { message: "Resource not found", code: "not_found" }
      )
    end

    it "dispatches via rescue_from when the exception is raised" do
      error = ActiveRecord::RecordNotFound.new("nope")
      expect(controller.rescue_with_handler(error)).to be_truthy
      expect(controller.rendered[:status]).to eq(:not_found)
    end
  end

  describe "#handle_parameter_missing" do
    it "renders a 400 envelope naming the missing param" do
      error = ActionController::ParameterMissing.new(:user)
      controller.handle_parameter_missing(error)

      expect(controller.rendered[:status]).to eq(:bad_request)
      expect(controller.rendered[:json][:error]).to include(
        message: "Parameter missing: user",
        code: "parameter_missing"
      )
    end

    it "dispatches via rescue_from when the exception is raised" do
      error = ActionController::ParameterMissing.new(:user)
      expect(controller.rescue_with_handler(error)).to be_truthy
      expect(controller.rendered[:status]).to eq(:bad_request)
    end
  end

  describe "#handle_record_invalid" do
    before do
      ActiveRecord::Schema.define do
        create_table :items, force: true do |t|
          t.string :name
        end
      end

      class Item < TestModel
        validates :name, presence: true
      end
    end

    after(:each) do
      ActiveRecord::Base.connection.tables.each do |table|
        next if table == "schema_migrations"

        ActiveRecord::Base.connection.drop_table(table)
      end
    end

    it "renders a 422 envelope with the record's full error messages" do
      record = Item.new
      record.valid?
      error = ActiveRecord::RecordInvalid.new(record)

      controller.handle_record_invalid(error)

      expect(controller.rendered[:status]).to eq(:unprocessable_entity)
      expect(controller.rendered[:json][:error][:code]).to eq("record_invalid")
      expect(controller.rendered[:json][:error][:details]).to include("Name can't be blank")
    end

    it "dispatches via rescue_from when the exception is raised" do
      record = Item.new
      record.valid?
      error = ActiveRecord::RecordInvalid.new(record)

      expect(controller.rescue_with_handler(error)).to be_truthy
      expect(controller.rendered[:status]).to eq(:unprocessable_entity)
    end
  end

  describe "subclass overrides" do
    it "lets a subclass replace a handler without re-declaring rescue_from" do
      base = controller_class
      custom_class = Class.new(base) do
        def handle_record_not_found(_error)
          render json: { success: false, error: { message: "custom 404" } }, status: :not_found
        end
      end

      custom = custom_class.new
      custom.rescue_with_handler(ActiveRecord::RecordNotFound.new("anything"))
      expect(custom.rendered[:json][:error][:message]).to eq("custom 404")
    end
  end

  describe "delegation to Respondable" do
    it "delegates to render_error when Respondable is also included" do
      rescuable = rescuable_base
      combined_class = Class.new(rescuable) do
        include ConcernsOnRails::Controllers::Respondable
        include ConcernsOnRails::Controllers::ErrorHandleable
      end

      instance = combined_class.new
      instance.handle_record_not_found(ActiveRecord::RecordNotFound.new("missing"))

      # Same envelope shape — Respondable's render_error is in charge.
      expect(instance.rendered[:json]).to eq(
        success: false,
        error: { message: "Resource not found", code: "not_found" }
      )
      expect(instance.rendered[:status]).to eq(:not_found)
    end
  end
  describe "expanded exception map" do
    before do
      ActiveRecord::Schema.define do
        create_table :error_items, force: true do |t|
          t.string :name
          t.integer :lock_version, default: 0, null: false
        end
      end

      class ErrorItem < TestModel
        validates :name, presence: true
      end
    end

    after(:each) do
      ActiveRecord::Base.connection.tables.each do |table|
        next if table == "schema_migrations"

        ActiveRecord::Base.connection.drop_table(table)
      end
      Object.send(:remove_const, :ErrorItem) if Object.const_defined?(:ErrorItem)
    end

    let(:invalid_item) { ErrorItem.new.tap(&:valid?) }

    def rescue!(error)
      expect(controller.rescue_with_handler(error)).to be_truthy
      controller.rendered
    end

    it "registers every HANDLERS entry by default and exposes the active keys" do
      registered = controller_class.rescue_handlers
      described_class::HANDLERS.each_value do |spec|
        expect(registered).to include([spec[:exception], spec[:handler]])
      end
      expect(controller_class.error_handleable_keys).to eq(described_class::HANDLERS.keys)
    end

    # One representative exception per key; every handler must render code ==
    # key and the status the HANDLERS table advertises, and be public.
    it "renders code == key and the table's status for every handler" do
      samples = {
        not_found: -> { ActiveRecord::RecordNotFound.new("x") },
        parameter_missing: -> { ActionController::ParameterMissing.new(:user) },
        record_invalid: -> { ActiveRecord::RecordInvalid.new(invalid_item) },
        validation_error: -> { ActiveModel::ValidationError.new(invalid_item) },
        record_not_saved: -> { ActiveRecord::RecordNotSaved.new("x", invalid_item) },
        record_not_destroyed: -> { ActiveRecord::RecordNotDestroyed.new("x", invalid_item) },
        stale_object: -> { ActiveRecord::StaleObjectError.new(invalid_item, "update") },
        record_not_unique: -> { ActiveRecord::RecordNotUnique.new("x") },
        foreign_key_violation: -> { ActiveRecord::InvalidForeignKey.new("x") },
        unpermitted_parameters: -> { ActionController::UnpermittedParameters.new(%w[a]) },
        invalid_authenticity_token: -> { ActionController::InvalidAuthenticityToken.new },
        bad_request: -> { ActionController::BadRequest.new("x") },
        parse_error: -> { ActionDispatch::Http::Parameters::ParseError.new("x") },
        unknown_format: -> { ActionController::UnknownFormat.new }
      }
      expect(samples.keys).to match_array(described_class::HANDLERS.keys)

      samples.each do |key, build|
        spec = described_class::HANDLERS.fetch(key)
        expect(controller_class.public_method_defined?(spec[:handler])).to be(true), "#{spec[:handler]} must be public"
        fresh = controller_class.new
        expect(fresh.rescue_with_handler(build.call)).to be_truthy, "no handler dispatched for #{key}"
        expect(fresh.rendered[:status]).to eq(spec[:status]), "#{key}: status"
        expect(fresh.rendered[:json][:error][:code]).to eq(key.to_s), "#{key}: code"
      end
    end

    it "ActiveModel::ValidationError → 422 validation_error with the model's messages" do
      form_class = Class.new do
        include ActiveModel::Model

        attr_accessor :email

        validates :email, presence: true

        def self.name
          "SignupForm"
        end
      end
      form = form_class.new.tap(&:valid?)
      rendered = rescue!(ActiveModel::ValidationError.new(form))
      expect(rendered[:status]).to eq(:unprocessable_entity)
      expect(rendered[:json][:error]).to include(code: "validation_error", details: ["Email can't be blank"])
      expect(rendered[:json][:error][:message]).to include("Email can't be blank")
    end

    it "ActiveRecord::RecordNotSaved → 422 record_not_saved, details only when the record has errors" do
      rendered = rescue!(ActiveRecord::RecordNotSaved.new("Failed to save the record", invalid_item))
      expect(rendered[:status]).to eq(:unprocessable_entity)
      expect(rendered[:json][:error]).to eq(
        message: "Failed to save the record", code: "record_not_saved", details: ["Name can't be blank"]
      )

      clean = ErrorItem.new(name: "ok")
      rendered = rescue!(ActiveRecord::RecordNotSaved.new("Failed to save the record", clean))
      expect(rendered[:json][:error]).to eq(message: "Failed to save the record", code: "record_not_saved")
    end

    it "ActiveRecord::RecordNotDestroyed → 422 record_not_destroyed" do
      item = ErrorItem.create!(name: "keep")
      item.errors.add(:base, "Cannot delete an item with open orders")
      rendered = rescue!(ActiveRecord::RecordNotDestroyed.new("Failed to destroy the record", item))
      expect(rendered[:status]).to eq(:unprocessable_entity)
      expect(rendered[:json][:error]).to include(
        code: "record_not_destroyed", details: ["Cannot delete an item with open orders"]
      )
    end

    it "ActiveRecord::StaleObjectError → 409 stale_object with a generic message (no class name leak)" do
      item = ErrorItem.create!(name: "v1")
      rendered = rescue!(ActiveRecord::StaleObjectError.new(item, "update"))
      expect(rendered[:status]).to eq(:conflict)
      expect(rendered[:json][:error][:code]).to eq("stale_object")
      expect(rendered[:json][:error][:message]).not_to include("ErrorItem")
      expect(rendered[:json][:error]).not_to have_key(:details)
    end

    it "ActiveRecord::RecordNotUnique → 409 record_not_unique without the SQL" do
      error = ActiveRecord::RecordNotUnique.new("SQLite3::ConstraintException: UNIQUE constraint failed: error_items.name")
      rendered = rescue!(error)
      expect(rendered[:status]).to eq(:conflict)
      expect(rendered[:json][:error]).to eq(message: "Resource already exists", code: "record_not_unique")
    end

    it "ActiveRecord::InvalidForeignKey → 409 foreign_key_violation without the SQL" do
      error = ActiveRecord::InvalidForeignKey.new("PG::ForeignKeyViolation: update or delete on table \"authors\" violates ...")
      rendered = rescue!(error)
      expect(rendered[:status]).to eq(:conflict)
      expect(rendered[:json][:error]).to eq(message: "Resource is referenced by other records", code: "foreign_key_violation")
    end

    it "ActionController::UnpermittedParameters → 400 unpermitted_parameters listing the params" do
      rendered = rescue!(ActionController::UnpermittedParameters.new(%w[admin role]))
      expect(rendered[:status]).to eq(:bad_request)
      expect(rendered[:json][:error]).to eq(
        message: "Unpermitted parameters: admin, role", code: "unpermitted_parameters", details: %w[admin role]
      )
    end

    it "ActionController::InvalidAuthenticityToken → 422 invalid_authenticity_token" do
      rendered = rescue!(ActionController::InvalidAuthenticityToken.new)
      expect(rendered[:status]).to eq(:unprocessable_entity)
      expect(rendered[:json][:error]).to eq(message: "Invalid authenticity token", code: "invalid_authenticity_token")
    end

    it "ActionController::BadRequest → 400 bad_request without echoing the offending input" do
      rendered = rescue!(ActionController::BadRequest.new("Invalid query parameters: invalid %-encoding (%zz<script>)"))
      expect(rendered[:status]).to eq(:bad_request)
      expect(rendered[:json][:error]).to eq(message: "Bad request", code: "bad_request")
    end

    it "ActionDispatch::Http::Parameters::ParseError → 400 parse_error without the parser message" do
      rendered = rescue!(ActionDispatch::Http::Parameters::ParseError.new("unexpected token at '{\"a\":'"))
      expect(rendered[:status]).to eq(:bad_request)
      expect(rendered[:json][:error]).to eq(message: "Malformed request body", code: "parse_error")
    end

    it "ActionController::UnknownFormat → 406 unknown_format" do
      rendered = rescue!(ActionController::UnknownFormat.new)
      expect(rendered[:status]).to eq(:not_acceptable)
      expect(rendered[:json][:error]).to eq(message: "Requested format is not supported", code: "unknown_format")
    end

    it "dispatches through the real ActionController stack (rescue_from + JSON body)" do
      real = IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::ErrorHandleable

        def show
          raise ActiveRecord::StaleObjectError.new(nil, "update")
        end
      end
      result = IntegrationHarness.dispatch(real, :show)
      expect(result.status).to eq(409)
      body = JSON.parse(result.body)
      expect(body).to eq("success" => false, "error" => { "message" => body.dig("error", "message"), "code" => "stale_object" })
    end
  end

  describe ".handle_errors" do
    it "except: drops the named keys and nothing else" do
      klass = Class.new(controller_class) { handle_errors except: :stale_object }
      expect(klass.error_handleable_keys).to eq(described_class::HANDLERS.keys - [:stale_object])
      expect(klass.rescue_handlers.map(&:first)).not_to include("ActiveRecord::StaleObjectError")
      expect(klass.rescue_handlers.map(&:first)).to include("ActiveRecord::RecordNotFound", "ActiveRecord::RecordNotUnique")
      expect(klass.new.rescue_with_handler(ActiveRecord::StaleObjectError.new(nil, "update"))).to be_nil
    end

    it "only: keeps just the named keys (the pre-expansion trio, say)" do
      klass = Class.new(controller_class) { handle_errors only: %i[not_found parameter_missing record_invalid] }
      expect(klass.error_handleable_keys).to eq(%i[not_found parameter_missing record_invalid])
      registered = klass.rescue_handlers.map(&:first)
      expect(registered).to include("ActiveRecord::RecordNotFound", "ActionController::ParameterMissing", "ActiveRecord::RecordInvalid")
      expect(registered).not_to include("ActiveRecord::RecordNotUnique", "ActionController::UnknownFormat")
    end

    it "is cumulative and accepts a single symbol or a list" do
      klass = Class.new(controller_class) do
        handle_errors except: :stale_object
        handle_errors except: %i[record_not_unique foreign_key_violation]
      end
      expect(klass.error_handleable_keys).to eq(
        described_class::HANDLERS.keys - %i[stale_object record_not_unique foreign_key_violation]
      )
    end

    it "leaves a rescue_from the host declared for the same exception untouched" do
      klass = Class.new(controller_class) do
        rescue_from "ActiveRecord::StaleObjectError", with: :my_stale_handler
        handle_errors except: :stale_object

        def my_stale_handler(_error)
          render json: { mine: true }, status: :conflict
        end
      end
      expect(klass.rescue_handlers).to include(["ActiveRecord::StaleObjectError", :my_stale_handler])
      expect(klass.rescue_handlers).not_to include(["ActiveRecord::StaleObjectError", :handle_stale_object])
      instance = klass.new
      instance.rescue_with_handler(ActiveRecord::StaleObjectError.new(nil, "update"))
      expect(instance.rendered[:json]).to eq(mine: true)
    end

    it "does not touch the parent class's registrations" do
      Class.new(controller_class) { handle_errors except: :not_found }
      expect(controller_class.error_handleable_keys).to include(:not_found)
      expect(controller_class.rescue_handlers.map(&:first)).to include("ActiveRecord::RecordNotFound")
    end

    it "rejects unknown keys with the list of valid ones" do
      expect { Class.new(controller_class) { handle_errors except: :nope } }
        .to raise_error(ArgumentError, /unknown handler key.*:nope.*valid keys:.*:not_found/)
    end

    it "rejects only: and except: together" do
      expect { Class.new(controller_class) { handle_errors only: :not_found, except: :stale_object } }
        .to raise_error(ArgumentError, /not both/)
    end
  end

  describe "instrumentation (#on_handled_error)" do
    def handled_events(&block)
      events = []
      callback = ->(*args) { events << ActiveSupport::Notifications::Event.new(*args) }
      ActiveSupport::Notifications.subscribed(callback, "handled_error.concerns_on_rails", &block)
      events
    end

    it "instruments every rescued error with code, status, message, exception and action" do
      controller.define_singleton_method(:action_name) { "show" }
      error = ActiveRecord::RecordNotFound.new("Couldn't find User with 'id'=99")
      events = handled_events { controller.rescue_with_handler(error) }

      expect(events.size).to eq(1)
      payload = events.first.payload
      expect(payload).to include(code: :not_found, status: :not_found, action: "show",
                                 exception: error, exception_class: "ActiveRecord::RecordNotFound")
      expect(payload[:message]).to eq(controller.rendered[:json][:error][:message])
      expect(payload).to have_key(:controller)
    end

    it "is an override point — replace it to report only some codes; skipping super silences the event" do
      klass = Class.new(controller_class) do
        def self.reports = (@reports ||= [])

        def on_handled_error(key, error, **)
          self.class.reports << [key, error.class.name] if key == :record_not_unique
        end
      end
      c = klass.new
      events = handled_events do
        c.rescue_with_handler(ActiveRecord::RecordNotUnique.new("dup"))
        c.rescue_with_handler(ActiveRecord::RecordNotFound.new("gone"))
      end
      expect(klass.reports).to eq([[:record_not_unique, "ActiveRecord::RecordNotUnique"]])
      expect(events).to be_empty
      expect(c.rendered[:status]).to eq(:not_found) # rendering is untouched
    end

    it "instruments a handler called directly too, with a nil exception" do
      events = handled_events { controller.handle_stale_object(ActiveRecord::StaleObjectError.new) }
      expect(events.first.payload).to include(code: :stale_object, status: :conflict, exception: nil, exception_class: nil)
    end

    it "fires through the real ActionController stack with the controller path" do
      klass = IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::ErrorHandleable

        define_method(:index) { raise ActiveRecord::RecordNotUnique, "dup" }
      end
      events = handled_events { IntegrationHarness.dispatch(klass, :index) }
      expect(events.size).to eq(1)
      expect(events.first.payload).to include(code: :record_not_unique, status: :conflict, action: "index")
      expect(events.first.payload[:controller]).to eq(klass.controller_path)
    end
  end
end
