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
  describe "RFC 9457 problem details (respondable_by error_format: :problem_details)" do
    let(:problem_class) do
      Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Respondable

        respondable_by error_format: :problem_details, problem_type_base: "https://api.example.com/problems/"
      end
    end

    it "renders application/problem+json with type, title, status, detail and the code/errors extensions" do
      c = problem_class.new
      c.render_error(message: "Validation failed", status: :unprocessable_entity, code: "record_invalid",
                     errors: ["Name can't be blank"])
      expect(c.rendered[:content_type]).to eq("application/problem+json")
      expect(c.rendered[:status]).to eq(:unprocessable_entity)
      expect(c.rendered[:json]).to eq(
        type: "https://api.example.com/problems/record_invalid",
        title: Rack::Utils::HTTP_STATUS_CODES[422],
        status: 422,
        detail: "Validation failed",
        code: "record_invalid",
        errors: ["Name can't be blank"]
      )
    end

    it "maps the renamed Rack status symbols without warning" do
      # Rack 3.1 renamed 422 to :unprocessable_content and warns on every
      # Rack::Utils.status_code call for the old name. 422 is render_error's
      # default and the status of several ErrorHandleable handlers, so falling
      # through would log a deprecation line on every validation failure.
      c = problem_class.new
      output = Kernel.instance_method(:warn)
      captured = []
      Kernel.send(:define_method, :warn) { |*args| captured.concat(args) }
      begin
        c.render_error(message: "nope", status: :unprocessable_entity, code: "record_invalid")
      ensure
        Kernel.send(:define_method, :warn, output)
      end

      expect(c.rendered[:json][:status]).to eq(422)
      expect(captured.join).not_to include("deprecated")
    end

    it "uses about:blank as the type without a code, and without a type base; omits absent members" do
      c = problem_class.new
      c.render_error(message: "Not here", status: :not_found)
      expect(c.rendered[:json]).to eq(type: "about:blank", title: "Not Found", status: 404, detail: "Not here")

      no_base = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Respondable

        respondable_by error_format: :problem_details
      end.new
      no_base.render_error(message: "Nope", status: 403, code: "forbidden")
      expect(no_base.rendered[:json]).to eq(type: "about:blank", title: "Forbidden", status: 403, detail: "Nope", code: "forbidden")
    end

    it "joins the type base and code with exactly one slash" do
      klass = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Respondable

        respondable_by error_format: :problem_details, problem_type_base: "https://api.example.com/problems"
      end
      c = klass.new
      c.render_error(message: "x", code: "rate_limited", status: 429)
      expect(c.rendered[:json][:type]).to eq("https://api.example.com/problems/rate_limited")
    end

    it "adds instance (the request path) when a request is available" do
      c = problem_class.new
      request = Struct.new(:path).new("/api/articles/7")
      c.define_singleton_method(:request) { request }
      c.render_error(message: "Not here", status: :not_found)
      expect(c.rendered[:json][:instance]).to eq("/api/articles/7")
    end

    it "leaves render_success untouched" do
      c = problem_class.new
      c.render_success(data: { id: 1 })
      expect(c.rendered).to eq(json: { success: true, data: { id: 1 } }, status: :ok)
    end

    it "keeps the classic envelope by default and rejects an unknown format" do
      expect(controller_class.respondable_error_format).to eq(:envelope)
      expect do
        Class.new(FakeController) do
          include ConcernsOnRails::Controllers::Respondable

          respondable_by error_format: :xml
        end
      end.to raise_error(ArgumentError, /error_format must be one of :envelope, :problem_details/)
    end

    it "switches every concern that funnels through render_error — ErrorHandleable's 404 becomes a problem document" do
      require "active_support/rescuable"
      klass = Class.new(FakeController) do
        include ActiveSupport::Rescuable
        include ConcernsOnRails::Controllers::Respondable
        include ConcernsOnRails::Controllers::ErrorHandleable

        respondable_by error_format: :problem_details, problem_type_base: "https://api.example.com/problems"
      end
      c = klass.new
      c.rescue_with_handler(ActiveRecord::RecordNotFound.new("missing"))
      expect(c.rendered[:content_type]).to eq("application/problem+json")
      expect(c.rendered[:json]).to include(type: "https://api.example.com/problems/not_found", status: 404, detail: "Resource not found")
    end

    it "sets the real Content-Type through the ActionController stack" do
      require "support/integration_harness"
      real = IntegrationHarness.build_controller do
        include ConcernsOnRails::Controllers::Respondable

        respondable_by error_format: :problem_details

        define_method(:show) { render_error(message: "Gone fishing", status: :gone, code: "gone") }
      end
      result = IntegrationHarness.dispatch(real, :show)
      expect(result.status).to eq(410)
      expect(result.header("Content-Type")).to start_with("application/problem+json")
      expect(JSON.parse(result.body)).to include("type" => "about:blank", "status" => 410, "detail" => "Gone fishing", "code" => "gone")
    end
  end

  describe "location:/headers:, #render_created and #render_invalid" do
    unless defined?(RespondableInvalidModel)
      RespondableInvalidModel = Struct.new(:name) do
        include ActiveModel::Validations

        validates :name, presence: true
      end
    end

    it "render_success sets Location and extra response headers" do
      controller.render_success(data: { id: 7 }, status: :created, location: "/articles/7",
                                headers: { "X-Request-Id" => "abc" })
      expect(controller.rendered).to eq(json: { success: true, data: { id: 7 } }, status: :created)
      expect(controller.response.headers).to include("Location" => "/articles/7", "X-Request-Id" => "abc")

      plain = controller_class.new
      plain.render_success(data: 1)
      expect(plain.response.headers).not_to have_key("Location")
    end

    it "resolves a non-String location through url_for when the controller has it" do
      controller.define_singleton_method(:url_for) { |target| "/resolved/#{target[:id]}" }
      controller.render_success(data: nil, location: { id: 9 })
      expect(controller.response.headers["Location"]).to eq("/resolved/9")
    end

    it "render_created is a 201 with an optional Location" do
      controller.render_created(data: { id: 3 }, location: "/articles/3", meta: { version: 2 })
      expect(controller.rendered).to eq(json: { success: true, data: { id: 3 }, meta: { version: 2 } }, status: :created)
      expect(controller.response.headers["Location"]).to eq("/articles/3")
    end

    it "render_invalid renders the record's errors as a 422 record_invalid envelope" do
      record = RespondableInvalidModel.new(nil)
      record.valid?
      controller.render_invalid(record)
      expect(controller.rendered).to eq(
        json: { success: false, error: { message: "Validation failed", code: "record_invalid", details: ["Name can't be blank"] } },
        status: :unprocessable_entity
      )

      custom = controller_class.new
      custom.render_invalid(record, message: "Bad article", status: :bad_request, code: "bad_article")
      expect(custom.rendered[:json][:error]).to include(message: "Bad article", code: "bad_article")
      expect(custom.rendered[:status]).to eq(:bad_request)
    end

    it "render_invalid accepts an errors object, omits empty details and rejects other things" do
      record = RespondableInvalidModel.new(nil)
      record.valid?
      via_errors = controller_class.new
      via_errors.render_invalid(record.errors)
      expect(via_errors.rendered[:json][:error][:details]).to eq(["Name can't be blank"])

      clean = controller_class.new
      clean.render_invalid(RespondableInvalidModel.new("ok"))
      expect(clean.rendered[:json][:error]).not_to have_key(:details)

      expect { controller.render_invalid("nope") }
        .to raise_error(ArgumentError, /render_invalid expects a record \(responding to #errors\) or an ActiveModel::Errors/)
    end

    it "render_invalid follows the problem-details format when configured" do
      klass = Class.new(FakeController) do
        include ConcernsOnRails::Controllers::Respondable

        respondable_by error_format: :problem_details, problem_type_base: "https://api.example.com/problems"
      end
      record = RespondableInvalidModel.new(nil)
      record.valid?
      c = klass.new
      c.render_invalid(record)
      expect(c.rendered[:json]).to include(type: "https://api.example.com/problems/record_invalid", status: 422,
                                           detail: "Validation failed", errors: ["Name can't be blank"])
    end
  end
end
