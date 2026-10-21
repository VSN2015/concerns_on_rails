require "spec_helper"
require "support/integration_harness"
require "json"

# Audit 2026-10-09, HTTP-4. ActionController::Instrumentation#process_action
# reads request.filtered_parameters BEFORE ActionController::Rescue#process_action
# (the frame that applies rescue_from) runs, and filtered_parameters rescues only
# ParseError -- so the ActionController::BadRequest a malformed query string
# raises escaped past rescue_from. The documented :bad_request handler never ran
# and the client got Rails' default HTML 400 page instead of the JSON envelope.
describe "ErrorHandleable :bad_request for a malformed query string" do
  # Rack::MockRequest.env_for refuses to build a URI from an invalid %-escape,
  # which is exactly the input under test, so set QUERY_STRING directly.
  def dispatch_raw_query(klass, query, action: :index, headers: {})
    env = Rack::MockRequest.env_for("/")
    env["QUERY_STRING"] = query
    headers.each { |name, value| env["HTTP_#{name.to_s.tr('-', '_').upcase}"] = value }
    status, response_headers, body = klass.action(action).call(env)
    chunks = body.enum_for(:each).to_a
    body.close if body.respond_to?(:close)
    IntegrationHarness::Result.new(status, response_headers, chunks.join)
  end

  def build(&block)
    IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::ErrorHandleable

      define_method(:index) { render json: { q: params[:q] } }
      class_eval(&block) if block
    end
  end

  it "renders the 400 bad_request envelope for invalid UTF-8 in the query string" do
    result = nil
    expect { result = dispatch_raw_query(build, "q=%FF") }.not_to raise_error

    expect(result.status).to eq(400)
    expect(JSON.parse(result.body)).to eq("success" => false, "error" => { "message" => "Bad request", "code" => "bad_request" })
  end

  it "renders the 400 bad_request envelope for an invalid %-escape" do
    result = nil
    expect { result = dispatch_raw_query(build, "q=%ZZ") }.not_to raise_error

    expect(result.status).to eq(400)
    expect(JSON.parse(result.body).dig("error", "code")).to eq("bad_request")
  end

  it "still serves a well-formed query string" do
    result = dispatch_raw_query(build, "q=hello")

    expect(result.status).to eq(200)
    expect(JSON.parse(result.body)).to eq("q" => "hello")
  end

  it "instruments handled_error.concerns_on_rails with the BadRequest" do
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("handled_error.concerns_on_rails") { |*, payload| events << payload }

    dispatch_raw_query(build, "q=%FF")

    expect(events.size).to eq(1)
    expect(events.first).to include(code: :bad_request, status: :bad_request, exception_class: "ActionController::BadRequest")
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it "renders a problem document under Respondable's :problem_details" do
    klass = build do
      include ConcernsOnRails::Controllers::Respondable

      respondable_by error_format: :problem_details
    end

    result = dispatch_raw_query(klass, "q=%FF")

    expect(result.status).to eq(400)
    expect(result.header("Content-Type")).to eq("application/problem+json")
    expect(JSON.parse(result.body)).to include("status" => 400, "code" => "bad_request", "detail" => "Bad request")
  end

  it "keeps the handle_errors except: :bad_request opt-out propagating the exception" do
    klass = build { handle_errors except: :bad_request }

    expect { dispatch_raw_query(klass, "q=%FF") }.to raise_error(ActionController::BadRequest)
  end

  it "uses a host's own later rescue_from ActionController::BadRequest, as rescue_from precedence does inside the action" do
    klass = build do
      rescue_from(ActionController::BadRequest) { |_error| render json: { custom: true }, status: :bad_request }
    end

    result = dispatch_raw_query(klass, "q=%FF")

    expect(result.status).to eq(400)
    expect(JSON.parse(result.body)).to eq("custom" => true)
  end

  it "renders under Localizable and Timezoneable without a locale or zone having been chosen" do
    klass = build do
      include ConcernsOnRails::Controllers::Localizable
      include ConcernsOnRails::Controllers::Timezoneable

      timezoneable default: "UTC"
    end

    locale_before = I18n.locale
    zone_before = Time.zone&.name
    result = nil
    expect { result = dispatch_raw_query(klass, "q=%FF", headers: { "Accept-Language" => "en", "Time-Zone" => "Tokyo" }) }
      .not_to raise_error

    expect(result.status).to eq(400)
    expect(JSON.parse(result.body).dig("error", "code")).to eq("bad_request")
    expect(I18n.locale).to eq(locale_before)
    expect(Time.zone&.name).to eq(zone_before)
  end
end
