require "spec_helper"
require "active_support/parameter_filter"

RSpec.describe ConcernsOnRails::Support::FilterParameterRegistry do
  let(:registry) { described_class.new }

  it "matches case-insensitively as a substring (Rails symbol-filter semantics)" do
    registry.add(:ssn)
    expect(registry.include?("ssn")).to be(true)
    expect(registry.include?("SSN")).to be(true)
    expect(registry.include?("user_ssn")).to be(true)
    expect(registry.include?("email")).to be(false)
  end

  it "matches nothing when empty, and resets" do
    expect(registry.include?("anything")).to be(false)
    registry.add(:ssn)
    registry.reset!
    expect(registry.include?("ssn")).to be(false)
  end

  it "returns the same proc object every call (the Railtie's idempotence check)" do
    expect(registry.to_proc).to equal(registry.to_proc)
  end

  it "redacts through an ALREADY-BUILT ParameterFilter — the boot-frozen snapshot scenario" do
    filter = ActiveSupport::ParameterFilter.new([registry.to_proc])
    registry.add(:ssn)

    result = filter.filter("ssn" => "123-45-6789", "user" => { "ssn" => "hidden" }, "name" => "ok")
    expect(result["ssn"]).to eq("[FILTERED]")
    expect(result["user"]["ssn"]).to eq("[FILTERED]")
    expect(result["name"]).to eq("ok")

    # Fields registered AFTER the filter instance was built (lazy-loaded model
    # classes in development) are still redacted — the pre-1.22 symbol appends
    # were invisible to every boot-time snapshot.
    registry.add(:dob)
    expect(filter.filter("dob" => "1990-01-01")["dob"]).to eq("[FILTERED]")
  end
end

RSpec.describe "ConcernsOnRails::Railtie filter_parameters initializer" do
  it "is registered before ActiveRecord's filter_attributes copy and appends the proc once" do
    begin
      require "rails/railtie"
      require "concerns_on_rails/railtie"
    rescue LoadError
      skip "railties not available in this bundle"
    end

    initializer = ConcernsOnRails::Railtie.initializers.find { |i| i.name == "concerns_on_rails.filter_parameters" }
    expect(initializer).not_to be_nil
    expect(initializer.before).to eq("active_record.set_filter_attributes")

    config = Struct.new(:filter_parameters).new([])
    app = Struct.new(:config).new(config)
    2.times { initializer.block.call(app) }

    expect(config.filter_parameters.size).to eq(1)
    expect(config.filter_parameters.first).to equal(ConcernsOnRails.filter_parameter_registry.to_proc)
  end
end
