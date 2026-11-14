require "spec_helper"

# Audit 2026-11-13, HTTP-2: throttled_response returned nil without a response object even
# when a (private) render_error existed, so the rate limit failed open.
describe ConcernsOnRails::Controllers::Throttleable do
  def throttled_controller(&extra)
    store = ActiveSupport::Cache::MemoryStore.new
    Class.new(FakeController) do
      def self.before_action(*); end
      include ConcernsOnRails::Controllers::Throttleable

      self.throttleable_store = store
      throttle_by limit: 1, period: 60, by: -> { "client" }
      attr_reader :errors_rendered

      def action_name = "index"
      class_eval(&extra) if extra
    end
  end

  def throttle_twice(klass)
    2.times.map do
      klass.new.tap do |c|
        c.response = nil
        c.enforce_throttles
      end
    end.last
  end

  it "still rejects a throttled request through a private render_error when there is no response" do
    klass = throttled_controller do
      private

      def render_error(**kwargs)
        (@errors_rendered ||= []) << kwargs
      end
    end
    second = throttle_twice(klass)
    expect(second.errors_rendered).to be_present
  end

  it "raises instead of failing open when nothing can render the 429" do
    klass = throttled_controller
    expect { throttle_twice(klass) }.to raise_error(/refusing to fail open/)
  end
end
