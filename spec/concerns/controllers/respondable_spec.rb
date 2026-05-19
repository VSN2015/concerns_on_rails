require "spec_helper"

describe ConcernsOnRails::Controllers::Respondable do
  let(:controller_class) do
    Class.new(FakeController) do
      include ConcernsOnRails::Controllers::Respondable
    end
  end

  let(:controller) { controller_class.new }

  describe "#render_success" do
    it "wraps data in a success envelope with default :ok status" do
      controller.render_success(data: { id: 1, title: "Hello" })
      expect(controller.rendered).to eq(
        json: { success: true, data: { id: 1, title: "Hello" } },
        status: :ok
      )
    end

    it "honors a custom status" do
      controller.render_success(data: { id: 1 }, status: :created)
      expect(controller.rendered[:status]).to eq(:created)
    end

    it "includes :meta when non-empty" do
      controller.render_success(data: [1, 2, 3], meta: { total: 3 })
      expect(controller.rendered[:json]).to eq(success: true, data: [1, 2, 3], meta: { total: 3 })
    end

    it "omits :meta from the body when empty (default)" do
      controller.render_success(data: [1, 2, 3])
      expect(controller.rendered[:json]).not_to have_key(:meta)
    end

    it "supports nil data" do
      controller.render_success
      expect(controller.rendered[:json]).to eq(success: true, data: nil)
    end
  end

  describe "#render_error" do
    it "wraps the message in an error envelope with default :unprocessable_entity status" do
      controller.render_error(message: "Bad request")
      expect(controller.rendered).to eq(
        json: { success: false, error: { message: "Bad request" } },
        status: :unprocessable_entity
      )
    end

    it "includes :code when provided" do
      controller.render_error(message: "Forbidden", status: :forbidden, code: "PERMISSION_DENIED")
      expect(controller.rendered[:json][:error]).to include(code: "PERMISSION_DENIED")
      expect(controller.rendered[:status]).to eq(:forbidden)
    end

    it "includes :details when errors are provided" do
      controller.render_error(message: "Invalid", errors: ["email is required", "name is too short"])
      expect(controller.rendered[:json][:error][:details]).to eq(["email is required", "name is too short"])
    end

    it "omits :code and :details when not provided" do
      controller.render_error(message: "Boom")
      expect(controller.rendered[:json][:error]).to eq(message: "Boom")
    end
  end
end
