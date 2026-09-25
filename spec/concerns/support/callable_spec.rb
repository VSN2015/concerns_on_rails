require "spec_helper"

RSpec.describe ConcernsOnRails::Support::Callable do
  let(:controller) do
    Class.new do
      def tenant = "acme"
    end.new
  end

  it "instance_execs a Proc on the controller, whatever its arity" do
    expect(described_class.invoke(controller, -> { tenant })).to eq("acme")
    expect(described_class.invoke(controller, proc { tenant })).to eq("acme")
  end

  it "hands any other callable the controller" do
    callable = Class.new { def call(controller) = "#{controller.tenant}!" }.new

    expect(described_class.invoke(controller, callable)).to eq("acme!")
  end

  it "calls a callable whose #call takes no arguments bare (a Method included)" do
    bare = Class.new { def call = "bare" }.new
    holder = Class.new { def self.current = "method" }

    expect(described_class.invoke(controller, bare)).to eq("bare")
    expect(described_class.invoke(controller, holder.method(:current))).to eq("method")
  end

  it "hands the controller to a #call answered only through method_missing" do
    ghost = Class.new do
      def respond_to_missing?(name, include_private = false) = name == :call || super
      def method_missing(name, *args) = name == :call ? args : super
    end.new

    expect(described_class.invoke(controller, ghost)).to eq([controller])
  end
end
