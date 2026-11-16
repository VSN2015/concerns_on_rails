require "spec_helper"

describe "Deprecatable after_sunset: :gone with nothing to render the 410" do
  it "raises instead of failing open" do
    klass = Class.new(FakeController) do
      def self.before_action(*); end
      include ConcernsOnRails::Controllers::Deprecatable

      deprecate_actions :index, deprecated_at: "2025-01-01", sunset_at: "2026-01-15", after_sunset: :gone
      def action_name = "index"
    end
    c = klass.new
    c.response = nil
    expect { c.apply_api_deprecations }.to raise_error(/refusing to fail open/)
  end
end
