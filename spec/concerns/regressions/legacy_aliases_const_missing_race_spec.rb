require "spec_helper"
require "stringio"

# Regression (audit 2026-10-29, GRAPH-4): const_missing pinned the alias with an unconditional
# const_set, so two threads that both missed the constant printed Ruby's "already initialized
# constant" warning (the comment on it claimed idempotence).
RSpec.describe "ConcernsOnRails legacy alias const_missing" do
  around do |example|
    ConcernsOnRails.send(:remove_const, :Maskable) if ConcernsOnRails.const_defined?(:Maskable, false)
    example.run
  ensure
    ConcernsOnRails.const_get(:Maskable) unless ConcernsOnRails.const_defined?(:Maskable, false)
  end

  def capture_stderr
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end

  it "returns the pinned module without a warning when const_missing is reached twice" do
    results = []
    warnings = capture_stderr do
      results << ConcernsOnRails.const_missing(:Maskable)
      results << ConcernsOnRails.const_missing(:Maskable)
    end

    expect(warnings).not_to include("already initialized constant")
    expect(results).to all(equal(ConcernsOnRails::Models::Maskable))
  end

  it "resolves to one module under racing threads, warning-free" do
    warnings = capture_stderr do
      Array.new(8) { Thread.new { ConcernsOnRails.const_missing(:Maskable) } }.each(&:join)
    end

    expect(warnings).not_to include("already initialized constant")
    expect(ConcernsOnRails::Maskable).to equal(ConcernsOnRails::Models::Maskable)
  end

  it "still raises NameError for a name that is not a legacy alias" do
    expect { ConcernsOnRails.const_missing(:NotAConcern) }.to raise_error(NameError)
  end
end
