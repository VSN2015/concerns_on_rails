require "spec_helper"
require "active_support/rescuable"
require "action_controller/metal/strong_parameters"

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
        error: { message: "Couldn't find User with 'id'=99", code: "not_found" }
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
        error: { message: "missing", code: "not_found" }
      )
      expect(instance.rendered[:status]).to eq(:not_found)
    end
  end
end
