require "spec_helper"
require "support/integration_harness"

# Audit 2026-10-09, HTTP-8. ActiveSupport::Rescuable walks #cause when no
# handler matches the raised exception and calls the handler with the cause
# (ActionView::Template::Error around a RecordNotFound, an app's
# `rescue => e; raise ServiceError`). handled_error.concerns_on_rails used to
# report the wrapper next to the cause's code (`code: :not_found` with
# `exception_class: "RuntimeError"`), so routing on the class went wrong.
describe "ErrorHandleable handled_error event for a wrapped exception" do
  def events_for(controller_class, action = :show)
    events = []
    callback = ->(*args) { events << ActiveSupport::Notifications::Event.new(*args) }
    ActiveSupport::Notifications.subscribed(callback, "handled_error.concerns_on_rails") do
      @result = IntegrationHarness.dispatch(controller_class, action)
    end
    events
  end

  let(:wrapped) do
    IntegrationHarness.build_controller do
      include ConcernsOnRails::Controllers::ErrorHandleable

      # What ActionView::Template::Error (and any app wrapper) does: re-raise
      # with the original as #cause.
      def show
        raise ActiveRecord::RecordNotFound, "Couldn't find Article"
      rescue ActiveRecord::RecordNotFound
        raise "template rendering failed"
      end

      def direct
        raise ActiveRecord::RecordNotUnique, "dup"
      end
    end
  end

  it "reports the exception that was handled, reached through #cause, not the wrapper" do
    events = events_for(wrapped)

    expect(@result.status).to eq(404)
    expect(events.size).to eq(1)
    payload = events.first.payload
    expect(payload[:code]).to eq(:not_found)
    expect(payload[:exception_class]).to eq("ActiveRecord::RecordNotFound")
    expect(payload[:exception]).to be_a(ActiveRecord::RecordNotFound)
  end

  it "hands the handled exception to the on_handled_error override" do
    seen = []
    klass = Class.new(wrapped) do
      define_method(:on_handled_error) do |key, error, **|
        seen << [key, error.class.name]
      end
    end

    events_for(klass)

    expect(seen).to eq([[:not_found, "ActiveRecord::RecordNotFound"]])
  end

  it "still reports an exception that was handled directly" do
    events = events_for(wrapped, :direct)

    expect(events.first.payload).to include(code: :record_not_unique, exception_class: "ActiveRecord::RecordNotUnique")
  end

  it "keeps a handler called outside a rescue reporting a nil exception" do
    controller = wrapped.new
    controller.define_singleton_method(:render) { |*, **| nil }
    events = []
    callback = ->(*args) { events << ActiveSupport::Notifications::Event.new(*args) }

    ActiveSupport::Notifications.subscribed(callback, "handled_error.concerns_on_rails") do
      controller.handle_stale_object(ActiveRecord::StaleObjectError.new)
    end

    expect(events.first.payload).to include(code: :stale_object, exception: nil, exception_class: nil)
  end
end
