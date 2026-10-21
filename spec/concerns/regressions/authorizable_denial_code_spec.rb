require "spec_helper"
require "support/integration_harness"
require "json"

# Audit 2026-10-09, HTTP-3. authorization_denied hard-coded code: "forbidden",
# so a `status: :not_found` concealment rule answered
# {"code":"forbidden"} next to its 404 -- distinguishable from a genuinely
# missing record (ErrorHandleable's "not_found"), i.e. an existence oracle for
# exactly the records the rule hides -- and a 401 told clients "forbidden".
describe "Authorizable denial envelope code" do
  def denying_controller(status, message: "Resource not found", respondable: true, problem_details: false)
    IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Respondable if respondable
      include ConcernsOnRails::Controllers::Authorizable

      respondable_by error_format: :problem_details, problem_type_base: "https://errors.example.com" if problem_details
      authorize_by(status: status, message: message) { false }

      define_method(:show) { render json: { ok: true } }
    end
  end

  def missing_record_controller(problem_details: false)
    IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Respondable
      include ConcernsOnRails::Controllers::ErrorHandleable

      respondable_by error_format: :problem_details, problem_type_base: "https://errors.example.com" if problem_details

      define_method(:show) { raise ActiveRecord::RecordNotFound, "Couldn't find Document with 'id'=42" }
    end
  end

  def code_for(klass)
    result = IntegrationHarness.dispatch(klass, :show)
    [result.status, JSON.parse(result.body).dig("error", "code")]
  end

  it "answers a status: :not_found rule with the same body as a genuinely missing record" do
    concealed = IntegrationHarness.dispatch(denying_controller(:not_found), :show)
    missing = IntegrationHarness.dispatch(missing_record_controller, :show)

    expect(concealed.status).to eq(404)
    expect(JSON.parse(concealed.body).dig("error", "code")).to eq("not_found")
    expect(concealed.body).to eq(missing.body)
  end

  it "answers a status: :not_found rule with the same problem document as a missing record under :problem_details" do
    concealed = IntegrationHarness.dispatch(denying_controller(:not_found, problem_details: true), :show)
    missing = IntegrationHarness.dispatch(missing_record_controller(problem_details: true), :show)

    body = JSON.parse(concealed.body)
    expect(body).to include("type" => "https://errors.example.com/not_found", "title" => "Not Found",
                            "status" => 404, "code" => "not_found")
    expect(body).to eq(JSON.parse(missing.body))
  end

  it "labels a status: :unauthorized denial 'unauthorized'" do
    expect(code_for(denying_controller(:unauthorized, message: "Authentication required"))).to eq([401, "unauthorized"])
  end

  it "derives the code from an Integer or numeric-String status too" do
    expect(code_for(denying_controller(404))).to eq([404, "not_found"])
    expect(code_for(denying_controller(401))).to eq([401, "unauthorized"])
    expect(code_for(denying_controller("404"))).to eq([404, "not_found"])
  end

  it "keeps 'forbidden' for 403 and for any status it does not map" do
    expect(code_for(denying_controller(:forbidden))).to eq([403, "forbidden"])
    expect(code_for(denying_controller(403))).to eq([403, "forbidden"])
    expect(code_for(denying_controller(:payment_required))).to eq([402, "forbidden"])
  end

  it "derives the code in the inline envelope (no Respondable) as well" do
    expect(code_for(denying_controller(:not_found, respondable: false))).to eq([404, "not_found"])
  end

  it "keeps an app override with the two-keyword authorization_denied signature working" do
    klass = Class.new(denying_controller(:not_found)) do
      def authorization_denied(status:, message:)
        response.set_header("X-Denied", "1")
        super
      end
    end

    result = IntegrationHarness.dispatch(klass, :show)

    expect(result.header("X-Denied")).to eq("1")
    expect(result.status).to eq(404)
    expect(JSON.parse(result.body).dig("error", "code")).to eq("not_found")
  end
end
