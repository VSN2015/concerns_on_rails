require "spec_helper"
require "support/integration_harness"
require "json"

# Audit 2026-10-29, HTTP-1 (an incomplete #145). The envelope `code` followed the
# denial's status, but the default `message:` stayed "Forbidden", so a
# `status: :not_found` concealment rule answered
# {"message":"Forbidden","code":"not_found"} next to ErrorHandleable's
# {"message":"Resource not found","code":"not_found"} -- still an existence
# oracle. The default message is now derived from the status, from the SAME
# constant ErrorHandleable renders.
describe "Authorizable default denial message" do
  def message_for(status = nil, kind: :authorize_by, **opts)
    klass = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Respondable
      include ConcernsOnRails::Controllers::Authorizable

      args = status ? opts.merge(status: status) : opts
      if kind == :authorize_by
        authorize_by(**args) { false }
      else
        require_role(:admin, **args)
      end
      define_method(:current_user) { Struct.new(:role).new("viewer") }
      private :current_user
      define_method(:show) { render json: { ok: true } }
    end
    result = IntegrationHarness.dispatch(klass, :show)
    [result.status, JSON.parse(result.body).dig("error", "message")]
  end

  %i[authorize_by require_role].each do |kind|
    context "with #{kind}" do
      it "renders ErrorHandleable's exact missing-record body for status: :not_found with no message:" do
        concealed = IntegrationHarness.build_controller do
          include ConcernsOnRails::Controllers::Respondable
          include ConcernsOnRails::Controllers::Authorizable

          if kind == :authorize_by
            authorize_by(status: :not_found) { false }
          else
            require_role :admin, status: :not_found
          end
          define_method(:current_user) { Struct.new(:role).new("viewer") }
          private :current_user
          define_method(:show) { render json: { ok: true } }
        end
        missing = IntegrationHarness.build_controller do
          include ConcernsOnRails::Controllers::Respondable
          include ConcernsOnRails::Controllers::ErrorHandleable

          define_method(:show) { raise ActiveRecord::RecordNotFound, "Couldn't find Doc with 'id'=42" }
        end

        a = IntegrationHarness.dispatch(concealed, :show)
        b = IntegrationHarness.dispatch(missing, :show)
        expect(a.status).to eq(404)
        expect(a.body).to eq(b.body)
      end

      it "derives the message from an Integer or String 404 and from 401" do
        expect(message_for(404, kind: kind)).to eq([404, "Resource not found"])
        expect(message_for("404", kind: kind)).to eq([404, "Resource not found"])
        expect(message_for(:unauthorized, kind: kind)).to eq([401, "Unauthorized"])
        expect(message_for(401, kind: kind)).to eq([401, "Unauthorized"])
      end

      it "keeps 'Forbidden' for the default status and any unmapped status" do
        expect(message_for(nil, kind: kind)).to eq([403, "Forbidden"])
        expect(message_for(:forbidden, kind: kind)).to eq([403, "Forbidden"])
        expect(message_for(:payment_required, kind: kind)).to eq([402, "Forbidden"])
      end

      it "lets an explicit message: win over the derived default" do
        expect(message_for(:not_found, kind: kind, message: "Nope")).to eq([404, "Nope"])
        expect(message_for(:unauthorized, kind: kind, message: "Log in")).to eq([401, "Log in"])
      end
    end
  end

  it "uses ONE constant for ErrorHandleable's 404 and Authorizable's concealment" do
    expect(ConcernsOnRails::Controllers::Authorizable::DENIAL_MESSAGES[404])
      .to equal(ConcernsOnRails::Support::ErrorEnvelope::NOT_FOUND_MESSAGE)
  end

  it "reports the derived message in the authorization_denied event payload" do
    klass = IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::Authorizable

      authorize_by(status: :not_found) { false }
      define_method(:show) { render json: { ok: true } }
    end
    payloads = []
    sub = ActiveSupport::Notifications.subscribe("authorization_denied.concerns_on_rails") { |*a| payloads << a.last }
    IntegrationHarness.dispatch(klass, :show)
    ActiveSupport::Notifications.unsubscribe(sub)

    expect(payloads.first).to include(status: :not_found, message: "Resource not found")
  end
end
