require "rails/railtie"

module ConcernsOnRails
  # Boot-time integration, loaded only when Rails is present (see the
  # conditional require at the bottom of lib/concerns_on_rails.rb).
  class Railtie < Rails::Railtie
    # Append the filter-parameter proc before ActiveRecord copies
    # `config.filter_parameters` into `filter_attributes` (a `+=` snapshot), so
    # encrypted fields are redacted from both request logs and #inspect. When
    # ActiveRecord is absent the `before:` reference simply doesn't constrain
    # ordering (railties matches before/after by name only).
    initializer "concerns_on_rails.filter_parameters",
                before: "active_record.set_filter_attributes" do |app|
      filter = ConcernsOnRails.filter_parameter_registry.to_proc
      app.config.filter_parameters << filter unless app.config.filter_parameters.include?(filter)
    end
  end
end
