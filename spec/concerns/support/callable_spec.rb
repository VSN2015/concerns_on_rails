require "spec_helper"

RSpec.describe ConcernsOnRails::Support::Callable do
  let(:controller) do
    Class.new do
      def tenant = "acme"
    end.new
  end

  it "instance_execs a zero-arity lambda or a block on the receiver" do
    expect(described_class.invoke(controller, -> { tenant })).to eq("acme")
    expect(described_class.invoke(controller, proc { tenant })).to eq("acme")
  end

  it "hands any other callable the controller" do
    callable = Class.new { def call(controller) = "#{controller.tenant}!" }.new

    expect(described_class.invoke(controller, callable)).to eq("acme!")
  end

  # Throttleable's if: dispatch: a lambda that takes an argument (or a
  # symbol proc) is CALLED with the receiver — instance_exec'ing it passed
  # no argument and raised ArgumentError.
  it "calls a lambda that takes an argument, and a symbol proc, with the receiver" do
    outside = "outside"
    expect(described_class.invoke(controller, ->(c) { "#{c.tenant}/#{outside}" })).to eq("acme/outside")
    expect(described_class.invoke(controller, :tenant.to_proc)).to eq("acme")
    expect(described_class.invoke(controller, controller.method(:tenant).to_proc)).to eq("acme")
  end

  # Before the arity dispatch every Proc was instance_exec'd, so a lambda
  # with only a splat or optional parameters read the receiver's state; it
  # still does (only a REQUIRED parameter means "hand me the receiver").
  it "instance_execs a lambda with no required parameter (splat, optional)" do
    expect(described_class.invoke(controller, ->(*) { tenant })).to eq("acme")
    expect(described_class.invoke(controller, ->(_c = nil) { tenant })).to eq("acme")
  end

  it "calls a Method with an optional parameter, and a splat #call, with the receiver" do
    splat = Class.new { def call(*args) = args.first.tenant }.new
    optional = Class.new { def self.pick(receiver = nil) = receiver&.tenant }.method(:pick)

    expect(described_class.invoke(controller, splat)).to eq("acme")
    expect(described_class.invoke(controller, optional)).to eq("acme")
  end

  it "instance_execs a block-style proc and hands it the receiver as well" do
    expect(described_class.invoke(controller, proc { |c| [tenant, c.tenant] })).to eq(%w[acme acme])
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
